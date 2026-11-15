#!/usr/bin/env python3
"""MountPartitions end to end: scan a mock device, then mount its rows.

The real ScanPartitions, MountPartitions and MarkAbsent LVOs run on a mocked
Exec with a mocked expansion.library (AddDosNode), the DOS device list and
FileSystem.resource. Case ids: E RDB filesystems, F node adoption and static
mounts, K caller strings. OPEN lists the ids whose fix has not landed: their
check must still fail, and the fixing commit removes the id here.

Status: gated, run by make test.
Run from the repository root: python3 tests/mount_device.py"""
import struct
import sys

import images as im
import mockdev as md
from mockexec import Rig, builds, STATIC

OPEN = {'E1', 'E2', 'F2', 'F3'}

FAT, MARKER, DOS0, DOS1, DOS3, PFS3 = (0x46415400, 0x464154FF, 0x444F5300, 0x444F5301,
                                       0x444F5303, 0x50465303)
CFG = STATIC + 0x8000


def rig_for(b, blocks, **kw):
    return Rig(b, md.Disk(blocks, **kw))


def mounted(rig):
    return [(r['name'], bool(r['flags'] & 8)) for r in rig.rows()]


def adds(rig):
    return [e for e in rig.events if isinstance(e, tuple) and e[0] == 'AddDosNode']


def clean(rig):
    return not (rig.overruns or rig.check_guards() or rig.bad_frees or rig.leaks())


def with_fat_handler(rig):
    rig.add_fs_entry(MARKER, 0x00040001)


def cfg(rig, handler=None, node_dostype=0):
    eq = rig.eq
    rig.mem.w_block(CFG, bytes(eq['mc_UnmFlags'] + 4))
    if handler:
        rig.mem.w32(CFG + eq['mc_NodeHandler'], rig.bstr(handler) + 1)
    rig.mem.w32(CFG + eq['mc_NodeDosType'], node_dostype)
    rig.mem.w32(CFG + eq['mc_Size'], eq['mc_UnmFlags'] + 4)
    return CFG


def rdb(parts, **kw):
    return im.rdb_disk([(n, im.envec(lo, hi, dt), 1) for n, lo, hi, dt in parts], **kw)


# -- baseline -----------------------------------------------------------------
def c_mount_mbr(b):
    rig = rig_for(b, im.mbr_disk([(0, 0x0C, 2048, 0x8000), (0, 0x0C, 0x9000, 0x4000)]))
    with_fat_handler(rig)
    rig.scan()
    n = rig.mount()
    nodes = [(d['name'], d['low'], d['dostype']) for d in rig.dos_nodes()]
    return (n == 2 and mounted(rig) == [('TESTa0', True), ('TESTa1', True)]
            and sorted(nodes) == [('TESTa0', 0, MARKER), ('TESTa1', 0, MARKER)] and clean(rig))


def c_mount_rdb(b):
    rig = rig_for(b, rdb([('DH0', 2, 101, DOS3)]))
    rig.add_fs_entry(DOS3, 0x00280001)
    rig.scan()
    n = rig.mount()
    nodes = [(d['name'], d['low'], d['high'], d['dostype']) for d in rig.dos_nodes()]
    return n == 1 and nodes == [('DH0', 2, 101, DOS3)] and clean(rig)


def c_remount_same(b):
    """A second pass over mounted rows builds nothing."""
    rig = rig_for(b, im.mbr_disk([(0, 0x0C, 2048, 0x8000)]))
    with_fat_handler(rig)
    rig.scan()
    rig.mount()
    n = rig.mount()
    return n == 0 and len(adds(rig)) == 1


# -- audit cases ----------------------------------------------------------------
def c_absent_not_mounted(b):
    """F4: rows marked absent are not mounted."""
    rig = rig_for(b, im.mbr_disk([(0, 0x0C, 2048, 0x8000), (0, 0x0C, 0x9000, 0x4000)]))
    with_fat_handler(rig)
    rig.scan()
    rig.mark_absent()
    n = rig.mount()
    return n == 0 and adds(rig) == []


def c_no_leak_idle(b):
    """F5: a mount pass that builds no node leaks nothing."""
    rig = rig_for(b, im.mbr_disk([(0, 0x0C, 2048, 0x8000)]))
    with_fat_handler(rig)
    rig.scan()
    rig.mount()
    rig.mount()
    return clean(rig)


def c_long_handler(b):
    """K: a handler path longer than the node holds fails the bind."""
    rig = rig_for(b, im.mbr_disk([(0, 0x0C, 2048, 0x8000)]))
    rig.scan()
    n = rig.mount(cfg(rig, handler='L:a-handler-path-that-is-too-long'))
    return n == 0 and adds(rig) == [] and mounted(rig) == [('TESTa0', False)] and clean(rig)


def c_dos0(b):
    """E2: an RDB DOS\\0 partition mounts as an unpatched node."""
    rig = rig_for(b, rdb([('DH0', 2, 101, DOS0)]))
    for i in range(1, 6):
        rig.add_fs_entry(DOS0 | i, 0x00280001)
    rig.scan()
    n = rig.mount()
    nodes = [(d['name'], d['seglist'], d['dostype']) for d in rig.dos_nodes()]
    return n == 1 and nodes == [('DH0', 0, DOS0)] and clean(rig)


def c_fshd_newer(b):
    """E1: a newer filesystem in the RDB replaces the resident one."""
    payload = bytes(range(256)) * 2
    rig = rig_for(b, rdb([('DH0', 2, 101, PFS3)], fs=(PFS3, 0x00130002, payload, 128)))
    rig.add_fs_entry(PFS3, 0x00120000)
    rig.scan()
    entries = [(dt, v) for _, dt, v, _ in rig.fs_entries()]
    return entries[:1] == [(PFS3, 0x00130002)] and clean(rig)


def c_fshd_older(b):
    """A filesystem in the RDB older than the resident one is not loaded."""
    payload = bytes(range(256)) * 2
    rig = rig_for(b, rdb([('DH0', 2, 101, PFS3)], fs=(PFS3, 0x00110000, payload, 128)))
    rig.add_fs_entry(PFS3, 0x00120000)
    rig.scan()
    return [(dt, v) for _, dt, v, _ in rig.fs_entries()] == [(PFS3, 0x00120000)] and clean(rig)


def c_static_overlap(b):
    """F2: a hand-mounted node over a partition's blocks is recorded, not
    doubled by a second handler."""
    rig = rig_for(b, rdb([('DH0', 2, 101, DOS3), ('DH1', 102, 201, PFS3)]))
    rig.add_fs_entry(DOS3, 0x00280001)
    rig.add_fs_entry(PFS3, 0x00130002)
    static = rig.add_static_node('PFSCF', 'test.device', 0, 102, 201, PFS3, bpt=32)
    rig.scan()
    rig.mount()
    rows = {r['name']: r for r in rig.rows()}
    dh1 = rows['DH1']
    node = rig.mem.r32(dh1['addr'] + rig.eq['pe_DevNode'])
    names = sorted(d['name'] for d in rig.dos_nodes())
    return names == ['DH0', 'PFSCF'] and node == static and bool(dh1['flags'] & 8) and clean(rig)


def c_card_swap(b):
    """F3: a mounted RDB row whose partition changed size on a new card is
    not refreshed in place under its old node."""
    disk = md.Disk(rdb([('DH0', 2, 101, DOS3)]))
    rig = Rig(b, disk)
    rig.add_fs_entry(DOS3, 0x00280001)
    rig.scan()
    rig.mount()
    first = rig.rows()[0]['addr']
    disk.blocks = rdb([('DH0', 2, 301, DOS3)])
    rig.scan()
    rows = rig.rows()
    old = [r for r in rows if r['addr'] == first]
    fresh = [r for r in rows if r['addr'] != first]
    return (len(old) == 1 and old[0]['flags'] & 0x10 and not old[0]['flags'] & 1
            and len(fresh) == 1 and fresh[0]['count'] == 300 * 32 and fresh[0]['flags'] & 1)


CASES = [
    (None, 'mount mbr', c_mount_mbr), (None, 'mount rdb', c_mount_rdb),
    (None, 'second pass builds nothing', c_remount_same),
    (None, 'older rdb filesystem not loaded', c_fshd_older),
    ('F4', 'absent rows not mounted', c_absent_not_mounted),
    ('F5', 'idle mount pass leaks nothing', c_no_leak_idle),
    ('K', 'long handler path fails', c_long_handler),
    ('E2', 'rdb dos\\0 mounts unpatched', c_dos0),
    ('E1', 'newer rdb filesystem loaded', c_fshd_newer),
    ('F2', 'static node over a partition', c_static_overlap),
    ('F3', 'card swap with a changed rdb', c_card_swap),
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
