#!/usr/bin/env python3
"""Unlink an entry under Forbid/Permit before freeing it.

That is Forbid, Remove(entry), Permit, then free(entry), in that order. Mocks
exec.library and _psFreeEntry; the helper itself is the real assembled code.

Status: gated, run by make test on both CPU tiers and both flavours.
Run from the repository root: python3 tests/unlink_free_entry.py [--source DIR]"""
import argparse,json,sys,tempfile
from pathlib import Path
from amitools.binfmt.BinFmt import BinFmt
from amitools.binfmt.Relocate import Relocate
from amitools.vamos.machine import Machine
from toolchain import ROOT, assemble
BASE,EXEC,ENTRY,STACK=0x10000,0x70000,0x52000,0x90000
LVO={'Forbid':-132,'Permit':-138,'Remove':-252}
# Required ordering: release the list lock before freeing memory.
ORACLE=['Forbid','Remove','Permit','free']

ap=argparse.ArgumentParser(); ap.add_argument('--source',default=str(ROOT))
a=ap.parse_args()
rows=[];bad=[]
with tempfile.TemporaryDirectory() as tmp:
    for cpu in ('68000','68020'):
        for flavor in ('small','full'):
            out=Path(tmp)/f'p-{cpu}-{flavor}'
            flags=['-D__68020__=1'] if cpu=='68020' else []
            if flavor=='full': flags.append('-DDEBUG=1')
            assemble(out, cpu=cpu, defines=flags, root=a.source)
            im=BinFmt().load_image(str(out))
            m=Machine.from_name(cpu,ram_size=2048)
            try:
                cpu_o,mem=m.get_cpu(),m.get_mem()
                mem.w_block(BASE,bytes(Relocate(im).relocate_one_block(BASE)))
                syms={s.name.decode():BASE+s.offset for s in im.get_segments()[0].get_symtab().get_symbols()}
                if '_psUnlinkFreeEntry' not in syms:
                    rows.append(dict(cpu=cpu,flavor=flavor,ok=False,why='helper absent')); bad.append(rows[-1]); continue
                calls=[];args_seen={}
                def mk(name):
                    def f():
                        calls.append(name)
                        if name=='Remove': args_seen['remove_a1']=cpu_o.r_reg(9)
                    return f
                for n,off in LVO.items():
                    tid=m.get_traps().alloc(lambda op,pc,fn=mk(n):fn())
                    mem.w16(EXEC+off,0xa000|tid); mem.w16(EXEC+off+2,0x4e75)
                def freed():
                    calls.append('free'); args_seen['free_a0']=cpu_o.r_reg(8)
                tid=m.get_traps().alloc(lambda op,pc:freed())
                mem.w16(syms['_psFreeEntry'],0xa000|tid); mem.w16(syms['_psFreeEntry']+2,0x4e75)
                cpu_o.w_reg(11,ENTRY)          # a3 = the entry
                cpu_o.w_reg(13,EXEC)           # a5 = ExecBase
                m.prepare(syms['_psUnlinkFreeEntry'],STACK)
                st=m.execute(20000); done=m.was_exit(st)
                ok=(done and calls==ORACLE and args_seen.get('remove_a1')==ENTRY
                    and args_seen.get('free_a0')==ENTRY and cpu_o.r_sp()==STACK)
                r=dict(cpu=cpu,flavor=flavor,terminated=bool(done),calls=calls,
                       remove_a1=hex(args_seen.get('remove_a1',0)),
                       free_a0=hex(args_seen.get('free_a0',0)),
                       sp_balanced=cpu_o.r_sp()==STACK,ok=bool(ok))
                rows.append(r)
                if not ok: bad.append(r)
            finally: m.cleanup()
print(json.dumps(rows,indent=2))
print(f'{len(rows)-len(bad)}/{len(rows)} builds unlink before freeing',file=sys.stderr)
sys.exit(1 if bad else 0)
