#!/usr/bin/env python3
"""MBR/GPT walkers and caller dispatch against malformed disk structures.

parts.s decides what gets mounted from structures it does not control, so the
cases here are mostly malformed on purpose. It is context-free: _partScanMBR
takes a loaded block, _partScanGPT takes a block-reader callback, and both fill
a caller-supplied PartRec buffer, so no device and no library state is needed.

Status: gated, run by make test.
Run from the repository root: python3 tests/parts_walker.py"""
import json
import re
import struct
import sys
import tempfile
from pathlib import Path

from amitools.binfmt.BinFmt import BinFmt
from amitools.binfmt.Relocate import Relocate
from amitools.vamos.machine import Machine
from toolchain import ROOT, assemble

BASE, BUF, BLOCK, CB, STACK = 0x10000, 0x40000, 0x42000, 0x44000, 0x90000
NEED = ('PR_StartLBA', 'PR_BlockCount', 'PR_DosType', 'PR_PartIndex', 'PR_Flags',
        'PR_Sizeof', 'PRFB_PRESENT', 'PRFB_GPT', 'PRFB_BOOTABLE', 'PART_MAX_REC',
        'DOSTYPE_FAT')

MS_BASIC = bytes.fromhex('a2a0d0ebe5b9334487c068b6b72699c7')
EFI_SYS = bytes.fromhex('28732ac11ff8d211ba4b00a0c93ec93b')
UNKNOWN = bytes.fromhex('0123456789abcdef0123456789abcdef')


def build(tmp, cpu, flavour):
    """Assemble the library and recover the PartRec offsets from the listing."""
    obj, lst = tmp / 'ptable', tmp / 'ptable.lst'
    assemble(obj, cpu=cpu, flavour=flavour, listing=lst)
    eq = {'cpu': cpu}
    for line in lst.read_text(errors='replace').splitlines():
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s+E:([0-9A-Fa-f]{8})\s*$', line)
        if m:
            eq[m.group(1)] = int(m.group(2), 16)
    missing = [n for n in NEED if n not in eq]
    assert not missing, 'missing equates: %s' % missing
    return BinFmt().load_image(str(obj)), eq


class Walker:
    """One run of a walker with the blocks a crafted table would make it read."""
    CTX = 0x46000

    def __init__(self, image, eq, blocks=None):
        self.eq = eq
        self.blocks = blocks or {}
        self.reads = []
        self.m = Machine.from_name(eq['cpu'], ram_size=8192)
        self.cpu, self.mem = self.m.get_cpu(), self.m.get_mem()
        self.mem.w_block(BASE, bytes(Relocate(image).relocate_one_block(BASE)))
        self.syms = {s.name.decode(): BASE + s.offset
                     for s in image.get_segments()[0].get_symtab().get_symbols()}
        self.buffer_end = BUF + eq['PART_MAX_REC'] * eq['PR_Sizeof']
        self.mem.w_block(BUF - 16, b'\xa5' * 16)
        self.mem.w_block(BUF, bytes(self.buffer_end - BUF))
        self.mem.w_block(self.buffer_end, b'\xa5' * 16)
        tid = self.m.get_traps().alloc(lambda op, pc: self._read())
        self.mem.w16(CB, 0xa000 | tid)
        self.mem.w16(CB + 2, 0x4e75)

    def _read(self):
        """The block-reader callback: serve the block or report a read failure."""
        lba = self.cpu.r_reg(0)
        self.reads.append(lba)
        data = self.blocks.get(lba)
        if data is None:
            self.cpu.w_reg(0, 1)
            return
        self.mem.w_block(BLOCK, data.ljust(512, b'\0'))
        self.cpu.w_reg(8, BLOCK)        # a0
        self.cpu.w_reg(0, 0)

    def run(self, name, a0=0, context=0, regs=()):
        for i in range(16):
            self.cpu.w_reg(i, 0)
        self.cpu.w_reg(8, a0)           # a0 = loaded block, MBR only
        self.cpu.w_reg(10, BUF)         # a2 = output buffer
        self.cpu.w_reg(11, CB)          # a3 = block reader
        self.cpu.w_reg(12, context)     # a4 = callback context
        for reg, value in regs:
            self.cpu.w_reg(reg, value)
        self.m.prepare(self.syms[name], STACK)
        state = self.m.execute(2000000)
        assert self.m.was_exit(state), '%s did not return' % name
        assert self.cpu.r_sp() == STACK, '%s left the stack unbalanced' % name
        assert bytes(self.mem.r_block(BUF - 16, 16)) == b'\xa5' * 16
        assert bytes(self.mem.r_block(self.buffer_end, 16)) == b'\xa5' * 16
        return self.cpu.r_reg(0)

    def records(self, count):
        """Read the filled PartRec entries back as dicts."""
        eq, out = self.eq, []
        for i in range(count):
            a = BUF + i * eq['PR_Sizeof']
            out.append({'start': self.mem.r32(a + eq['PR_StartLBA']),
                        'blocks': self.mem.r32(a + eq['PR_BlockCount']),
                        'dostype': self.mem.r32(a + eq['PR_DosType']),
                        'index': self.mem.r8(a + eq['PR_PartIndex']),
                        'flags': self.mem.r8(a + eq['PR_Flags'])})
        return out

    def close(self):
        self.m.cleanup()


class Scanner(Walker):
    """Real scanner and parsers; mock geometry, reads, publishing and reconciliation."""

    def __init__(self, image, eq, blocks):
        super().__init__(image, eq, blocks)
        self.published, self.reconcile = [], []
        self.mem.w32(self.CTX + eq['BC_BlockBuf'], BLOCK)
        # Zeroed geometry describes a direct-access device, not optical. The
        # helper only exists on a library that knows about optical media; the
        # dispatch below does not depend on it either way.
        if '_bootGeometry' in self.syms:
            self.stub('_bootGeometry', lambda: self.cpu.w_reg(0, 0))
        self.stub('_bootReadBlock', self._read)
        self.stub('_psReadLBA', self._read)
        self.stub('_scanClearPresent', lambda: self.reconcile.append('clear'))
        self.stub('_scanPurge', lambda: self.reconcile.append('purge'))
        self.stub('_scanPubRec', self.publish_record)
        self.stub('_scanPubFlat', self.publish_flat)
        for name in ('_bootDebug', '_bootDebugDec32'):
            if name in self.syms:
                self.stub(name, lambda: None)

    def stub(self, name, fn):
        tid = self.m.get_traps().alloc(lambda op, pc: fn())
        self.mem.w16(self.syms[name], 0xa000 | tid)
        self.mem.w16(self.syms[name] + 2, 0x4e75)

    def publish_record(self):
        entry = self.cpu.r_reg(11)
        self.published.append((self.cpu.r_reg(6),
                               self.mem.r32(entry + self.eq['PR_StartLBA']),
                               self.mem.r32(entry + self.eq['PR_BlockCount'])))
        self.cpu.w_reg(0, 1)

    def publish_flat(self):
        self.published.append(('flat', 0, self.cpu.r_reg(1)))
        self.cpu.w_reg(0, 1)


def fat_boot(signature=b'\x55\xaa', total=64):
    block = bytearray(512)
    block[:3] = b'\xeb\x3c\x90'
    block[11:13] = struct.pack('<H', 512)
    block[13] = 1
    block[19:21] = struct.pack('<H', total)
    block[510:512] = signature
    return bytes(block)


def scanner_cases(image, eq, check):
    protective = mbr([(0, 0xee, 1, 1000)])
    ordinary = mbr([(0, 0x06, 100, 8)])
    gpt = {1: gpt_header(count=1), 2: gpt_entry(MS_BASIC, 200, 207), 200: fat_boot()}
    cases = []
    for name, sector in (('MBR', ordinary), ('GPT', protective)):
        for signature in (b'\0\0', b'\xaa\x55'):
            cases.append((name + ' bad signature ' + signature.hex(),
                          {**gpt, 0: sector[:510] + signature, 100: fat_boot()}, []))
    cases += [
        ('slot zero protective selects GPT', {**gpt, 0: protective},
         [(eq['PES_GPT'], 200, 8)]),
        ('ordinary selects MBR despite GPT header', {**gpt, 0: ordinary, 100: fat_boot()},
         [(eq['PES_MBR'], 100, 8)]),
        ('protective second slot stays MBR',
         {**gpt, 0: mbr([(0, 0x06, 100, 8), (0, 0xee, 1, 1000)]), 100: fat_boot()},
         [(eq['PES_MBR'], 100, 8)]),
        ('block zero read fails', gpt, []),
        ('GPT header read fails', {0: protective, 2: gpt[2], 200: fat_boot()}, []),
        ('partition read fails', {0: ordinary}, []),
        ('partition signature absent', {0: ordinary, 100: fat_boot(signature=b'\0\0')}, []),
        ('partition BPB invalid', {0: ordinary, 100: bytes(510) + b'\x55\xaa'}, []),
        ('empty flat medium not published', {0: fat_boot(total=0)}, []),
    ]
    # A valid BPB at LBA0 takes precedence over protective MBR bytes.
    flat = bytearray(fat_boot())
    flat[446:510] = protective[446:510]
    cases.append(('flat BPB precedes table bytes', {**gpt, 0: bytes(flat)}, [('flat', 0, 64)]))
    for name, blocks, expected in cases:
        w = Scanner(image, eq, blocks)
        try:
            n = w.run('_scanRun', context=w.CTX)
            check('scan ' + name, (n, w.published, w.reconcile),
                  (len(expected), expected, ['clear', 'purge']))
        finally:
            w.close()

    # A primary failing the boot gate does not stop the logicals behind it.
    blocks = {0: mbr([(0, 0x06, 100, 8), (0, 0x0c, 200, 8), (0, 0x0f, 1000, 100)]),
              100: fat_boot(), 1000: ebr((0, 0x0c, 10, 8)), 1010: fat_boot()}
    w = Scanner(image, eq, blocks)
    try:
        n = w.run('_scanRun', context=w.CTX)
        check('scan MBR logical published', (n, w.published),
              (2, [(eq['PES_MBR'], 100, 8), (eq['PES_MBR'], 1010, 8)]))
    finally:
        w.close()

    # _scanFillRec names the entry by its table index: the first logical is CF4.
    entry, name = 0x48000, 0x47000
    w = Walker(image, eq)
    try:
        w.mem.w_block(name, b'compactflash.device\0')
        w.mem.w32(w.CTX + eq['BC_DevName'], name)
        w.mem.w32(w.CTX + eq['BC_Unit'], 0)
        w.mem.w_block(entry, bytes(eq['pe_Sizeof']))
        w.mem.w_block(BUF, struct.pack('>IIIBB', 1010, 8, eq['DOSTYPE_FAT'], 4,
                                       1 << eq['PRFB_PRESENT']))
        w.run('_scanFillRec', context=w.CTX,
              regs=((6, eq['PES_MBR']), (11, entry)))
        nb = entry + eq['pe_NameB']
        check('fill names MBR logical by index',
              (bytes(w.mem.r_block(nb + 1, w.mem.r8(nb))),
               w.mem.r32(entry + eq['pe_PartIndex'])), (b'CF4', 4))
    finally:
        w.close()


def ebr(logical, link=None):
    """An EBR: entry 0 = logical (start relative to this EBR), entry 1 = link
    (start relative to the extended partition)."""
    return mbr([logical, link or (0, 0, 0, 0)])


def mbr(slots):
    """A 512-byte MBR. slots is a list of (status, type, start, count)."""
    block = bytearray(512)
    for i, slot in enumerate(slots[:4]):
        status, kind, start, count = slot
        off = 446 + i * 16
        block[off] = status
        block[off + 4] = kind
        block[off + 8:off + 12] = struct.pack('<I', start)
        block[off + 12:off + 16] = struct.pack('<I', count)
    block[510:512] = b'\x55\xaa'
    return bytes(block)


def gpt_header(entry_lba=2, count=4, size=128, magic=b'EFI PART', entry_lba_high=0):
    block = bytearray(512)
    block[0:8] = magic
    block[72:76] = struct.pack('<I', entry_lba)
    block[76:80] = struct.pack('<I', entry_lba_high)
    block[80:84] = struct.pack('<I', count)
    block[84:88] = struct.pack('<I', size)
    return bytes(block)


def gpt_entry(guid, first, last, first_high=0, last_high=0):
    e = bytearray(128)
    e[0:16] = guid
    e[32:36] = struct.pack('<I', first)
    e[36:40] = struct.pack('<I', first_high)
    e[40:44] = struct.pack('<I', last)
    e[44:48] = struct.pack('<I', last_high)
    return bytes(e)


def entry_blocks(entries, entry_lba=2, size=128):
    """Lay entries out at the size the header declares, one dict of blocks."""
    raw = b''.join(e.ljust(size, b'\0') for e in entries)
    blocks = {}
    for i in range(0, max(len(raw), 1), 512):
        blocks[entry_lba + i // 512] = raw[i:i + 512]
    return blocks


def run_suite(cpu, flavour):
    rows, bad = [], []

    def check(name, got, want):
        ok = got == want
        rows.append({'case': name, 'ok': ok, 'got': got, 'want': want})
        if not ok:
            bad.append(name)

    with tempfile.TemporaryDirectory() as tmp:
        image, eq = build(Path(tmp), cpu, flavour)
        present = 1 << eq['PRFB_PRESENT']
        gptf = present | (1 << eq['PRFB_GPT'])
        boot = present | (1 << eq['PRFB_BOOTABLE'])

        # --- MBR ------------------------------------------------------
        for kind in (0x01, 0x04, 0x06, 0x0b, 0x0c, 0x0e):
            w = Walker(image, eq)
            n = w.run('_partScanMBR', a0=w.mem.w_block(BLOCK, mbr([(0, kind, 100, 8)])) or BLOCK)
            check('mbr type %02x accepted' % kind, (n, w.records(n)),
                  (1, [{'start': 100, 'blocks': 8, 'dostype': eq['DOSTYPE_FAT'],
                        'index': 0, 'flags': present}]))
            w.close()
        for kind in (0x00, 0x05, 0x07, 0x82, 0xee):
            w = Walker(image, eq)
            w.mem.w_block(BLOCK, mbr([(0, kind, 100, 8)]))
            check('mbr type %02x refused' % kind, w.run('_partScanMBR', a0=BLOCK), 0)
            w.close()

        w = Walker(image, eq)
        w.mem.w_block(BLOCK, mbr([(0, 0x06, 100, 0)]))
        check('mbr zero-length slot skipped', w.run('_partScanMBR', a0=BLOCK), 0)
        w.close()

        w = Walker(image, eq)
        w.mem.w_block(BLOCK, mbr([(0x80, 0x06, 1, 2), (0x01, 0x0c, 3, 4)]))
        n = w.run('_partScanMBR', a0=BLOCK)
        check('mbr bootable is only status 80', [r['flags'] for r in w.records(n)],
              [boot, present])
        w.close()

        w = Walker(image, eq)
        w.mem.w_block(BLOCK, mbr([(0, 0x00, 0, 0), (0, 0x06, 9, 9), (0, 0x00, 0, 0),
                                  (0, 0x0c, 7, 7)]))
        n = w.run('_partScanMBR', a0=BLOCK)
        check('mbr slot index survives a gap', [r['index'] for r in w.records(n)], [1, 3])
        w.close()

        # --- MBR extended / logical ------------------------------------
        def logicals(label, blocks, want, reads=None):
            w = Walker(image, eq, blocks)
            w.mem.w_block(BLOCK, blocks[0])
            n = w.run('_partScanMBR', a0=BLOCK)
            got = [(r['start'], r['blocks'], r['index']) for r in w.records(n)]
            if reads is None:
                check('mbr ' + label, got, want)
            else:
                check('mbr ' + label, (got, w.reads), (want, reads))
            w.close()

        for kind in (0x05, 0x0f, 0x85):
            logicals('extended type %02x followed' % kind,
                     {0: mbr([(0, 0x0c, 100, 8), (0, kind, 1000, 500)]),
                      1000: ebr((0, 0x0c, 10, 20), (0, 0x05, 100, 50)),
                      1100: ebr((0, 0x06, 10, 30))},
                     [(100, 8, 0), (1010, 20, 4), (1110, 30, 5)], [1000, 1100])
        logicals('non-FAT logical skipped but indexed',
                 {0: mbr([(0, 0x0f, 1000, 500)]),
                  1000: ebr((0, 0x07, 10, 20), (0, 0x05, 100, 50)),
                  1100: ebr((0, 0x0c, 10, 30))},
                 [(1110, 30, 5)])
        logicals('empty EBR entry takes no index',
                 {0: mbr([(0, 0x0f, 1000, 500)]),
                  1000: ebr((0, 0, 0, 0), (0, 0x05, 100, 50)),
                  1100: ebr((0, 0x0c, 10, 30))},
                 [(1110, 30, 4)])
        logicals('only the first extended slot followed',
                 {0: mbr([(0, 0x0f, 1000, 500), (0, 0x05, 2000, 500)]),
                  1000: ebr((0, 0x0c, 10, 20)), 2000: ebr((0, 0x0c, 10, 20))},
                 [(1010, 20, 4)], [1000])
        logicals('zero-size extended slot ignored',
                 {0: mbr([(0, 0x0f, 1000, 0)]), 1000: ebr((0, 0x0c, 10, 20))},
                 [], [])
        logicals('EBR link cycle stops',
                 {0: mbr([(0, 0x0f, 1000, 500)]),
                  1000: ebr((0, 0x0c, 10, 20), (0, 0x05, 100, 50)),
                  1100: ebr((0, 0x0c, 10, 30), (0, 0x05, 100, 50))},
                 [(1010, 20, 4), (1110, 30, 5)], [1000, 1100])
        logicals('EBR link backwards stops',
                 {0: mbr([(0, 0x0f, 1000, 500)]),
                  1000: ebr((0, 0x0c, 10, 20), (0, 0x05, 100, 50)),
                  1100: ebr((0, 0x0c, 10, 30), (0, 0x05, 50, 50))},
                 [(1010, 20, 4), (1110, 30, 5)], [1000, 1100])
        logicals('EBR link of non-extended type stops',
                 {0: mbr([(0, 0x0f, 1000, 500)]),
                  1000: ebr((0, 0x0c, 10, 20), (0, 0x0c, 100, 50))},
                 [(1010, 20, 4)], [1000])
        logicals('EBR read failure keeps earlier records',
                 {0: mbr([(0, 0x0c, 100, 8), (0, 0x0f, 1000, 500)]),
                  1000: ebr((0, 0x0c, 10, 20), (0, 0x05, 100, 50))},
                 [(100, 8, 0), (1010, 20, 4)], [1000, 1100])
        logicals('EBR without signature stops',
                 {0: mbr([(0, 0x0f, 1000, 500)]),
                  1000: ebr((0, 0x0c, 10, 20))[:510] + b'\0\0'},
                 [], [1000])
        logicals('logical start beyond 32 bits skipped',
                 {0: mbr([(0, 0x0f, 0xfffffff0, 500)]),
                  0xfffffff0: ebr((0, 0x0c, 0x20, 20))},
                 [])
        logicals('EBR link beyond 32 bits stops',
                 {0: mbr([(0, 0x0f, 0xfffffff0, 500)]),
                  0xfffffff0: ebr((0, 0x0c, 1, 2), (0, 0x05, 0x20, 50))},
                 [(0xfffffff1, 2, 4)], [0xfffffff0])

        # Three primaries leave slot 3 for the extended one; the logicals fill
        # the rest, the last taking index 4 + (PART_MAX_REC - 3) - 1.
        chain = {0: mbr([(0, 0x0c, 10 + i, 1) for i in range(3)] + [(0, 0x0f, 1000, 5000)])}
        for i in range(eq['PART_MAX_REC']):
            chain[1000 + i * 100] = ebr((0, 0x0c, 10, 1), (0, 0x05, (i + 1) * 100, 50))
        w = Walker(image, eq, chain)
        w.mem.w_block(BLOCK, chain[0])
        n = w.run('_partScanMBR', a0=BLOCK)
        check('mbr logicals stop at PART_MAX_REC',
              (n, w.records(n)[-1]['index'], len(w.reads)),
              (eq['PART_MAX_REC'], eq['PART_MAX_REC'], eq['PART_MAX_REC'] - 3))
        w.close()

        # --- GPT, well-formed ----------------------------------------
        for label, guid in (('basic data', MS_BASIC), ('efi system', EFI_SYS)):
            blocks = {1: gpt_header(count=1)}
            blocks.update(entry_blocks([gpt_entry(guid, 2048, 4095)]))
            w = Walker(image, eq, blocks)
            n = w.run('_partScanGPT')
            check('gpt %s accepted' % label, (n, w.records(n)),
                  (1, [{'start': 2048, 'blocks': 2048, 'dostype': eq['DOSTYPE_FAT'],
                        'index': 0, 'flags': gptf}]))
            w.close()

        for label, blocks in (
                ('no header block', {}),
                ('bad magic', {1: gpt_header(magic=b'NOT PART')}),
                ('entry array beyond 32 bits', {1: gpt_header(entry_lba_high=1)}),
                ('entry size below 128', {1: gpt_header(size=64)}),
                ('entry size not a multiple of 128', {1: gpt_header(size=192)})):
            w = Walker(image, eq, dict(blocks))
            check('gpt refused: %s' % label, w.run('_partScanGPT'), 0)
            w.close()

        # 384 is three times 128: UEFI only ever emits 128 times a power of two,
        # so this pins what the parser accepts rather than what the spec emits.
        blocks = {1: gpt_header(count=1, size=384)}
        blocks.update(entry_blocks([gpt_entry(MS_BASIC, 64, 127)], size=384))
        w = Walker(image, eq, blocks)
        check('gpt entry size 384 accepted', w.run('_partScanGPT'), 1)
        w.close()

        blocks = {1: gpt_header(count=2)}
        blocks.update(entry_blocks([gpt_entry(bytes(16), 1, 2),
                                    gpt_entry(UNKNOWN, 3, 4)]))
        w = Walker(image, eq, blocks)
        check('gpt unused and unknown guids skipped', w.run('_partScanGPT'), 0)
        w.close()

        for label, kw in (('first', {'first_high': 1}), ('last', {'last_high': 1})):
            blocks = {1: gpt_header(count=1)}
            blocks.update(entry_blocks([gpt_entry(MS_BASIC, 8, 16, **kw)]))
            w = Walker(image, eq, blocks)
            check('gpt %s lba beyond 32 bits skipped' % label, w.run('_partScanGPT'), 0)
            w.close()

        entries = [gpt_entry(MS_BASIC, 100 + i * 10, 108 + i * 10)
                   for i in range(eq['PART_MAX_REC'] + 3)]
        blocks = {1: gpt_header(count=len(entries))}
        blocks.update(entry_blocks(entries))
        w = Walker(image, eq, blocks)
        check('gpt stops at PART_MAX_REC', w.run('_partScanGPT'), eq['PART_MAX_REC'])
        w.close()

        for label, first, last in (('reversed', 4096, 2048),
                                   ('overflow length', 0, 0xffffffff)):
            blocks = {1: gpt_header(count=1)}
            blocks.update(entry_blocks([gpt_entry(MS_BASIC, first, last)]))
            w = Walker(image, eq, blocks)
            check('gpt ' + label + ' skipped', w.run('_partScanGPT'), 0)
            w.close()

        blocks = {1: gpt_header(count=1)}
        blocks.update(entry_blocks([gpt_entry(MS_BASIC, 0xffffffff, 0xffffffff)]))
        w = Walker(image, eq, blocks)
        n = w.run('_partScanGPT')
        check('gpt last representable LBA accepted',
              (n, [(r['start'], r['blocks']) for r in w.records(n)]),
              (1, [(0xffffffff, 1)]))
        w.close()

        blocks = {1: gpt_header(count=1)}
        blocks.update(entry_blocks([gpt_entry(MS_BASIC, 1, 0xffffffff)]))
        w = Walker(image, eq, blocks)
        n = w.run('_partScanGPT')
        check('gpt maximum representable count accepted',
              (n, [r['blocks'] for r in w.records(n)]), (1, [0xffffffff]))
        w.close()

        # index 1 fits; index 2 must not wrap back to LBA 2.
        blocks = {1: gpt_header(count=3, size=0x80000000),
                  2: gpt_entry(MS_BASIC, 1, 2),
                  4194306: gpt_entry(MS_BASIC, 3, 4)}
        w = Walker(image, eq, blocks)
        n = w.run('_partScanGPT')
        check('gpt multiplication cannot wrap', (n, w.reads), (2, [1, 2, 4194306]))
        w.close()

        # The largest aligned byte offset still fits; the next overflows.
        blocks = {1: gpt_header(count=3, size=0xffffff80),
                  2: bytes(512), 8388609: bytes(512)}
        w = Walker(image, eq, blocks)
        n = w.run('_partScanGPT')
        check('gpt large valid offset survives', (n, w.reads), (0, [1, 2, 8388609]))
        w.close()

        # High-word product fits, but adding the low-word product carries.
        blocks = {1: gpt_header(count=4, size=0x55555580),
                  2: bytes(512), 2796204: bytes(512), 5592407: bytes(512)}
        w = Walker(image, eq, blocks)
        n = w.run('_partScanGPT')
        check('gpt partial-product carry rejected',
              (n, w.reads), (0, [1, 2, 2796204, 5592407]))
        w.close()

        blocks = {1: gpt_header(entry_lba=0xffffffff, count=2, size=512),
                  0xffffffff: gpt_entry(MS_BASIC, 8, 9),
                  0: gpt_entry(MS_BASIC, 10, 11)}
        w = Walker(image, eq, blocks)
        n = w.run('_partScanGPT')
        check('gpt LBA addition cannot wrap', (n, w.reads), (1, [1, 0xffffffff]))
        w.close()

        entries = [bytes(128)] * 99 + [gpt_entry(MS_BASIC, 5, 6),
                                       gpt_entry(MS_BASIC, 7, 8)]
        blocks = {1: gpt_header(count=101)}
        blocks.update(entry_blocks(entries))
        w = Walker(image, eq, blocks)
        n = w.run('_partScanGPT')
        check('gpt index 99 accepted, 100 ignored',
              (n, [r['index'] for r in w.records(n)], w.reads[-1]), (1, [99], 26))
        w.close()

        blocks = {1: gpt_header(count=2, size=512),
                  2: gpt_entry(MS_BASIC, 8, 9)}
        w = Walker(image, eq, blocks)
        n = w.run('_partScanGPT')
        check('gpt read failure preserves previous record',
              (n, [r['start'] for r in w.records(n)], w.reads), (1, [8], [1, 2, 3]))
        w.close()

        # This routine checks a loaded block; the caller checks the signature.
        for name, jump, sector, cluster, oem, want in (
                ('short jump', b'\xeb\x3c\x90', 512, 1, b'MSDOS5.0', 0xffffffff),
                ('word jump', b'\xe9\x00\x00', 4096, 128, b'MSDOS5.0', 0xffffffff),
                ('Palm jump', b'\xeb\x00\x90', 1024, 2, b'MSDOS5.0', 0xffffffff),
                ('early jump', b'\xeb\x23\x90', 512, 1, b'MSDOS5.0', 0),
                ('bad opcode', bytes(3), 512, 1, b'MSDOS5.0', 0),
                ('NTFS', b'\xeb\x3c\x90', 512, 1, b'NTFS    ', 0),
                ('zero cluster', b'\xeb\x3c\x90', 512, 0, b'MSDOS5.0', 0),
                ('odd cluster', b'\xeb\x3c\x90', 512, 3, b'MSDOS5.0', 0),
                ('small sector', b'\xeb\x3c\x90', 256, 1, b'MSDOS5.0', 0),
                ('large sector', b'\xeb\x3c\x90', 8192, 1, b'MSDOS5.0', 0),
                ('odd sector', b'\xeb\x3c\x90', 768, 1, b'MSDOS5.0', 0)):
            block = bytearray(512)
            block[:3], block[3:11] = jump, oem
            block[11:13] = struct.pack('<H', sector)
            block[13] = cluster
            w = Walker(image, eq)
            w.mem.w_block(BLOCK, bytes(block))
            check('boot gate ' + name, w.run('_partIsBootBlock', a0=BLOCK), want)
            w.close()

        scanner_cases(image, eq, check)

    print(cpu, flavour, len(rows), 'cases,', len(bad), 'failed')
    if bad:
        print(json.dumps([row for row in rows if not row['ok']], indent=2))
    if bad:
        print('%d case(s) failed: %s' % (len(bad), ', '.join(bad)), file=sys.stderr)
    return 1 if bad else 0


def main():
    return int(any([run_suite(cpu, flavour) for cpu in ('68000', '68020')
                    for flavour in ('small', 'full')]))


if __name__ == '__main__':
    raise SystemExit(main())
