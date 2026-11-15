#!/usr/bin/env python3
"""UMUL32: 32-bit unsigned multiply with the overflow flag.

The RDB geometry is computed with UMUL32 (mulu.l on 68020, the UMul32
routine on 68000), and a product past 32 bits must set V. The cases run the
macro through a probe routine assembled per CPU and compare with Python.

Status: gated, run by make test.
Run from the repository root: python3 tests/umul32.py"""
import random
import sys
import tempfile
from pathlib import Path

from amitools.binfmt.BinFmt import BinFmt
from amitools.binfmt.Relocate import Relocate
from amitools.vamos.machine import Machine
from toolchain import ROOT, assemble

BASE, STACK = 0x10000, 0x80000

# The image starts at the branch to the probe; the macro must be defined
# before its use, and on 68000 the include also places UMul32.
PROBE = """
	bra.w	probe
	include	"umul32.i"
probe:
	UMUL32
	svs	d2
	rts
"""


def pairs():
    rng = random.Random(32)
    edge = [0, 1, 2, 0xFFFF, 0x10000, 0x10001, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF]
    out = [(a, b) for a in edge for b in edge]
    out += [(rng.getrandbits(rng.randint(1, 32)), rng.getrandbits(rng.randint(1, 32)))
            for _ in range(3000)]
    return out


def run(cpu, tmp):
    src = Path(tmp) / ('probe%s.s' % cpu)
    src.write_text(PROBE)
    obj = Path(tmp) / ('probe%s' % cpu)
    assemble(obj, source=str(src), cpu=cpu, defines=['-D__68020__=1'] if cpu == '68020' else [])
    image = BinFmt().load_image(str(obj))
    m = Machine.from_name(cpu, ram_size=1024)
    cpu_, mem = m.get_cpu(), m.get_mem()
    mem.w_block(BASE, bytes(Relocate(image).relocate_one_block(BASE)))
    bad = []
    try:
        for a, b in pairs():
            cpu_.w_reg(0, a)
            cpu_.w_reg(1, b)
            cpu_.w_reg(2, 0)
            m.prepare(BASE, STACK)
            assert m.was_exit(m.execute(100000))
            product = a * b
            overflow = cpu_.r_reg(2) & 0xFF != 0
            if overflow != (product > 0xFFFFFFFF) or (not overflow and cpu_.r_reg(0) != product):
                bad.append((hex(a), hex(b), hex(cpu_.r_reg(0)), overflow))
            if cpu_.r_reg(1) != b:
                bad.append(('d1 clobbered', hex(a), hex(b)))
    finally:
        m.cleanup()
    return bad


def main():
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        for cpu in ('68000', '68020'):
            bad = run(cpu, tmp)
            print('%s %d pairs, %d wrong' % (cpu, len(pairs()), len(bad)))
            for b in bad[:10]:
                print('  ', b)
            failed += len(bad)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
