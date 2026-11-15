#!/usr/bin/env python3
"""Mocked Exec for driving the real ptable LVOs against a mock device.

The library image runs on the bare amitools Machine. Exec is a fake base whose
LVO slots trap into Python: memory comes from a guarded heap, lists and
resources are real 68k structures, and DoIO is served by a mockdev.Disk.
"""
import re
import tempfile
from pathlib import Path

from amitools.binfmt.BinFmt import BinFmt
from amitools.binfmt.Relocate import Relocate
from amitools.vamos.machine import Machine

import mockdev as md
from toolchain import assemble

BASE, LIBBASE, EXEC, TASK, STRINGS = 0x10000, 0x38000, 0x60000, 0x3A000, 0x3B000
HEAP, HEAP_END, STACK = 0x100000, 0x700000, 0x90000
GUARD = b'\xa5' * 16
RDBL_EXECBASE = 34

LVO = dict(Forbid=-132, Permit=-138, AllocMem=-198, FreeMem=-210, AddHead=-240,
           AddTail=-246, Remove=-252, FindName=-276, FindTask=-294,
           AllocSignal=-330, FreeSignal=-336, OpenLibrary=-552, CloseLibrary=-414,
           OpenDevice=-444, CloseDevice=-450, DoIO=-456, AddResource=-486,
           OpenResource=-498, RawPutChar=-516, InitSemaphore=-558,
           ObtainSemaphore=-564, ReleaseSemaphore=-570, AttemptSemaphore=-576,
           CacheClearU=-636)

# IORequest offsets (exec/io.h)
IO_COMMAND, IO_ERROR, IO_ACTUAL, IO_LENGTH, IO_DATA, IO_OFFSET = 28, 31, 32, 36, 40, 44


def equates(listing):
    """Assembler equates (NAME E:hex) from a vasm listing."""
    eq = {}
    for line in Path(listing).read_text(errors='replace').splitlines():
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s+E:([0-9A-Fa-f]{8})\s*$', line)
        if m:
            eq[m.group(1)] = int(m.group(2), 16)
    return eq


class Build:
    """One assembled library: image plus equates."""

    def __init__(self, cpu, flavour, tmp):
        self.cpu, self.flavour = cpu, flavour
        out, lst = Path(tmp) / f'pt-{cpu}-{flavour}', Path(tmp) / f'pt-{cpu}-{flavour}.lst'
        assemble(out, cpu=cpu, flavour=flavour, listing=lst)
        self.image = BinFmt().load_image(str(out))
        self.eq = equates(lst)

    @property
    def name(self):
        return f'{self.cpu}/{self.flavour}'


def builds():
    """All four builds, assembled once into a temporary directory."""
    tmp = tempfile.mkdtemp(prefix='ptable-')
    return [Build(cpu, fl, tmp) for cpu in ('68000', '68020') for fl in ('small', 'full')]


_live = []


class Rig:
    """The library loaded at BASE with a mocked Exec and one mock device.

    Only one Machine may exist at a time; a new Rig closes the previous one.
    """

    def __init__(self, build, disk):
        while _live:
            _live.pop().close()
        _live.append(self)
        self.build, self.eq, self.disk = build, build.eq, disk
        self.m = Machine.from_name(build.cpu, ram_size=8192)
        self.cpu, self.mem = self.m.get_cpu(), self.m.get_mem()
        self.mem.w_block(BASE, bytes(Relocate(build.image).relocate_one_block(BASE)))
        self.syms = {s.name.decode(): BASE + s.offset
                     for s in build.image.get_segments()[0].get_symtab().get_symbols()}
        self.mem.w32(4, EXEC)
        self.mem.w32(LIBBASE + RDBL_EXECBASE, EXEC)
        self.heap, self.allocs, self.res = HEAP, {}, {}
        self.events, self.text, self.overruns, self.bad_frees = [], [], [], []
        self.forbid, self.delays = 0, 0
        self.attempt_ok = True
        for name, off in LVO.items():
            self.trap(EXEC + off, getattr(self, 'x_' + name,
                                          lambda n=name: self.events.append(n)))
        self.trap(self.syms['_bootDelay100ms'], self._delay)

    # -- plumbing ---------------------------------------------------------
    def trap(self, addr, fn):
        tid = self.m.get_traps().alloc(lambda op, pc: fn())
        self.mem.w16(addr, 0xA000 | tid)
        self.mem.w16(addr + 2, 0x4E75)

    def r(self, n):
        return self.cpu.r_reg(n)

    def d0(self, value):
        self.cpu.w_reg(0, value & 0xFFFFFFFF)

    def cstr(self, addr):
        out = bytearray()
        while (c := self.mem.r8(addr)):
            out.append(c)
            addr += 1
        return out.decode('latin1')

    def close(self):
        if self.m is not None:
            self.m.cleanup()
            self.m = None

    # -- Exec ---------------------------------------------------------------
    def _delay(self):
        self.delays += 1
        self.events.append(('Delay', self.mem.r32(self.r(12) + self.eq['BC_DosBase'])))

    def x_Forbid(self):
        self.forbid += 1

    def x_Permit(self):
        self.forbid -= 1

    def x_AllocMem(self):
        size = self.r(0)
        addr = self.heap
        self.heap = (addr + size + len(GUARD) + 15) & ~15
        assert self.heap < HEAP_END, 'mock heap exhausted'
        self.mem.w_block(addr, bytes(size))
        self.mem.w_block(addr + size, GUARD)
        self.allocs[addr] = size
        self.d0(addr)

    def x_FreeMem(self):
        addr, size = self.r(9), self.r(0)
        if self.allocs.get(addr) != size:
            self.bad_frees.append((addr, size, self.allocs.get(addr)))
        self.allocs.pop(addr, None)
        if bytes(self.mem.r_block(addr + size, len(GUARD))) != GUARD:
            self.overruns.append(addr)

    def check_guards(self):
        """Allocations still live whose guard bytes were overwritten."""
        return [a for a, s in self.allocs.items()
                if bytes(self.mem.r_block(a + s, len(GUARD))) != GUARD]

    def x_AddTail(self):
        lst, node = self.r(8), self.r(9)
        pred = self.mem.r32(lst + 8)
        self.mem.w32(node, lst + 4)
        self.mem.w32(node + 4, pred)
        self.mem.w32(pred, node)
        self.mem.w32(lst + 8, node)

    def x_AddHead(self):
        lst, node = self.r(8), self.r(9)
        succ = self.mem.r32(lst)
        self.mem.w32(node, succ)
        self.mem.w32(node + 4, lst)
        self.mem.w32(succ + 4, node)
        self.mem.w32(lst, node)

    def x_Remove(self):
        node = self.r(9)
        succ, pred = self.mem.r32(node), self.mem.r32(node + 4)
        self.mem.w32(pred, succ)
        self.mem.w32(succ + 4, pred)

    def x_FindTask(self):
        self.d0(TASK)

    def x_AllocSignal(self):
        self.d0(16)

    def x_OpenResource(self):
        self.d0(self.res.get(self.cstr(self.r(9)), 0))

    def x_AddResource(self):
        node = self.r(9)
        self.res[self.cstr(self.mem.r32(node + 10))] = node

    def x_ObtainSemaphore(self):
        self.events.append('Obtain')

    def x_ReleaseSemaphore(self):
        self.events.append('Release')

    def x_AttemptSemaphore(self):
        self.events.append('Attempt')
        self.d0(1 if self.attempt_ok else 0)

    def x_OpenLibrary(self):
        self.d0(0)

    def x_RawPutChar(self):
        self.text.append(chr(self.r(0) & 0xFF))

    def x_OpenDevice(self):
        self.events.append(('OpenDevice', self.cstr(self.r(8)), self.r(0)))
        self.mem.w8(self.r(9) + IO_ERROR, 0)
        self.d0(0)

    def x_CloseDevice(self):
        self.events.append('CloseDevice')

    def x_DoIO(self):
        io = self.r(9)
        cmd = self.mem.r16(io + IO_COMMAND)
        length, data = self.mem.r32(io + IO_LENGTH), self.mem.r32(io + IO_DATA)
        offset = self.mem.r32(io + IO_OFFSET)
        disk, err, actual = self.disk, 0, 0
        if cmd not in disk.cmds:
            err = md.IOERR_NOCMD
            disk.log.append(('nocmd', cmd))
        elif cmd == md.TD_CHANGESTATE:
            actual = 0 if disk.present else 1
            disk.log.append(('changestate',))
        elif cmd == md.TD_GETGEOMETRY:
            disk.log.append(('geometry', length))
            if length != md.DG_SIZEOF or disk.geometry == 'error':
                err = md.IOERR_BADLENGTH if length != md.DG_SIZEOF else md.TDERR_NOTSPECIFIED
            else:
                size = disk.bs if disk.geometry is None else disk.geometry
                g = bytearray(md.DG_SIZEOF)
                for i, v in enumerate((size, disk.total, disk.total, 1, 1, 1, 1)):
                    g[i * 4:i * 4 + 4] = v.to_bytes(4, 'big')
                self.mem.w_block(data, bytes(g))
                actual = md.DG_SIZEOF
        elif cmd in (md.CMD_READ, md.TD_READ64, md.NSCMD_TD_READ64):
            hi = self.mem.r32(io + IO_ACTUAL) if cmd != md.CMD_READ else 0
            err, buf = disk.read(cmd, hi << 32 | offset, length)
            disk.log.append(('read', cmd, hi << 32 | offset, length, err))
            if not err:
                self.mem.w_block(data, buf)
                actual = length
        elif cmd == md.HD_SCSICMD:
            sdata, slen = self.mem.r32(data), self.mem.r32(data + 4)
            cdb = self.mem.r32(data + 12)
            op = self.mem.r8(cdb)
            if op == 0x28:
                lba, count = self.mem.r32(cdb + 2), self.mem.r16(cdb + 7)
            else:
                lba = ((self.mem.r8(cdb + 1) & 0x1F) << 16) | self.mem.r16(cdb + 2)
                count = self.mem.r8(cdb + 4) or 256
            err, buf = disk.read(cmd, lba * disk.bs, count * disk.bs)
            disk.log.append(('scsi', lba, count, slen, err))
            if not err:
                # A device transfers what the CDB asks for; scsi_Length is
                # only the caller's claim about its buffer.
                self.mem.w_block(sdata, buf)
                self.mem.w32(data + 8, len(buf))
        self.mem.w8(io + IO_ERROR, err & 0xFF)
        self.mem.w32(io + IO_ACTUAL, actual)
        self.d0(err)

    # -- LVO calls ----------------------------------------------------------
    def call(self, name, regs, limit=400):
        for i in range(16):
            self.cpu.w_reg(i, 0)
        for reg, value in regs.items():
            self.cpu.w_reg(reg, value & 0xFFFFFFFF)
        self.cpu.w_reg(14, LIBBASE)
        self.m.prepare(self.syms[name], STACK)
        for _ in range(limit):
            state = self.m.execute(200000)
            if self.m.was_exit(state):
                break
        else:
            raise AssertionError('%s did not return (pc=%x)' % (name, self.cpu.r_pc()))
        assert self.cpu.r_sp() == STACK, '%s left the stack unbalanced' % name
        assert self.forbid == 0, '%s left Forbid nested %d' % (name, self.forbid)
        return self.r(0)

    def scan(self, device='test.device', unit=0):
        self.mem.w_block(STRINGS, device.encode() + b'\0')
        return self.call('ScanPartitions', {9: STRINGS, 0: unit})

    # -- resource view ---------------------------------------------------------
    def resource(self):
        return self.res.get('partition.resource', 0)

    def rows(self):
        """Published PartEntry rows as dicts (fields by listing equates)."""
        eq, res, out = self.eq, self.resource(), []
        if not res:
            return out
        node = self.mem.r32(res + eq['PTR_PartList'])
        while self.mem.r32(node):
            nb = node + eq['pe_NameB']
            row = {'addr': node,
                   'name': bytes(self.mem.r_block(nb + 1, self.mem.r8(nb))).decode('latin1'),
                   'source': self.mem.r8(node + eq['pe_Source']),
                   'flags': self.mem.r8(node + eq['pe_Flags']),
                   'index': self.mem.r32(node + eq['pe_PartIndex']),
                   'start': self.mem.r32(node + eq['pe_StartLBA']),
                   'count': self.mem.r32(node + eq['pe_BlockCount']),
                   'dostype': self.mem.r32(node + eq['pe_DosType']),
                   'readmode': self.mem.r8(node + eq['pe_ReadMode']),
                   'length': self.mem.r16(node + eq['pe_Length']),
                   'envec': [self.mem.r32(node + eq['pe_Envec'] + 4 * i) for i in range(21)],
                   'raw': bytes(self.mem.r_block(node, eq['pe_Sizeof']))}
            out.append(row)
            node = self.mem.r32(node)
        return out

    def fs_entries(self):
        """FileSystem.resource entries as (address, DosType, Version, SegList BPTR)."""
        eq, res, out = self.eq, self.res.get('FileSystem.resource', 0), []
        if not res:
            return out
        node = self.mem.r32(res + eq['fsr_FileSysEntries'])
        while self.mem.r32(node):
            out.append((node, self.mem.r32(node + eq['fse_DosType']),
                        self.mem.r32(node + eq['fse_Version']),
                        self.mem.r32(node + eq['fse_SegList'])))
            node = self.mem.r32(node)
        return out

    def owned(self):
        """Allocations the resources legitimately keep: partition.resource with
        its rows and names, FileSystem.resource with its entries and the
        allocation behind each single-hunk SegList."""
        keep = set()
        res = self.resource()
        if res:
            keep.add(res)
            for row in self.rows():
                keep.add(row['addr'])
                keep.add(self.mem.r32(row['addr'] + self.eq['pe_Device']))
        fsr = self.res.get('FileSystem.resource', 0)
        if fsr:
            keep.add(fsr)
            for node, _, _, seglist in self.fs_entries():
                keep.add(node)
                keep.add(seglist * 4 - 4)
        return keep

    def leaks(self):
        return sorted(set(self.allocs) - self.owned())
