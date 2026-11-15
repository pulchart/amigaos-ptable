#!/usr/bin/env python3
"""Disk image builders for the device-level tests.

Every image is a sparse dict {native block number: bytes} for mockdev.Disk,
built in Python so the tests need no host partitioning tools. Layouts follow
the MBR/EBR and UEFI GPT formats and the NDK devices/hardblocks.i structures.
"""
import struct
import zlib

MS_BASIC = bytes.fromhex('a2a0d0ebe5b9334487c068b6b72699c7')
EFI_SYS = bytes.fromhex('28732ac11ff8d211ba4b00a0c93ec93b')
LINUX_FS = bytes.fromhex('af3dc60f838472478e793d69d8477de4')


# -- MBR / EBR -----------------------------------------------------------------
def mbr_slot(status, ptype, start, count):
    return struct.pack('<B3sB3sII', status, b'\0' * 3, ptype, b'\0' * 3, start, count)


def mbr(slots, boot=b'', sig=True, size=512):
    """Block 0 with up to four (status, type, start, count) slots."""
    b = bytearray(size)
    b[:len(boot)] = boot
    for i, s in enumerate(slots):
        b[446 + 16 * i:446 + 16 * (i + 1)] = mbr_slot(*s)
    if sig:
        b[510:512] = b'\x55\xaa'
    return bytes(b)


def mbr_disk(primaries, logicals=(), ext_start=0x10000, step=0x1000, size=512):
    """MBR plus an extended chain. logicals: [(type, count)]; EBR k sits at
    ext_start + k*step and its logical starts 64 blocks after it."""
    blocks = {}
    slots = list(primaries)
    if logicals:
        slots.append((0, 0x0F, ext_start, step * len(logicals)))
    blocks[0] = mbr(slots, size=size)
    for k, (ptype, count) in enumerate(logicals):
        link = []
        if k + 1 < len(logicals):
            link = [(0, 0x05, (k + 1) * step, step)]
        blocks[ext_start + k * step] = mbr([(0, ptype, 64, count)] + link, size=size)
    return blocks


# -- GPT -----------------------------------------------------------------------
def gpt_disk(entries, bs=512, total=1 << 20, n_entries=128, protective_slot=0,
             entry_size=128):
    """Protective MBR + primary header + entry array at native LBA 2.
    entries: [(type_guid, first_lba, last_lba)] at indexes 0.."""
    blocks = {}
    slots = [(0, 0, 0, 0)] * 4
    slots[protective_slot] = (0, 0xEE, 1, min(total - 1, 0xFFFFFFFF))
    blocks[0] = mbr(slots, size=bs)
    array = bytearray(n_entries * entry_size)
    for i, (guid, first, last) in enumerate(entries):
        e = struct.pack('<16s16sQQQ', guid, bytes([i + 1]) * 16, first, last, 0)
        array[i * entry_size:i * entry_size + len(e)] = e
    array_blocks = (len(array) + bs - 1) // bs
    hdr = bytearray(92)
    struct.pack_into('<8sIIIIQQQQ16sQIII', hdr, 0, b'EFI PART', 0x10000, 92, 0, 0,
                     1, total - 1, 2 + array_blocks, total - 2 - array_blocks,
                     b'\x11' * 16, 2, n_entries, entry_size, zlib.crc32(bytes(array)))
    struct.pack_into('<I', hdr, 16, zlib.crc32(bytes(hdr)))
    blocks[1] = bytes(hdr).ljust(bs, b'\0')
    for i in range(array_blocks):
        blocks[2 + i] = bytes(array[i * bs:(i + 1) * bs])
    return blocks


# -- FAT boot sector / foreign volume -------------------------------------------
def fat_boot(sector_size=512, total=0x10000, spc=4):
    """A FAT16 boot sector that passes _partIsBootBlock."""
    b = bytearray(512)
    b[0:3] = b'\xeb\x3c\x90'
    b[3:11] = b'MSDOS5.0'
    struct.pack_into('<HBHBHHBHHHII', b, 11, sector_size, spc, 1, 2, 512,
                     total if total < 0x10000 else 0, 0xF8, 64, 32, 2, 0,
                     total if total >= 0x10000 else 0)
    b[510:512] = b'\x55\xaa'
    return bytes(b)


def foreign_boot(oem=b'NOFAT   '):
    """A boot sector with $55AA but no FAT BPB and an empty slot table, the
    shape of a whole-device volume of another file system."""
    b = bytearray(512)
    b[0:3] = b'\xeb\x76\x90'
    b[3:11] = oem
    b[510:512] = b'\x55\xaa'
    return bytes(b)


# -- RDB -------------------------------------------------------------------------
def _checksum(block, summed):
    """Set the ChkSum long so the first summed longs add up to zero."""
    struct.pack_into('>I', block, 8, 0)
    total = sum(struct.unpack('>%dI' % summed, block[:summed * 4]))
    struct.pack_into('>I', block, 8, -total & 0xFFFFFFFF)


def _block(bs, ident, summed, fields):
    b = bytearray(bs)
    struct.pack_into('>4sI', b, 0, ident, summed)
    for off, fmt, value in fields:
        struct.pack_into(fmt, b, off, value)
    _checksum(b, summed)
    return b


def envec(low, high, dostype, surfaces=1, bpt=32, size_block=128, bootpri=0,
          table=16):
    v = [table, size_block, 0, surfaces, 1, bpt, 2, 0, 0, low, high, 30, 0,
         0x1FE00, 0x7FFFFFFE, bootpri, dostype]
    return v[:table + 1]


def rdb_disk(parts, bs=512, fs=None, rdb_at=0, summed=None):
    """parts: [(name, envec list, flags)]; fs: (dostype, version, payload,
    lseg_summed) or None. Block numbers are native device blocks."""
    summed = summed or bs // 4
    blocks, nxt = {}, rdb_at + 1
    part_blocks = list(range(nxt, nxt + len(parts)))
    nxt += len(parts)
    fshd = nxt if fs else 0xFFFFFFFF
    fields = [(16, '>I', bs), (20, '>I', 0), (24, '>I', 0xFFFFFFFF),
              (28, '>I', part_blocks[0] if parts else 0xFFFFFFFF), (32, '>I', fshd),
              (36, '>I', 0xFFFFFFFF)]
    blocks[rdb_at] = bytes(_block(bs, b'RDSK', min(64, summed), fields))
    for i, (name, env, flags) in enumerate(parts):
        f = [(16, '>I', part_blocks[i + 1] if i + 1 < len(parts) else 0xFFFFFFFF),
             (20, '>I', flags), (36, 'B', len(name)), (37, '%ds' % len(name), name.encode())]
        for j, v in enumerate(env):
            f.append((128 + 4 * j, '>I', v & 0xFFFFFFFF))
        blocks[part_blocks[i]] = bytes(_block(bs, b'PART', min(64, summed), f))
    if fs:
        dostype, version, payload, lseg_summed = fs
        lseg_first = fshd + 1
        per = (lseg_summed - 5) * 4
        chunks = [payload[i:i + per] for i in range(0, len(payload), per)] or [b'']
        f = [(16, '>I', 0xFFFFFFFF), (32, '>I', dostype), (36, '>I', version),
             (40, '>I', 0x180), (72, '>i', lseg_first), (76, '>i', -1)]
        blocks[fshd] = bytes(_block(bs, b'FSHD', min(64, summed), f))
        for k, chunk in enumerate(chunks):
            n = lseg_first + k + 1 if k + 1 < len(chunks) else 0xFFFFFFFF
            b = _block(bs, b'LSEG', lseg_summed, [(16, '>I', n), (20, '%ds' % len(chunk), chunk)])
            blocks[lseg_first + k] = bytes(b)
    return blocks
