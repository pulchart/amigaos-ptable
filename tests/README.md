# ptable tests

Assembled routines run in amitools/vamos against mocked Exec, resource and device calls. Each suite and what it checks: [INVENTORY.md](INVENTORY.md).

## Requires

Linux, Python 3.11+ and [vasm 2.0f](http://sun.hasenbraten.de/vasm/), built with `make CPU=m68k SYNTAX=mot` and installed under `/opt/vasm` or `VASM_HOME`.

From the repository root:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r tests/requirements.txt
make check-test-deps
make test
```

The pinned amifuse forks provide `amitools` and `machine68k`; upstream packages overwrite those imports, so use a fresh environment if both were installed.

## Running

`make test` checks dependencies, then runs every suite over 68000/68020 and small/full. A failure prints its diagnostic output and stops the run. Python optimization (`-O`, `-OO`, `PYTHONOPTIMIZE`) is rejected: it disables assertions.

One suite: `python tests/parts_walker.py`. `unlink_free_entry.py --source /path/to/tree` tests another source tree.

Make exports its assembler as `PTABLE_VASM`; direct runs resolve `PTABLE_VASM`, `VASM_HOME/bin`, PATH, then `/opt/vasm/bin/vasmm68k_mot`.

## Not covered

AmigaOS itself, hardware timing, interrupts, reentrancy, arbitrary device faults.

## Writing a test

Assemble with `assemble()` from `toolchain.py`; keep symbols, the suites look routines up by name. Give the module docstring a `Status:` line, run `make test-list-update` and commit INVENTORY.md.
