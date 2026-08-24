## 20260825-dev

<!-- COMPONENTS:BEGIN -->
_Components in this release_:

- `ptable.library 2.0-dev (25.08.2026)` _(new)_
- `lsptres 1.0-dev (25.08.2026)` _(new)_
<!-- COMPONENTS:END -->

##### Partition Table library

- **Unified partition scanning.** One scanner parses RDB, MBR, GPT, and flat (whole-disk FAT) partition tables and publishes every partition into a shared `partition.resource`, now consumed by both `compactflash.device` and `fat95` instead of each carrying its own parser. See [ptable.md](ptable.md).
- **Selectable filesystem for MBR/GPT FAT partitions.** The consumer can name the DosType to mount them with (`mc_NodeDosType`) and a handler to load when `FileSystem.resource` has none (`mc_NodeHandler`). Unset means unchanged; RDB partitions are unaffected. See [ptable.md](ptable.md).
- **`lsptres`** shows the DosType a mounted partition actually carries in its `DosType` column.

##### Tools

- **`lsptres`**: a new CLI that lists the contents of `partition.resource`. See [lsptres.md](lsptres.md).

## 1.1 (07.06.2026)

##### Partition Table library

- **Cold-boot RDB partition scanner**, extracted from `compactflash.device`: the RDB autoboot `RTF_COLDSTART` hook, the filesystem-handler loader, and the hunk relocator.
- **Duplicate RDB drive names are made unique at cold boot.** When two cards carry RDBs that reuse the same partition name (for example both define `DH0`), a clashing name now gets a numeric suffix (`DH0.1`, `DH0.2`, ...).
- Loads filesystem handlers stored in a compacted format (`RELOC32SHORT` relocations).
- A partition with a damaged RDB entry is skipped instead of mounted (a `DosEnvec` shorter than the `DOSTYPE` field).
- Filesystem handlers loaded from a card's RDB now appear in `FileSystem.resource` under their own name instead of `ptable.library`.
