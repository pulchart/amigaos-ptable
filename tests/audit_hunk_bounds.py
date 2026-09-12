#!/usr/bin/env python3
"""The HUNK loader must stay inside the hunks it was given.

Executes the real loader with Exec allocation, free and cache calls mocked, and
feeds it hunk tables that end early, overlap or claim more than they carry.

Status: gated, run by make test on both CPU tiers and both flavours.
Run from the repository root: python3 tests/audit_hunk_bounds.py"""
import argparse
import json
import struct
import tempfile
from pathlib import Path
from amitools.binfmt.BinFmt import BinFmt
from amitools.binfmt.Relocate import Relocate
from amitools.vamos.machine import Machine
from toolchain import ROOT, assemble

BASE, INPUT, CTX, EXEC, STACK, HEAP = 0x10000, 0x30000, 0x40000, 0x60000, 0x90000, 0x100000

def longs(*xs):
    return struct.pack('>' + 'I'*len(xs), *xs)

def fixture(size, offset=None, short=False, body=None):
    data = longs(0x3f3, 0, 1, 0, 0, size)
    if body is not None:
        data += longs(0x3e9, body)  # deliberately missing oversized body
    else:
        data += longs(0x3eb, size & 0x3fffffff)
    if offset is not None:
        if short:
            data += longs(0x3fc) + struct.pack('>4H', 1, 0, offset, 0)
        else:
            data += longs(0x3ec, 1, 0, offset, 0)
    return data + longs(0x3f2)

def run(image, cpu_name, data, fail_alloc=0):
    m = Machine.from_name(cpu_name, ram_size=4096)
    try:
        cpu, mem = m.get_cpu(), m.get_mem()
        mem.w_block(BASE, bytes(Relocate(image).relocate_one_block(BASE)))
        syms = {s.name.decode(): BASE+s.offset for s in image.get_segments()[0].get_symtab().get_symbols()}
        events, blocks = [], []
        cursor = HEAP
        alloc_count = 0
        def trap(addr, fn):
            tid = m.get_traps().alloc(lambda op, pc: fn())
            mem.w16(addr, 0xa000|tid); mem.w16(addr+2, 0x4e75)
        def alloc():
            nonlocal cursor, alloc_count
            alloc_count += 1
            size = cpu.r_reg(0)
            if alloc_count == fail_alloc:
                events.append(['alloc_failed', size]); cpu.w_reg(0,0); return
            assert 0 < size <= 0x100000, size
            addr = cursor; cursor += (size+63)&~3
            mem.w_block(addr, bytes(size))
            mem.w_block(addr+size, bytes([0xa5])*32)
            blocks.append(dict(addr=addr,size=size,freed=False))
            events.append(['alloc', addr,size]); cpu.w_reg(0,addr)
        def free():
            addr, size = cpu.r_reg(9), cpu.r_reg(0)
            block = next(b for b in blocks if b['addr']==addr)
            assert not block['freed'] and size == block['size']
            block['freed']=True; events.append(['free',addr,size])
        trap(EXEC-198,alloc); trap(EXEC-210,free)
        trap(EXEC-636,lambda: events.append(['cache']))
        for name in ('_bootDebug','_bootDebugHex8'):
            if name in syms: trap(syms[name],lambda: None)
        mem.w_block(INPUT,data); mem.w32(CTX,EXEC)
        for r in range(2,15): cpu.w_reg(r,0x1100+r)
        cpu.w_reg(10,INPUT); cpu.w_reg(4,len(data)); cpu.w_reg(12,CTX)
        saved={r:cpu.r_reg(r) for r in list(range(2,8))+list(range(10,15))}
        m.prepare(syms['_bootRelocateHunks'],STACK)
        for _ in range(100):
            state=m.execute(10000)
            if m.was_exit(state): break
        else: raise AssertionError('loader did not return')
        assert cpu.r_sp()==STACK
        assert all(cpu.r_reg(r)==v for r,v in saved.items())
        guards_ok=all(mem.r_block(b['addr']+b['size'],32)==bytes([0xa5])*32 for b in blocks)
        result=cpu.r_reg(0)
        if not result: assert all(b['freed'] for b in blocks)
        else:
            assert blocks[0]['freed'] and all(not b['freed'] for b in blocks[1:])
            assert result==(blocks[1]['addr']+4)//4
        relocated=None
        if result and len(blocks)>1 and blocks[1]['size']>=12:
            relocated=mem.r32(blocks[1]['addr']+8)
        return dict(result=bool(result),guards_ok=guards_ok,events=events,relocated=relocated)
    finally: m.cleanup()

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--source',type=Path,default=ROOT)
    args=ap.parse_args()
    cases=[('wrapped_size',fixture(0x3fffffff),False,0),
           ('over_cap',fixture(0x3ffff),False,0),
           ('at_cap',fixture(0x3fffe),True,0),
           ('empty_valid',fixture(0),True,0),
           ('body_overflow',fixture(1,body=0x3fffffff),False,0),
           ('table_alloc_failure',fixture(1),False,1),
           ('hunk_alloc_failure',fixture(1),False,2)]
    header=longs(0x3f3,0,1,0,0,1)
    cases += [('second_hunk_wrap',longs(0x3f3,0,2,0,1,1,0x3fffffff,0x3eb,1,0x3f2,0x3eb,0x3fffffff,0x3f2),False,0),
              ('code_copy',header+longs(0x3e9,1,0x12345678,0x3f2),True,0),
              ('data_copy',header+longs(0x3ea,1,0x12345678,0x3f2),True,0),
              ('body_exceeds_allocation',header+longs(0x3e9,2,0,0,0x3f2),False,0),
              ('body_truncated',header+longs(0x3e9,1),False,0),
              ('chip_attribute',fixture(0x40000001),True,0),
              ('fast_attribute',fixture(0x80000001),True,0),
              ('explicit_attribute',longs(0x3f3,0,1,0,0,0xc0000001,2,0x3eb,1,0x3f2),True,0),
              ('two_hunks',longs(0x3f3,0,2,0,1,1,1,0x3e9,1,0,0x3ec,1,1,0,0,0x3f2,0x3eb,1,0x3f2),True,0)]
    for short in (False,True):
        for size,off,ok in [(0,0,False),(1,0,True),(1,4,False),(2,4,True),(2,8,False)]:
            cases.append((f'reloc_{short}_{size}_{off}',fixture(size,off,short),ok,0))
    rows=[]
    with tempfile.TemporaryDirectory() as tmp:
        for cpu in ('68000','68020'):
            for flavor in ('full','small'):
                out=Path(tmp)/f'{cpu}-{flavor}'
                flags=(['-D__68020__=1'] if cpu=='68020' else [])+(['-DDEBUG=1'] if flavor=='full' else [])
                assemble(out, cpu=cpu, defines=flags, root=args.source)
                image=BinFmt().load_image(str(out))
                for name,data,ok,fail in cases:
                    r=run(image,cpu,data,fail)
                    assert r['result']==ok,(cpu,flavor,name,r)
                    assert r['guards_ok'],(name,r)
                    if name in ('code_copy','data_copy'): assert r['relocated']==0x12345678
                    if name=='two_hunks': assert r['relocated']==r['events'][2][1]+8
                    if name.startswith('reloc_') and ok and name.endswith('_0'):
                        assert r['relocated']==r['events'][1][1]+8
                    rows.append(dict(cpu=cpu,flavor=flavor,case=name,**r))
    print(json.dumps(rows,indent=2))
if __name__=='__main__': main()
