# amigaos-ptable

`ptable.library` is the AmigaOS partition-table library. One place that parses
**RDB, MBR and GPT** layouts and shares the result, so a device driver and a
filesystem handler never each carry their own partition parser.

It was extracted from the `compactflash.device` project, where it grew up as the
cold-boot RDB autoboot helper and then gained DOS-time MBR/GPT scanning. It is
consumed today by:

- **`compactflash.device`** (cold-boot RDB autoboot, and a per-unit automount
  task for hotplugged FAT MBR/GPT cards).
- **`fat95`** (whole-disk partition auto-detection; it reads `partition.resource`
  instead of parsing tables itself).

## What it does

- **Cold-boot RDB autoboot** (`RTF_COLDSTART` consumer calls `BootScanRDB`):
  finds RDSK, loads filesystem handlers from the RDB into `FileSystem.resource`,
  and publishes partitions via `AddBootNode` / `AddDosNode`.
- **DOS-time MBR/GPT scanning** into a shared `partition.resource`, plus mount
  and unmount helpers that any consumer can drive.

## Public interface (LVOs)

```
BootScanRDB(deviceName:a1, unit:d0)        -30  cold-boot RDB scan + register
ScanPartitions(deviceName:a1, unit:d0)     -36  parse MBR/GPT -> partition.resource
MountPartitions(deviceName:a1, unit:d0)    -42  AddDosNode(ADNF_STARTPROC) the entries
UnmountPartitions(deviceName:a1, unit:d0)  -48  ACTION_DIE + RemDosEntry + free
```

`OpenLibrary("ptable.library", 1)` is enough for the cold-boot RDB path;
consumers of the DOS-time calls open version `2`. RDB cards are skipped by
`ScanPartitions` (the cold-boot path owns them), so nothing double-mounts.

`partition.resource` is the runtime single-source-of-truth for discovered
partitions; its layout and the `PartEntry` fields are documented in
[`src/ptable_pub.i`](src/ptable_pub.i), the public consumer header.

## Build

Requires vasm 2.0e at `/opt/vasm` (override with `VASM_HOME=`).

```sh
make            # build all four tiers + dist/ptable.version
make clean
```

Output: `dist/<flavor>/<cpu>/ptable.library` for `full`/`small` x `68020`/`68000`
(`full` includes serial debug output). The library must be ROM-resident for
cold-boot autoboot; the DOS-time calls also work from a disk-loaded `LIBS:` copy.

## Consuming it from another repo

Add as a git submodule and either build it standalone (`make -C extern/ptable`)
and consume the binaries, or assemble against its sources with
`-I extern/ptable/src` for the public `ptable_pub.i` header.

## License

LGPL-2.1 (see [`LICENSE`](LICENSE)).
