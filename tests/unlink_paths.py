#!/usr/bin/env python3
"""Unmount, teardown and purge unlink entries before freeing their allocations.

Checks event order, allocation sizes, list links, continuation pointers,
preserved registers and stack balance in the assembled call sites.

Status: gated, run by make test on both CPU tiers and both flavours.
Run from the repository root: python3 tests/unlink_paths.py"""
import tempfile
from pathlib import Path
from amitools.binfmt.BinFmt import BinFmt
from amitools.binfmt.Relocate import Relocate
from amitools.vamos.machine import Machine
from toolchain import assemble
BASE,EXEC,ENTRY,NEXT,PREV,NAME,STACK=0x10000,0x70000,0x52000,0x53000,0x54000,0x55000,0x90000

def observe(im,kind,cpu_name,device,length):
 m=Machine.from_name(cpu_name,ram_size=2048)
 try:
  cpu,mem=m.get_cpu(),m.get_mem();events=[]
  mem.w_block(BASE,bytes(Relocate(im).relocate_one_block(BASE)))
  syms={s.name.decode():BASE+s.offset for s in im.get_segments()[0].get_symtab().get_symbols()}
  def trap(addr,fn):
   tid=m.get_traps().alloc(lambda op,pc:fn());mem.w16(addr,0xa000|tid);mem.w16(addr+2,0x4e75)
  trap(EXEC-132,lambda:events.append(['Forbid']))
  trap(EXEC-138,lambda:events.append(['Permit']))
  def remove():
   assert cpu.r_reg(9)==ENTRY;events.append(['Remove',ENTRY])
   mem.w32(PREV,NEXT);mem.w32(NEXT+4,PREV)
  trap(EXEC-252,remove)
  def free():
   events.append(['FreeMem',cpu.r_reg(9),cpu.r_reg(0)])
   for r in (0,1,8,9):cpu.w_reg(r,0xdead0000+r)
  trap(EXEC-210,free)
  for n in ('_bootDebug','_bootDebugBStr'):
   if n in syms:trap(syms[n],lambda:None)
  for n in ('_aum_walk','_spg_walk'):mem.w16(syms[n],0x4e75)
  mem.w32(ENTRY,NEXT);mem.w32(ENTRY+4,PREV);mem.w32(PREV,ENTRY);mem.w32(NEXT+4,ENTRY)
  mem.w32(ENTRY+14,NAME if device else 0);mem.w16(ENTRY+244,length)
  mem.w_block(NAME,b'cfd.device\0')
  for r in range(16):cpu.w_reg(r,0x1200+r)
  cpu.w_reg(2,NEXT);cpu.w_reg(11,ENTRY);cpu.w_reg(13,EXEC)
  m.prepare(syms[kind],STACK);state=m.execute(20000);assert m.was_exit(state)
  assert cpu.r_sp()==STACK and mem.r32(PREV)==NEXT and mem.r32(NEXT+4)==PREV
  expected=[['Forbid'],['Remove',ENTRY],['Permit']]
  if device:expected.append(['FreeMem',NAME,11])
  expected.append(['FreeMem',ENTRY,length or 260]);assert events==expected
  if kind=='_ate_nofree':assert cpu.r_reg(0)==1
  else:assert cpu.r_reg(11)==NEXT
  for r in (2,3,5,6,7,10,12,13):
   expected=NEXT if r==2 else EXEC if r==13 else 0x1200+r
   assert cpu.r_reg(r)==expected,(kind,'register',r,cpu.r_reg(r),expected)
 finally:m.cleanup()

with tempfile.TemporaryDirectory() as tmp:
 for cpu in ('68000','68020'):
  for flavor in ('small','full'):
   out=Path(tmp)/f'{cpu}-{flavor}'
   assemble(out, cpu=cpu, flavour=flavor)
   image=BinFmt().load_image(str(out))
   count=0
   for kind in ('_aum_drop','_ate_nofree','_spg_free'):
    for device in (False,True):
     for length in (0,272):
      observe(image,kind,cpu,device,length)
      count+=1
   print(cpu,flavor,count,'unlink path cases passed')
