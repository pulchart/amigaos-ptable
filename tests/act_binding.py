#!/usr/bin/env python3
"""Mount-time resolution of a row: caller settings matched by DosType family.

_actResolveCfg turns the caller's MountCfg into the Flags, CONTROL, node
DosType and handler path a row is mounted with. The cases run the real
routine on crafted rows and MountCfg structures; no device is involved.

Status: gated, run by make test.
Run from the repository root: python3 tests/act_binding.py"""
import struct
import sys

import mockdev as md
from mockexec import Rig, builds

ENTRY, CTX, CFG, OVR, CTRL, PATH = 0x48000, 0x49000, 0x4A000, 0x4A100, 0x4A200, 0x4A300
FAT, MARKER, DOS3 = 0x46415400, 0x464154FF, 0x444F5303
PES_MBR, PES_RDB, PES_FLAT = 0, 2, 3


def cstr(s):
    return s.encode() + b'\0'


class Resolve:
    def __init__(self, build):
        self.rig = Rig(build, md.Disk({}))
        self.eq, self.mem = build.eq, self.rig.mem

    def row(self, source, dostype, count, envec_dostype=MARKER):
        eq = self.eq
        self.mem.w_block(ENTRY, bytes(eq['pe_Sizeof']))
        self.mem.w8(ENTRY + eq['pe_Source'], source)
        self.mem.w32(ENTRY + eq['pe_DosType'], dostype)
        self.mem.w32(ENTRY + eq['pe_StartLBA'], 2048)
        self.mem.w32(ENTRY + eq['pe_BlockCount'], count)
        self.mem.w32(ENTRY + eq['pe_Envec'], 16)
        self.mem.w32(ENTRY + eq['pe_Envec'] + 4 * 16, envec_dostype)

    def cfg(self, flags=0, control=None, overrides=(), node_dostype=0, handler=None):
        eq = self.eq
        self.mem.w_block(CFG, bytes(eq['mc_UnmFlags'] + 4))
        self.mem.w32(CFG + eq['mc_Flags'], flags)
        if control:
            self.mem.w_block(CTRL, cstr(control))
            self.mem.w32(CFG + eq['mc_Control'], CTRL)
        if overrides:
            table = b''
            for i, (prefix, oflags, ocontrol) in enumerate(overrides):
                addr = CTRL + 0x40 * (i + 1)
                self.mem.w_block(addr, cstr(ocontrol))
                table += struct.pack('>IIB3xI', prefix, oflags, 1, addr)
            self.mem.w_block(OVR, table + bytes(eq['ovr_Sizeof']))
            self.mem.w32(CFG + eq['mc_Overrides'], OVR)
        self.mem.w32(CFG + eq['mc_NodeDosType'], node_dostype)
        if handler:
            self.mem.w_block(PATH, cstr(handler))
            self.mem.w32(CFG + eq['mc_NodeHandler'], PATH)
        self.mem.w32(CFG + eq['mc_Size'], eq['mc_UnmFlags'] + 4)

    def run(self):
        eq = self.eq
        self.mem.w_block(CTX, bytes(eq['BC_Sizeof']))
        self.mem.w32(CTX + eq['BC_MountCfg'], CFG)
        self.rig.call('_actResolveCfg', {11: ENTRY, 12: CTX})
        nb = ENTRY + eq['pe_Control']
        return {'flags': self.mem.r32(ENTRY + eq['pe_MountFlags']),
                'control': bytes(self.mem.r_block(nb + 1, self.mem.r8(nb))).decode(),
                'nodedt': self.mem.r32(ENTRY + eq['pe_NodeDosType']),
                'handler': self.mem.r32(CTX + eq['BC_NodeHandler'])}

    def prefix(self, dostype):
        self.mem.w32(ENTRY + self.eq['pe_DosType'], dostype)
        return self.rig.call('_actPrefix', {11: ENTRY})


def cases(build):
    r = Resolve(build)
    out = []
    try:
        for dt, want in ((FAT, FAT), (FAT | 1, FAT), (DOS3, 0x444F5300)):
            out.append(('prefix %08x' % dt, r.prefix(dt), want))

        over = [(FAT, 7, '-d'), (0x444F5300, 3, '-x')]
        for name, source in (('MBR', PES_MBR), ('flat', PES_FLAT)):
            r.row(source, FAT, 0x8000)
            r.cfg(flags=1, control='-g', overrides=over)
            got = r.run()
            out.append(('%s row takes the FAT override' % name,
                        (got['flags'], got['control']), (7, '-d')))

        r.row(PES_FLAT, FAT, 0x8000)
        r.cfg(node_dostype=FAT | 1, handler='L:fat95')
        got = r.run()
        out.append(('flat row takes mc_NodeDosType', (got['nodedt'], got['handler'] == PATH),
                    (FAT | 1, True)))

        r.row(PES_FLAT, FAT, 0)
        r.cfg(node_dostype=FAT | 1, handler='L:fat95')
        got = r.run()
        out.append(('size unknown keeps the auto-detect node', got['nodedt'], MARKER))

        r.row(PES_RDB, DOS3, 0x8000, envec_dostype=DOS3)
        r.cfg(node_dostype=FAT | 1, handler='L:fat95')
        got = r.run()
        out.append(('RDB row ignores mc_Node*', (got['nodedt'], got['handler']), (DOS3, 0)))
    finally:
        r.rig.close()
    return out


def main():
    bad = 0
    for build in builds():
        results = cases(build)
        for name, got, want in results:
            if got != want:
                bad += 1
                print('FAIL %s %s: got %r want %r' % (build.name, name, got, want))
        print('%s %d cases' % (build.name, len(results)))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
