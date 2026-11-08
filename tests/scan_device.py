#!/usr/bin/env python3
"""ScanPartitions end to end: the real LVO, a mocked Exec and a mock device.

Each case builds a medium, runs the library's scan through the device layer
(read-method probe, block reads, CHANGESTATE, the resource lock) and checks
the published rows. Case ids: A block size, C device I/O, E RDB blocks,
G media without a table, I 32-bit limits, J table walks.
OPEN lists the ids whose fix has not landed: their check must still fail, so
the suite stays green before and after each fix and the fixing commit removes
the id here.

Status: gated, run by make test.
Run from the repository root: python3 tests/scan_device.py"""
import struct
import sys

import images as im
import mockdev as md
from mockexec import Rig, builds

OPEN = {'A', 'C1', 'C2', 'E4', 'I', 'J-ee', 'J-max', 'J-gpt'}

FAT = 0x46415400
PES_MBR, PES_GPT, PES_RDB, PES_FLAT = 0, 1, 2, 3
PERM_NSCMD = 1


def scan(build, disk, device='test.device', unit=0, rig=None):
    rig = rig or Rig(build, disk)
    rig.scan(device, unit)
    return rig


def clean(rig):
    """No overruns, bad frees or leaks after a scan."""
    return not (rig.overruns or rig.check_guards() or rig.bad_frees or rig.leaks())


# -- baseline cases: must pass on every commit ---------------------------------
def c_mbr512(b):
    disk = md.Disk(im.mbr_disk([(0x80, 0x0C, 2048, 0x8000), (0, 0x06, 0x9000, 0x4000)]))
    rig = scan(b, disk)
    rows = [(r['source'], r['start'], r['count'], r['dostype']) for r in rig.rows()]
    return rows == [(PES_MBR, 2048, 0x8000, FAT), (PES_MBR, 0x9000, 0x4000, FAT)] and clean(rig)


def c_gpt512(b):
    disk = md.Disk(im.gpt_disk([(im.MS_BASIC, 2048, 0x9FFF), (im.LINUX_FS, 0xA000, 0xBFFF),
                                (im.MS_BASIC, 0xC000, 0xCFFF)]))
    rig = scan(b, disk)
    rows = [(r['source'], r['index'], r['start'], r['count']) for r in rig.rows()]
    return rows == [(PES_GPT, 0, 2048, 0x9800), (PES_GPT, 2, 0xC000, 0x1000)] and clean(rig)


def c_rdb512(b):
    disk = md.Disk(im.rdb_disk([('DH0', im.envec(2, 101, 0x444F5303), 1)]))
    rig = scan(b, disk)
    rows = [(r['source'], r['name'], r['start'], r['count']) for r in rig.rows()]
    return rows == [(PES_RDB, 'DH0', 64, 100 * 32)] and clean(rig)


def c_flat512(b):
    disk = md.Disk({0: im.fat_boot(total=0x20000)}, total=0x20000)
    rig = scan(b, disk)
    rows = [(r['source'], r['start'], r['count'], r['dostype']) for r in rig.rows()]
    return rows == [(PES_FLAT, 0, 0x20000, FAT)] and clean(rig)


def c_linux83(b):
    disk = md.Disk({0: im.mbr([(0, 0x83, 2048, 0x8000)])})
    rig = scan(b, disk)
    return rig.rows() == [] and clean(rig)


def c_rescan(b):
    disk = md.Disk(im.mbr_disk([(0, 0x0C, 2048, 0x8000)]))
    rig = scan(b, disk)
    first = rig.rows()
    rig.scan()
    return len(first) == 1 and [r['addr'] for r in rig.rows()] == [first[0]['addr']] and clean(rig)


# -- audit cases -------------------------------------------------------------
def c_gpt4k(b):
    """A: GPT on a 4096-byte device; rows in native blocks, no overrun."""
    disk = md.Disk(im.gpt_disk([(im.MS_BASIC, 256, 4351)], bs=4096, total=1 << 18), bs=4096,
                   total=1 << 18)
    rig = scan(b, disk)
    rows = [(r['start'], r['count']) for r in rig.rows()]
    return rows == [(256, 4096)] and clean(rig)


def c_rdb2048(b):
    """A: RDB with 2048-byte blocks on a 2048-byte device."""
    env = im.envec(2, 101, 0x444F5303, size_block=512)
    disk = md.Disk(im.rdb_disk([('DH0', env, 1)], bs=2048), bs=2048)
    rig = scan(b, disk)
    rows = [(r['name'], r['start'], r['count']) for r in rig.rows()]
    return rows == [('DH0', 64, 3200)] and clean(rig)


def c_carddisk2048(b):
    """A: CMD_READ-only device with 2048-byte blocks."""
    disk = md.Disk(im.mbr_disk([(0, 0x0C, 64, 0x1000)], size=2048), bs=2048, profile='carddisk')
    rig = scan(b, disk)
    return [(r['start'], r['count']) for r in rig.rows()] == [(64, 0x1000)] and clean(rig)


def c_blank(b):
    """G: a blank block 0, no signature: one whole-medium FAT row."""
    rig = scan(b, md.Disk({}, total=0x40000))
    rows = [(r['source'], r['start'], r['count'], r['dostype']) for r in rig.rows()]
    return rows == [(PES_FLAT, 0, 0x40000, FAT)] and clean(rig)


def c_amiga_flat(b):
    """G: an FFS superfloppy: a row of its DosType, the node over the medium."""
    rig = scan(b, md.Disk({0: b'DOS\x01' + bytes(508)}, total=0x1000))
    rows = [(r['source'], r['start'], r['count'], r['dostype']) for r in rig.rows()]
    env = rig.rows()[0]['envec'] if rows else []
    return (rows == [(PES_FLAT, 0, 0x1000, 0x444F5301)]
            and (env[9], env[10], env[16]) == (0, 0xFFF, 0x444F5301) and clean(rig))


def c_amiga_nosize(b):
    """G: an Amiga DosType row needs the medium size for its window."""
    rig = scan(b, md.Disk({0: b'DOS\x01' + bytes(508)}, total=0x1000, geometry='error'))
    return rig.rows() == [] and clean(rig)


def c_foreign(b):
    """G: $55AA, no FAT BPB, no MBR structure: one whole-medium FAT row."""
    disk = md.Disk({0: im.foreign_boot()}, total=0x40000)
    rig = scan(b, disk)
    rows = [(r['source'], r['start'], r['count'], r['dostype']) for r in rig.rows()]
    return rows == [(PES_FLAT, 0, 0x40000, FAT)] and clean(rig)


def c_fat4096(b):
    """G: FAT volume with 4096-byte logical sectors on a 512-byte device:
    the row covers the medium, not the BPB sector count."""
    disk = md.Disk({0: im.fat_boot(sector_size=4096, total=0x4000)}, total=0x20000)
    rig = scan(b, disk)
    return [(r['source'], r['count']) for r in rig.rows()] == [(PES_FLAT, 0x20000)] and clean(rig)


def c_bootcode(b):
    """G1: boot code over the slot table (status bytes neither 00 nor 80) is
    not an MBR."""
    blk = bytearray(im.mbr([]))
    blk[446:510] = bytes((0x4C + i * 7) & 0xFF for i in range(64))
    blk[446 + 4] = 0x0C                       # slot 0 type would be accepted
    disk = md.Disk({0: bytes(blk)}, total=0x40000)
    rig = scan(b, disk)
    return not [r for r in rig.rows() if r['source'] == PES_MBR] and clean(rig)


def c_cmd_high(b):
    """C1: on a CMD_READ-only device an EBR past 4 GiB is not read at
    offset mod 4 GiB."""
    far = 0x900000                             # byte offset 0x1_2000_0000
    blocks = im.mbr_disk([(0, 0x0C, 2048, 0x8000)], logicals=[(0x0C, 0x1000)],
                         ext_start=far)
    blocks[far & 0x7FFFFF] = im.mbr([(0, 0x0C, 64, 0x2222)])   # the wrapped block
    disk = md.Disk(blocks, total=far + 0x10000, profile='carddisk')
    rig = scan(b, disk)
    return not [r for r in rig.rows() if r['count'] == 0x2222] and clean(rig)


def c_first_fail(b):
    """C1: a transient error on the first read does not demote the method."""
    disk = md.Disk(im.mbr_disk([(0, 0x0C, 2048, 0x8000)]), nth_fail={md.NSCMD_TD_READ64: 1})
    rig = scan(b, disk)
    return [r['readmode'] for r in rig.rows()] == [PERM_NSCMD] and clean(rig)


def c_part_error(b):
    """C2: a read error on one PART block does not drop the other rows."""
    parts = [('DH%d' % i, im.envec(2 + 100 * i, 101 + 100 * i, 0x444F5303), 1) for i in range(3)]
    blocks = im.rdb_disk(parts)
    disk = md.Disk(blocks)
    rig = scan(b, disk)
    before = [r['name'] for r in rig.rows()]
    disk.inject[(md.NSCMD_TD_READ64, 2)] = md.TDERR_NOTSPECIFIED
    rig.scan()
    after = [r['name'] for r in rig.rows()]
    return before == ['DH0', 'DH1', 'DH2'] and after == before and clean(rig)


def c_nochangestate(b):
    """C3: a device without TD_CHANGESTATE is read, not polled as absent."""
    disk = md.Disk(im.mbr_disk([(0, 0x0C, 2048, 0x8000)]), profile='no_changestate')
    rig = scan(b, disk)
    return len(rig.rows()) == 1 and rig.delays == 0 and clean(rig)


def c_lock_order(b):
    """C4: the unit is opened before PTR_Lock is taken."""
    disk = md.Disk(im.mbr_disk([(0, 0x0C, 2048, 0x8000)]))
    rig = scan(b, disk)
    seq = [e if isinstance(e, str) else e[0] for e in rig.events
           if e in ('Obtain',) or (isinstance(e, tuple) and e[0] == 'OpenDevice')]
    return seq[:2] == ['OpenDevice', 'Obtain'] and clean(rig)


def c_torn_part(b):
    """E4: a PART block with a bad checksum is not published."""
    blocks = im.rdb_disk([('DH0', im.envec(2, 101, 0x444F5303), 1),
                          ('DH1', im.envec(102, 201, 0x444F5303), 1)])
    torn = bytearray(blocks[2])
    torn[200] ^= 0xFF
    blocks[2] = bytes(torn)
    rig = scan(b, md.Disk(blocks))
    return [r['name'] for r in rig.rows()] == ['DH0'] and clean(rig)


def c_rdb_overflow(b):
    """I: an RDB partition whose start does not fit 32 bits is not published."""
    env = im.envec(0x00200000, 0x00200010, 0x444F5303, surfaces=16, bpt=255)
    rig = scan(b, md.Disk(im.rdb_disk([('DH0', env, 1)])))
    return rig.rows() == [] and clean(rig)


def c_ee_slot1(b):
    """J-ee: a hybrid MBR with the protective entry in slot 1 is read as GPT."""
    blocks = im.gpt_disk([(im.MS_BASIC, 2048, 4095), (im.MS_BASIC, 4096, 8191)],
                         protective_slot=1)
    blk = bytearray(blocks[0])
    blk[446:462] = im.mbr_slot(0, 0x0C, 2048, 2048)
    blocks[0] = bytes(blk)
    rig = scan(b, md.Disk(blocks))
    return [r['source'] for r in rig.rows()] == [PES_GPT, PES_GPT] and clean(rig)


def c_max_rec(b):
    """J-max: every FAT logical of a long extended chain is published."""
    logicals = [(0x0C, 0x800)] * 14
    rig = scan(b, md.Disk(im.mbr_disk([(0, 0x0C, 2048, 0x8000)], logicals=logicals)))
    return len(rig.rows()) == 15 and clean(rig)


def c_gpt_reads(b):
    """J-gpt: entries sharing one block cost one read of that block."""
    disk = md.Disk(im.gpt_disk([(im.MS_BASIC, 2048 + i * 2048, 4095 + i * 2048)
                                for i in range(4)]))
    rig = scan(b, disk)
    reads = [e for e in disk.log if e[0] == 'read' and e[2] == 2 * 512]
    return len(rig.rows()) == 4 and len(reads) == 1 and clean(rig)


CASES = [
    (None, 'mbr 512', c_mbr512), (None, 'gpt 512', c_gpt512), (None, 'rdb 512', c_rdb512),
    (None, 'superfloppy 512', c_flat512), (None, 'linux-only mbr', c_linux83),
    (None, 'rescan reuses rows', c_rescan),
    ('A', 'gpt 4096-byte device', c_gpt4k), ('A', 'rdb 2048-byte blocks', c_rdb2048),
    ('A', 'cmd-only 2048-byte device', c_carddisk2048),
    ('G', 'whole medium, no table, no bpb', c_foreign), (None, 'blank medium: one fat row', c_blank),
    (None, 'ffs superfloppy row', c_amiga_flat), (None, 'superfloppy of unknown size', c_amiga_nosize), ('G', 'fat -S 4096 superfloppy', c_fat4096),
    ('G1', 'boot code over the slot table', c_bootcode),
    ('C1', 'cmd_read past 4 GiB', c_cmd_high), ('C1', 'transient first read', c_first_fail),
    ('C2', 'part read error keeps rows', c_part_error), ('C3', 'no td_changestate', c_nochangestate),
    ('C4', 'open before lock', c_lock_order), ('E4', 'torn part block', c_torn_part),
    ('I', 'rdb start overflow', c_rdb_overflow), ('J-ee', 'protective entry in slot 1', c_ee_slot1),
    ('J-max', 'more than 12 logicals', c_max_rec), ('J-gpt', 'gpt entry block read once', c_gpt_reads),
]


def main():
    failures = []
    for build in builds():
        for ident, label, fn in CASES:
            try:
                ok = bool(fn(build))
            except AssertionError as e:
                ok, label = False, '%s (%s)' % (label, e)
            want = ident not in OPEN
            if ok != want:
                failures.append('%s %s [%s]: %s' % (build.name, label, ident or 'base',
                                                    'passes, remove from OPEN' if ok else 'FAILS'))
            print('%-11s %-5s %-34s %s' % (build.name, ident or '-', label[:34],
                                            'ok' if ok else 'open'))
    for f in failures:
        print('FAIL', f)
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
