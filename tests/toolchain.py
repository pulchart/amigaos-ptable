#!/usr/bin/env python3
"""Repository paths and the assembler invocation shared by every ptable test.

Standard library only: deps.py imports this module on a host where nothing else
is installed yet, to report what is missing.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

if not __debug__:
    sys.exit('Tests require assertions: remove -O/-OO and unset PYTHONOPTIMIZE.')

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / 'tests'

# Suites select their build coverage; there is no environment CPU selector.
CPUS = ('68000', '68020')
FLAVOURS = ('small', 'full')


def find_vasm():
    """PTABLE_VASM (what make exports) > VASM_HOME/bin > PATH > the Makefile default."""
    if os.environ.get('PTABLE_VASM'):
        return Path(os.environ['PTABLE_VASM'])
    if os.environ.get('VASM_HOME'):
        return Path(os.environ['VASM_HOME']) / 'bin' / 'vasmm68k_mot'
    found = shutil.which('vasmm68k_mot')
    return Path(found) if found else Path('/opt/vasm/bin/vasmm68k_mot')


VASM = find_vasm()

# The Makefile here does not pin a version the way fat95 and cfd do; this is
# the one the library is built and tested with.
EXPECTED_VASM_VERSION = '2.0f'


def assemble(output, source='src/ptable_lib.s', cpu='68000', flavour='small',
             defines=None, listing=None, root=None):
    """Assemble one build of the library into a hunk executable, symbols kept.

    root selects a source tree. defines overrides the flags derived from cpu and flavour,
    for a caller that already built its own list. -nosym must never appear: the
    tests find routines through the symbol table.
    """
    where = Path(root) if root else ROOT
    if defines is None:
        defines = (['-D__68020__=1'] if cpu == '68020' else [])
        defines += ['-DDEBUG=1'] if flavour == 'full' else []
    command = [str(VASM), '-quiet', '-Fhunkexe', '-m' + cpu, *defines]
    if listing is not None:
        command += ['-L', str(listing)]
    command += ['-I', 'src', '-o', str(output), str(source)]
    subprocess.run(command, cwd=where, check=True)
    return Path(output)
