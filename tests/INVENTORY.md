# ptable test inventory

Generated from the docstrings by `tests/list_tests.py`. Refresh with `make test-list-update`.

<!-- TESTS:BEGIN -->

| script | status | what it checks |
|---|---|---|
| `audit_cold_registration.py` | gated | Successful cold registration retains its device-node blob. |
| `audit_hunk_bounds.py` | gated | The HUNK loader must stay inside the hunks it was given. |
| `parts_walker.py` | gated | MBR/GPT walkers and caller dispatch against malformed disk structures. |
| `unlink_free_entry.py` | gated | Unlink an entry under Forbid/Permit before freeing it. |
| `unlink_paths.py` | gated | Unmount, teardown and purge unlink entries before freeing their allocations. |

<!-- TESTS:END -->
