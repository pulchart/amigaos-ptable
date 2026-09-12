#!/usr/bin/env python3
"""Successful cold registration retains its device-node blob.

Drives the real _actCold and mocks the resource lookup, the matching, the blob
creation, the expansion calls and the debug output.

Status: gated, run by make test on both CPU tiers and both flavours.
Run from the repository root: python3 tests/audit_cold_registration.py"""
import argparse
import json
import tempfile
from pathlib import Path

from amitools.binfmt.BinFmt import BinFmt
from amitools.binfmt.Relocate import Relocate
from amitools.vamos.machine import Machine
from toolchain import ROOT, assemble

BASE, CTX, RESOURCE, ENTRY, TAIL, BLOB, EXEC, EXP, STACK = (
    0x10000, 0x30000, 0x31000, 0x32000, 0x33000, 0x34000,
    0x60000, 0x70000, 0x90000)


def observe(image, cpu_name, flavor, bootable, succeeds):
    machine = Machine.from_name(cpu_name)
    try:
        cpu, mem = machine.get_cpu(), machine.get_mem()
        mem.w_block(BASE, bytes(Relocate(image).relocate_one_block(BASE)))
        symbols = {s.name.decode(): BASE + s.offset
                   for s in image.get_segments()[0].get_symtab().get_symbols()}
        events = []

        def result(value):
            cpu.w_reg(0, value)

        def trap(address, callback):
            tid = machine.get_traps().alloc(lambda opcode, pc: callback())
            mem.w16(address, 0xa000 | tid)
            mem.w16(address + 2, 0x4e75)

        trap(symbols['_partGetResource'], lambda: result(RESOURCE))
        trap(symbols['_actMatch'], lambda: result(1))
        trap(symbols['_actBuildBlob'], lambda: result(BLOB))
        for name in ('_bootDebug', '_bootDebugBStrR', '_bootDebugPartTail'):
            if name in symbols:
                trap(symbols[name], lambda: None)

        def add_node(command):
            events.append([command, cpu.r_reg(8)])
            result(int(succeeds))

        trap(EXP - 36, lambda: add_node('AddBootNode'))
        trap(EXP - 150, lambda: add_node('AddDosNode'))
        trap(EXEC - 210, lambda: events.append(
            ['FreeMem', cpu.r_reg(9), cpu.r_reg(0)]))
        # Offsets from ptable_pub.i and ptable_boot.s; no fake routine body.
        mem.w32(CTX + 4, EXP)
        mem.w32(RESOURCE + 34, ENTRY)
        mem.w32(ENTRY, TAIL)
        mem.w32(TAIL, 0)
        mem.w8(ENTRY + 26, 2)  # PES_RDB
        mem.w8(ENTRY + 27, 2 if bootable else 0)
        cpu.w_reg(12, CTX)
        cpu.w_reg(13, EXEC)
        machine.prepare(symbols['_actCold'], STACK)
        for _ in range(20):
            state = machine.execute(10000)
            if machine.was_exit(state):
                break
        else:
            raise AssertionError('_actCold did not return')
        assert cpu.r_sp() == STACK
        registered = cpu.r_reg(0)
        mounted = bool(mem.r8(ENTRY + 27) & 8)
        freed = ['FreeMem', BLOB, 232] in events
        assert registered == int(succeeds) and mounted == succeeds
        if succeeds:
            assert mem.r32(ENTRY + 44) == BLOB
            assert mem.r32(ENTRY + 48) == BLOB
            assert mem.r32(ENTRY + 52) == 232
        assert freed == (not succeeds), events
        return {'cpu': cpu_name, 'flavor': flavor, 'bootable': bootable,
                'add_succeeded': succeeds, 'registered': registered,
                'mounted': mounted, 'blob_freed': freed,
                'dangling_registered_blob': succeeds and freed, 'events': events}
    finally:
        machine.cleanup()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=ROOT)
    args = parser.parse_args()
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        for cpu in ('68000', '68020'):
            for flavor in ('full', 'small'):
                output = Path(tmp) / f'{cpu}-{flavor}.hunk'
                flags = ['-D__68020__=1'] if cpu == '68020' else []
                if flavor == 'full':
                    flags.append('-DDEBUG=1')
                assemble(output, cpu=cpu, defines=flags, root=args.source)
                image = BinFmt().load_image(str(output))
                for bootable in (False, True):
                    for succeeds in (False, True):
                        rows.append(observe(image, cpu, flavor, bootable, succeeds))
    print(json.dumps(rows, indent=2))


if __name__ == '__main__':
    main()
