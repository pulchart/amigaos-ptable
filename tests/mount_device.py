#!/usr/bin/env python3
"""MountPartitions end to end: scan a mock device, then mount its rows.

The real ScanPartitions, MountPartitions and MarkAbsent LVOs run on a mocked
Exec with a mocked expansion.library (AddDosNode), the DOS device list and
FileSystem.resource. Case ids: D handler binding rows, E RDB filesystems,
F node adoption and static mounts, K caller strings. OPEN lists the ids whose fix has not landed: their
check must still fail, and the fixing commit removes the id here.

Status: gated, run by make test.
Run from the repository root: python3 tests/mount_device.py"""
import struct
import sys

import images as im
import mockdev as md
from mockexec import Rig, builds, STATIC

OPEN = set()

FAT, MARKER, DOS0, DOS1, DOS3, PFS3 = (0x46415400, 0x464154FF, 0x444F5300, 0x444F5301,
                                       0x444F5303, 0x50465303)
SFS0, MSD0 = 0x53465300, 0x4D534400
PES_MBR, PES_RDB = 0, 2
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


def binds(rig, rows, size=None, handler=None):
    """A MountCfg with binding rows: dicts of prefix, sources, force, pri,
    dostype, handler, stack."""
    eq = rig.eq
    assert 'mc_Binds' in eq, 'no binding table in this build'
    base = cfg(rig, handler=handler)
    rig.mem.w_block(base + eq['mc_UnmFlags'] + 4, bytes(eq['mc_BindSize'] - eq['mc_UnmFlags']))
    size_row = eq['bnd_Sizeof']
    table = rig.alloc_static(size_row * len(rows))
    for i, r in enumerate(rows):
        a = table + i * size_row
        rig.mem.w_block(a, bytes(size_row))
        rig.mem.w32(a + eq['bnd_Prefix'], r.get('prefix', 0))
        rig.mem.w8(a + eq['bnd_Sources'], r.get('sources', 0))
        flags = ((1 << eq['BNDB_FORCE']) if r.get('force') else 0) | \
                ((1 << eq['BNDB_PRI']) if 'pri' in r else 0)
        rig.mem.w8(a + eq['bnd_Flags'], flags)
        rig.mem.w32(a + eq['bnd_DosType'], r.get('dostype', 0))
        if r.get('handler'):
            rig.mem.w32(a + eq['bnd_Handler'], rig.bstr(r['handler']) + 1)
        rig.mem.w32(a + eq['bnd_Stack'], r.get('stack', 0))
        rig.mem.w32(a + eq['bnd_Pri'], r.get('pri', 0) & 0xFFFFFFFF)
    rig.mem.w32(base + eq['mc_Binds'], table)
    rig.mem.w32(base + eq['mc_BindCount'], len(rows))
    rig.mem.w32(base + eq['mc_BindSize'], size_row)
    rig.mem.w32(base + eq['mc_Size'], size or eq['mc_BindSize'] + 4)
    return base


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


def c_own_device_name(b):
    """Each node carries its own device-name BSTR inside its blob."""
    rig = rig_for(b, im.mbr_disk([(0, 0x0C, 2048, 0x8000), (0, 0x0C, 0x9000, 0x4000)]))
    with_fat_handler(rig)
    rig.scan()
    rig.mount()
    blobs = {r['name']: rig.mem.r32(r['addr'] + rig.eq['pe_BlobPtr']) for r in rig.rows()}
    out = []
    for d in rig.dos_nodes():
        blob, dev = blobs[d['name']], d['device']
        size = rig.mem.r32([r for r in rig.rows() if r['name'] == d['name']][0]['addr']
                           + rig.eq['pe_BlobSize'])
        name = bytes(rig.mem.r_block(dev + 1, rig.mem.r8(dev))).decode()
        out.append(blob < dev and dev + 1 + len(name) <= blob + size and name == 'test.device')
    return out == [True, True] and clean(rig)


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


def c_static_overlap_4k(b):
    """F2: on a 4096-byte device the hand mount's window is compared in the
    same units as the row."""
    rig = rig_for(b, im.mbr_disk([(0, 0x0C, 256, 0x1000)], size=4096), bs=4096, total=0x10000)
    with_fat_handler(rig)
    # 512-byte envec blocks: blocks 2048..34815 are device blocks 256..4351
    static = rig.add_static_node('HAND', 'test.device', 0, 2048, 34815, 0x4D534400)
    rig.scan()
    rig.mount()
    row = rig.rows()[0]
    return adds(rig) == [] and rig.mem.r32(row['addr'] + rig.eq['pe_DevNode']) == static and clean(rig)


def c_static_elsewhere(b):
    """F2: hand-mounted nodes on another unit, past the partition, on
    auto-detect, or with a port-handler startup leave the mount alone."""
    rig = rig_for(b, rdb([('DH0', 2, 101, DOS3)]))
    rig.add_fs_entry(DOS3, 0x00280001)
    rig.add_fs_entry(MARKER, 0x00040001)
    rig.add_static_node('OTHER', 'test.device', 1, 2, 101, DOS3, bpt=32)
    rig.add_static_node('PAST', 'test.device', 0, 200, 300, DOS3, bpt=32)
    rig.add_static_node('AUTO', 'test.device', 0, 0, 0xFFFF, MARKER)
    port = rig.add_static_node('SER', 'test.device', 0, 2, 101, DOS3, bpt=32)
    rig.mem.w32(port + 28, 1)                  # dn_Startup = 1, not an FSSM
    rig.scan()
    n = rig.mount()
    return n == 1 and len(adds(rig)) == 1 and mounted(rig) == [('DH0', True)] and clean(rig)


def c_static_mountused(b):
    """F2: MCUF_MOUNTUSED lets the mount build its node over a hand mount."""
    rig = rig_for(b, rdb([('DH0', 2, 101, DOS3)]))
    rig.add_fs_entry(DOS3, 0x00280001)
    rig.add_static_node('HAND', 'test.device', 0, 2, 101, DOS3, bpt=32)
    rig.scan()
    c = cfg(rig)
    rig.mem.w32(c + rig.eq['mc_UnmFlags'], 1 << rig.eq['MCUF_MOUNTUSED'])
    n = rig.mount(c)
    return n == 1 and len(adds(rig)) == 1 and clean(rig)


def c_reuse_fat_only(b):
    """F1: a same-named LowCyl 0 node of another filesystem is not reused as
    an auto-detect node; it is the partition's static mount."""
    rig = rig_for(b, im.mbr_disk([(0, 0x0C, 2048, 0x8000)]))
    with_fat_handler(rig)
    node = rig.add_static_node('TESTa0', 'test.device', 0, 0, 0xFFFFF, 0x4D534400)
    rig.scan()
    n = rig.mount()
    row = rig.rows()[0]
    nb = row['addr'] + rig.eq['pe_MountName']
    name = bytes(rig.mem.r_block(nb + 1, rig.mem.r8(nb))).decode()
    return (n == 0 and adds(rig) == [] and rig.mem.r32(row['addr'] + rig.eq['pe_DevNode']) == node
            and name == 'TESTa0' and clean(rig))


def c_reuse_fat(b):
    """A same-named auto-detect FAT node is reused."""
    rig = rig_for(b, im.mbr_disk([(0, 0x0C, 2048, 0x8000)]))
    with_fat_handler(rig)
    node = rig.add_static_node('TESTa0', 'test.device', 0, 0, 0xFFFFF, MARKER)
    rig.scan()
    n = rig.mount()
    return n == 1 and adds(rig) == [] and rig.mem.r32(rig.rows()[0]['addr'] + rig.eq['pe_DevNode']) == node


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
    swapped = (len(old) == 1 and old[0]['flags'] & 0x10 and not old[0]['flags'] & 1
               and len(fresh) == 1 and fresh[0]['count'] == 300 * 32 and fresh[0]['flags'] & 1)
    # A rescan of the new card adds nothing; the first card back takes its
    # mounted row again and the other row goes.
    rig.scan()
    again = [r['addr'] for r in rig.rows()] == [r['addr'] for r in rows]
    disk.blocks = rdb([('DH0', 2, 101, DOS3)])
    rig.scan()
    back = [(r['addr'], r['flags'] & 0x19) for r in rig.rows()] == [(first, 9)]
    return swapped and again and back and clean(rig)


def ffs_floppy():
    return {0: b'DOS\x01' + bytes(508)}


def c_ffs_floppy(b):
    """An FFS superfloppy mounts on FFS over the whole medium."""
    rig = Rig(b, md.Disk(ffs_floppy(), total=0x1000))
    rig.add_fs_entry(DOS1, 0x00280001)
    rig.scan()
    n = rig.mount()
    nodes = [(d['low'], d['high'], d['dostype'], d['seglist']) for d in rig.dos_nodes()]
    return n == 1 and nodes == [(0, 0xFFF, DOS1, 0x1234)] and clean(rig)


def swap(rig, disk, blocks, total):
    """Card out (MarkAbsent keeps the nodes), another card in."""
    rig.mark_absent()
    disk.blocks, disk.total = blocks, total
    rig.scan()
    rig.mount()
    return [(r['dostype'], r['count'], r['flags'] & 0x19) for r in rig.rows()]


def c_swap_fat_ffs(b):
    """A FAT stick's mounted row is not turned into the FFS superfloppy's row
    under the FAT node; the superfloppy gets a row and an FFS node."""
    disk = md.Disk({0: im.fat_boot(total=0x2000)}, total=0x2000)
    rig = Rig(b, disk)
    with_fat_handler(rig)
    rig.add_fs_entry(DOS1, 0x00280001)
    rig.scan()
    rig.mount()
    rows = swap(rig, disk, ffs_floppy(), 0x1000)
    dts = sorted(d['dostype'] for d in rig.dos_nodes())
    back = swap(rig, disk, {0: im.fat_boot(total=0x2000)}, 0x2000)
    return (rows == [(FAT, 0x2000, 0x18), (DOS1, 0x1000, 9)] and dts == sorted([MARKER, DOS1])
            and back == [(FAT, 0x2000, 9), (DOS1, 0x1000, 0x18)])


def c_swap_ffs_size(b):
    """A mounted FFS superfloppy row is not resized under its fixed window."""
    disk = md.Disk(ffs_floppy(), total=0x1000)
    rig = Rig(b, disk)
    rig.add_fs_entry(DOS1, 0x00280001)
    rig.scan()
    rig.mount()
    rows = swap(rig, disk, ffs_floppy(), 0x2000)
    windows = sorted(d['high'] for d in rig.dos_nodes())
    return rows == [(DOS1, 0x1000, 0x18), (DOS1, 0x2000, 9)] and windows == [0xFFF, 0x1FFF]


# -- binding rows ----------------------------------------------------------------
FAT_MBR = [(0, 0x0C, 2048, 0x8000)]


def node(rig):
    nodes = rig.dos_nodes()
    assert len(nodes) == 1, nodes
    return nodes[0]


def c_bind_rdb_path(b):
    """D: an RDB partition without a FileSysEntry mounts by a row's path."""
    rig = rig_for(b, rdb([('DH0', 2, 101, SFS0)]))
    rig.scan()
    n = rig.mount(binds(rig, [dict(prefix=SFS0, handler='L:SmartFilesystem')]))
    d = node(rig)
    return (n == 1 and (d['handler'], d['seglist'], d['low'], d['high'], d['dostype'])
            == ('L:SmartFilesystem', 0, 2, 101, SFS0) and clean(rig))


def c_bind_rdb_no_dostype(b):
    """D: a row's DosType and window never apply to an RDB partition."""
    rig = rig_for(b, rdb([('DH0', 2, 101, SFS0)]))
    rig.scan()
    rig.mount(binds(rig, [dict(prefix=SFS0, handler='L:SFS', dostype=MSD0)]))
    d = node(rig)
    return (d['low'], d['high'], d['dostype']) == (2, 101, SFS0)


def c_bind_force(b):
    """D: FORCE takes the row's path over a FileSysEntry."""
    rig = rig_for(b, im.mbr_disk(FAT_MBR))
    with_fat_handler(rig)
    rig.scan()
    rig.mount(binds(rig, [dict(prefix=FAT, handler='L:fat95', force=True)]))
    d = node(rig)
    return (d['handler'], d['seglist']) == ('L:fat95', 0) and clean(rig)


def c_bind_noforce(b):
    """D: without FORCE a FileSysEntry wins over the row's path."""
    rig = rig_for(b, im.mbr_disk(FAT_MBR))
    with_fat_handler(rig)
    rig.scan()
    rig.mount(binds(rig, [dict(prefix=FAT, handler='L:fat95')]))
    d = node(rig)
    return (d['handler'], d['seglist']) == (None, 0x1234)


def c_bind_stack_pri(b):
    """D: the row's stack is a floor over the patched node, its priority is set."""
    rig = rig_for(b, im.mbr_disk(FAT_MBR + [(0, 0x0C, 0x9000, 0x4000)]))
    with_fat_handler(rig)
    rig.scan()
    rig.mount(binds(rig, [dict(prefix=FAT, stack=16384, pri=-3)]))
    big = [(d['stack'], d['pri']) for d in rig.dos_nodes()]
    rig2 = rig_for(b, im.mbr_disk(FAT_MBR))
    with_fat_handler(rig2)
    rig2.scan()
    rig2.mount(binds(rig2, [dict(prefix=FAT, stack=2000)]))
    small = node(rig2)
    return big == [(16384, 0xFFFFFFFD)] * 2 and (small['stack'], small['pri']) == (4000, 5)


def c_bind_sources(b):
    """D: a source mask limits the row to those tables; prefix 0 matches any."""
    rig = rig_for(b, rdb([('DH0', 2, 101, SFS0)]))
    rig.scan()
    n = rig.mount(binds(rig, [dict(sources=1 << PES_MBR, handler='L:x')]))
    other = n == 0 and mounted(rig) == [('DH0', False)]
    rig2 = rig_for(b, rdb([('DH0', 2, 101, SFS0)]))
    rig2.scan()
    n2 = rig2.mount(binds(rig2, [dict(sources=1 << PES_RDB, handler='L:y')]))
    return other and n2 == 1 and node(rig2)['handler'] == 'L:y'


def c_bind_first(b):
    """D: the first matching row wins."""
    rig = rig_for(b, im.mbr_disk(FAT_MBR))
    rig.scan()
    rig.mount(binds(rig, [dict(prefix=SFS0, handler='L:s'), dict(prefix=FAT, handler='L:a'),
                          dict(prefix=FAT, handler='L:b')]))
    return node(rig)['handler'] == 'L:a'


def c_bind_implicit(b):
    """D: with no matching row, mc_NodeHandler still serves a FAT partition."""
    rig = rig_for(b, im.mbr_disk(FAT_MBR))
    rig.scan()
    rig.mount(binds(rig, [dict(prefix=SFS0, handler='L:s')], handler='L:fallback'))
    return node(rig)['handler'] == 'L:fallback'


def c_bind_dostype(b):
    """D: a row's DosType on an MBR partition gives a fixed window."""
    rig = rig_for(b, im.mbr_disk(FAT_MBR))
    rig.scan()
    rig.mount(binds(rig, [dict(prefix=FAT, dostype=MSD0, handler='L:CrossDOSFileSystem')]))
    d = node(rig)
    return ((d['dostype'], d['low'], d['high'], d['handler'])
            == (MSD0, 2048, 2048 + 0x8000 - 1, 'L:CrossDOSFileSystem') and clean(rig))


def c_bind_old_size(b):
    """A MountCfg of 28 bytes has no binding table."""
    rig = rig_for(b, im.mbr_disk(FAT_MBR))
    with_fat_handler(rig)
    rig.scan()
    base = cfg(rig)
    rig.mem.w_block(base + 28, struct.pack('>III', STATIC + 0x9000, 1, 24))
    rig.mem.w32(STATIC + 0x9000, FAT)
    rig.mem.w32(STATIC + 0x9000 + 12, rig.bstr('L:x') + 1)
    rig.mem.w8(STATIC + 0x9000 + 5, 1)
    rig.mount(base)
    d = node(rig)
    return (d['handler'], d['seglist']) == (None, 0x1234)


# -- filesystem type ----------------------------------------------------------
def c_fs_type(b):
    """The registrant records its filesystem name; another node cannot, and a
    new registration and UnregisterPartition clear it."""
    from mockexec import STRINGS
    rig = rig_for(b, im.mbr_disk([(0, 0x0C, 2048, 0x8000)]))
    with_fat_handler(rig)
    rig.scan()
    rig.mount()
    eq = rig.eq
    row = rig.rows()[0]
    node = rig.mem.r32(row['addr'] + eq['pe_DevNode'])
    name = lambda: bytes(rig.mem.r_block(row['addr'] + eq['pe_FsName'], 8))
    text = rig.alloc_static(16)

    def set_fs(dev_node, fs):
        rig.mem.w_block(STRINGS, b'test.device\0')
        if fs is not None:
            rig.mem.w_block(text, fs + b'\0')
        return rig.call('SetPartitionFs', {9: STRINGS, 0: 0, 1: 2048, 10: dev_node,
                                           8: text if fs is not None else 0})
    ok = set_fs(node, b'FAT32') == 1 and name() == b'FAT32\0\0\0'
    other = set_fs(node + 4, b'FAT16') == 0 and name() == b'FAT32\0\0\0'
    longer = set_fs(node, b'LongerName') == 1 and name() == b'LongerNa'
    gone = set_fs(node, None) == 1 and name() == bytes(8)
    bstr = rig.bstr('CF0')
    set_fs(node, b'exFAT')
    rig.mem.w_block(STRINGS, b'test.device\0')
    rig.call('RegisterPartition', {9: STRINGS, 0: 0, 1: 2048, 2: 0x8000, 8: bstr,
                                   10: node, 3: 0, 4: 0, 5: 0})
    cleared_reg = name() == bytes(8)
    set_fs(node, b'FAT12')
    rig.mem.w_block(STRINGS, b'test.device\0')
    rig.call('UnregisterPartition', {9: STRINGS, 0: 0, 1: 2048, 10: node})
    cleared_unreg = name() == bytes(8)
    return ok and other and longer and gone and cleared_reg and cleared_unreg and clean(rig)

CASES = [
    (None, 'mount mbr', c_mount_mbr), (None, 'mount rdb', c_mount_rdb),
    (None, 'second pass builds nothing', c_remount_same),
    ('F5', 'node owns its device name', c_own_device_name),
    (None, 'older rdb filesystem not loaded', c_fshd_older),
    ('F4', 'absent rows not mounted', c_absent_not_mounted),
    ('F5', 'idle mount pass leaks nothing', c_no_leak_idle),
    ('K', 'long handler path fails', c_long_handler),
    ('E2', 'rdb dos\\0 mounts unpatched', c_dos0),
    ('E1', 'newer rdb filesystem loaded', c_fshd_newer),
    ('F2', 'static node over a partition', c_static_overlap),
    (None, 'unrelated hand mounts ignored', c_static_elsewhere),
    (None, 'hand mount over a 4096-byte row', c_static_overlap_4k),
    (None, 'mount_used builds over a hand mount', c_static_mountused),
    (None, 'same-named fat node reused', c_reuse_fat),
    ('F1', 'same-named other fs not reused', c_reuse_fat_only),
    ('F3', 'card swap with a changed rdb', c_card_swap),
    (None, 'ffs superfloppy mounts on ffs', c_ffs_floppy),
    ('F3', 'swap fat stick to ffs superfloppy', c_swap_fat_ffs),
    ('F3', 'swap to a larger ffs superfloppy', c_swap_ffs_size),
    (None, 'mountcfg of 28 bytes: no rows', c_bind_old_size),
    (None, 'filesystem name from the registrant', c_fs_type),
    ('D', 'rdb partition bound by path', c_bind_rdb_path),
    ('D', 'rdb row keeps its dostype', c_bind_rdb_no_dostype),
    ('D', 'force: path over filesysentry', c_bind_force),
    (None, 'no force: filesysentry wins', c_bind_noforce),
    ('D', 'stack floor and priority', c_bind_stack_pri),
    ('D', 'source mask', c_bind_sources),
    ('D', 'first matching row wins', c_bind_first),
    (None, 'no row: mc_NodeHandler', c_bind_implicit),
    ('D', 'row dostype: fixed window', c_bind_dostype),
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
