## 20260904-dev

<!-- COMPONENTS:BEGIN -->
_Components in this release_:

- `ptable.library 2.0-dev (27.08.2026)` _(new)_
- `lsptres 1.0-dev (27.08.2026)` _(new)_
<!-- COMPONENTS:END -->

#### New major version of ptable.library 2.0

- **Unified partition scanning.** One scanner parses RDB, MBR, GPT and flat (whole-disk FAT) tables and publishes every partition into `partition.resource`, the shared partition manager. Any driver or handler reads the layout from there instead of parsing the card itself; `compactflash.device` and `fat95` do today. See [ptable.md](ptable.md).
- **Selectable filesystem for MBR/GPT FAT partitions.** The consumer can name the DosType to mount them with (`mc_NodeDosType`) and a handler to load when `FileSystem.resource` has none (`mc_NodeHandler`). Unset means unchanged; RDB partitions are unaffected.
- **`lsptres`** shows the DosType a mounted partition actually carries in its `DosType` column. A handler that mounts statically can record its DosType too, via a new `RegisterPartition` input.

#### New tool 'lsptres 1.0'

- Lists the contents of `partition.resource`. See [lsptres.md](lsptres.md).

## 1.1 (07.06.2026)

Never released on its own: 1.1 shipped inside the compactflash.device archive (driver/media/cfd), in releases 20260609 and 20260614.

##### Partition Table library

- **Cold-boot RDB partition scanner**, extracted from `compactflash.device`: the RDB autoboot `RTF_COLDSTART` hook, the filesystem-handler loader, and the hunk relocator.
- **Duplicate RDB drive names are made unique at cold boot.** When two cards carry RDBs that reuse the same partition name (for example both define `DH0`), a clashing name now gets a numeric suffix (`DH0.1`, `DH0.2`, ...).
- Loads filesystem handlers stored in a compacted format (`RELOC32SHORT` relocations).
- A partition with a damaged RDB entry is skipped instead of mounted (a `DosEnvec` shorter than the `DOSTYPE` field).
- Filesystem handlers loaded from a card's RDB now appear in `FileSystem.resource` under their own name instead of `ptable.library`.
