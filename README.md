# amigaos-ptable

`ptable.library` is the AmigaOS partition-table library. One place that parses **RDB, MBR and GPT** layouts and shares the result, so a device driver and a filesystem handler never each carry their own partition parser.

It was assembled from existing code: the library framework and RDB cold-boot path came from `compactflash.device`, the MBR/GPT scanning from `fat95`. It is consumed today by:

- **[`compactflash.device`](https://github.com/pulchart/cfd)** (cold-boot RDB autoboot, and a per-unit automount task for hotplugged FAT MBR/GPT cards).
- **[`fat95`](https://github.com/pulchart/fat95)** (whole-disk partition auto-detection; it reads `partition.resource` instead of parsing tables itself).

## What it does

- **Cold-boot RDB autoboot**: boot directly from an RDB-partitioned card.
- **DOS-time scanning and automount**: discover and mount hotplugged RDB/MBR/GPT/flat cards.

See [`docs/ptable.md`](docs/ptable.md) for the end-user guide: what it is, configuration, and the public interface. The `partition.resource` and `PartEntry` field layout is in [`src/ptable_pub.i`](src/ptable_pub.i).

# amigaos-ptable's cli

`lsptres`: is a small CLI that dumps `partition.resource`. See [`docs/lsptres.md`](docs/lsptres.md) for usage.

# Release notes

See [`docs/changes.md`](docs/changes.md) for release news and history.

# License

LGPL-2.1 (see [`LICENSE`](LICENSE)).
