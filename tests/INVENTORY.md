# ptable test inventory

Generated from the docstrings by `tests/list_tests.py`. Refresh with `make test-list-update`.

<!-- TESTS:BEGIN -->

| script | status | what it checks |
|---|---|---|
| `act_binding.py` | gated | Mount-time resolution of a row: caller settings matched by DosType family. |
| `audit_cold_registration.py` | gated | Successful cold registration retains its device-node blob. |
| `audit_hunk_bounds.py` | gated | The HUNK loader must stay inside the hunks it was given. |
| `mount_device.py` | gated | MountPartitions end to end: scan a mock device, then mount its rows. |
| `parts_walker.py` | gated | MBR/GPT walkers and caller dispatch against malformed disk structures. |
| `scan_device.py` | gated | ScanPartitions end to end: the real LVO, a mocked Exec and a mock device. |
| `umul32.py` | gated | UMUL32: 32-bit unsigned multiply with the overflow flag. |
| `unlink_free_entry.py` | gated | Unlink an entry under Forbid/Permit before freeing it. |
| `unlink_paths.py` | gated | Unmount, teardown and purge unlink entries before freeing their allocations. |

<!-- TESTS:END -->
