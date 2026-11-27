## 20261127

<!-- COMPONENTS:BEGIN -->
_Components in this release_:

- `ptable.library 3.0 (27.11.2026)` _(new)_
- `lsptres 1.3 (15.11.2026)`
<!-- COMPONENTS:END -->

#### ptable.library 3.0
- Fixed a crash under AROS with the full build, found by the new integration tests of fat95 and cfd.
- Simplified ConfigDev for a bootable RDB partition. It carries only the fields strap needs to boot from it and is not registered with `AddConfigDev`, so `ShowConfig` does not list it.

#### Install
- Install sets the execute bit on the files it copies.

#### Build and tests
- Improved build and tests. Every change is built and tested automatically, and the FS-UAE integration tests of cfd and fat95 run ptable.library on AROS and ApolloOS, and locally also on AmigaOS 3.1 and 3.2.3.

## 20261115

_Components in this release_:

- `ptable.library 2.3 (15.11.2026)` _(new)_
- `lsptres 1.3 (15.11.2026)` _(new)_

#### ptable.library 2.3
- MBR partitions of type 07 are passed to the filesystem handler, like GPT basic data partitions.
- A card with FFS, PFS or SFS and no partition table mounts as one volume.
- Improved partition detection; a card can have up to 100 partitions, was 12.
- Fewer wrong or missing partitions: boot code at the card start, damaged RDB blocks, read errors and RDB partitions past 2 TB are handled.
- A newer filesystem in the RDB replaces an older one in ROM, e.g. FFS 45 over FFS 40.
- Improved detection of partitions already mounted from `DEVS:DOSDrivers`, also under another name.
- Card swap: partitions of the old card are no longer mounted for the new one.
- `HANDLER_<fs>`, `STACK_<fs>` and `PRI_<fs>` in `cfd.prefs` also apply to RDB partitions. A handler path over 23 characters is refused instead of cut.
- Fixed a memory leak on every card insert.

#### Tools

##### 'lsptres 1.3'
- `VERBOSE` shows the filesystem on each partition, e.g. `FAT32` (with fat95 4.2).

## 20261007

_Components in this release_:

- `ptable.library 2.2 (03.10.2026)` _(new)_
- `lsptres 1.2 (03.10.2026)` _(new)_

#### Install
- New Installer script.
- Reworked icon positions.

#### ptable.library 2.2
- Fixed SCSI reads for partition detection.
- Serial debug output ends lines with LF alone.

#### Tools

##### 'lsptres 1.2'
- Improved paging.
- Output lines end in LF alone.

## 20260930

_Components in this release_:

- `ptable.library 2.1 (30.09.2026)` _(new)_
- `lsptres 1.1 (30.09.2026)` _(new)_

#### 'ptable.library 2.1'

- A damaged GPT no longer produces bogus partitions.
- MBR logical partitions inside an extended partition are found, numbered from 4 (`CF4`, `CF5`, ...).

#### 'lsptres 1.1'

- The listing pauses a screenful at a time on a console; any key continues, `Q` stops, and the `-- more --` prompt is shown in italic, reversed. Redirected output is written in full.

## 20260911

_Components in this release_:

- `ptable.library 2.0 (11.09.2026)` _(new)_
- `lsptres 1.0 (11.09.2026)` _(new)_

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
