# ptable tests

Assembled routines run in amitools/vamos against mocked Exec, resource and device calls. Each suite and what it checks: [INVENTORY.md](INVENTORY.md).

## Requires

`make test` runs the suites in the amiga-toolchain image, which holds vasm 2.0f, Python 3.14+ and the pinned amifuse forks of `amitools` and `machine68k` listed in `requirements.txt`, see [docs/building.md](../docs/building.md).

`make lint` runs ruff and yamllint; `pre-commit install` runs them before each commit.

## Running

`make test` checks dependencies, then runs every suite over 68000/68020 and small/full. A failure prints its diagnostic output and stops the run. Python optimization (`-O`, `-OO`, `PYTHONOPTIMIZE`) is rejected: it disables assertions.

One suite: `make test TEST_CHECKS=parts_walker.py`. In the image, `python3 tests/unlink_free_entry.py --source /path/to/tree` tests another source tree.

The suites take vasm from `PTABLE_VASM`, `VASM_HOME/bin` or PATH, in that order; in the image PATH has it.

## Not covered

AmigaOS itself, hardware timing, interrupts, reentrancy.

`scan_device.py` runs the real ScanPartitions LVO on a mocked Exec (`mockexec.py`) against a mock device (`mockdev.py`: command set, block size, injected errors) and images built by `images.py`. `mount_device.py` adds MountPartitions and MarkAbsent with a mocked expansion.library, DOS device list and FileSystem.resource. Their `OPEN` sets list the cases whose fix has not landed; they must still fail, and the fixing commit removes their id.

## Writing a test

Assemble with `assemble()` from `toolchain.py`; keep symbols, the suites look routines up by name. Give the module docstring a `Status:` line, run `make test-list-update` and commit INVENTORY.md.
