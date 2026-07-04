# lsptres - partition.resource lister

`lsptres` lists `partition.resource`: every partition that `ptable.library` has discovered and published, whether registered at cold boot or scanned when a card was hotplugged. It reports the partition scheme it came from (RDB, MBR, GPT or a partition-table-less "flat" superfloppy), the DosType, mount state, and the mount Flags / CONTROL string resolved for it. It is the companion to fat95's `lsfsres`, which lists `FileSystem.resource`.

**Use cases**:
- Confirm a hotplugged card's partitions were scanned and mounted.
- See which partitions are mounted, and under what DOS name.
- Check the mount Flags and CONTROL string the partition was mounted with - whether resolved by cfd's automount from `ENV:cfd.prefs` (the `FLAGS` / `CONTROL` knobs), or supplied by a handler that mounted it from a static mountlist.

## Usage

```
lsptres            ; default columns
lsptres VERBOSE    ; also show CMD / Start / Blocks / Size (V works too)
lsptres >SER:      ; forward output over the serial line
```

`lsptres` reads the live resource. If nothing has been scanned yet, or `ptable.library` v2 is not resident, it prints `partition.resource not present` and exits.

## Columns

| Column | Meaning |
|--------|---------|
| Name | Partition name. Shown as `name>dosname` when the partition is mounted under a different DOS name (e.g. `MFMa0>MS0`). |
| Device | Device serving the partition (e.g. `compactflash.device`, truncated to fit). |
| Unit | Device unit number. |
| Part | Partition index within the card (0-based). |
| Src | Partition scheme: `MBR`, `GPT`, `RDB`, or `FLT` (flat / superfloppy). |
| Pri | Boot priority. |
| DosType | The DosType as hex (e.g. `0x46415400`). |
| Text | The DosType as four-character text; non-printable bytes (e.g. a trailing `\0`) show as `.`. |
| Flags | First char: `P` present, `I` invalid (a card is in but has no partition for this mounted slot), `-` absent. Then `B` bootable, `N` nomount, `M` mounted; `-` for an absent bit. |
| MFlg | Mount Flags the partition was mounted with: cfd's automount resolves these from `cfd.prefs` (`FLAGS`), or a handler that mounts it statically records the value it opened the device with. |
| Ctrl | CONTROL string the partition was mounted with: from `cfd.prefs` (`CONTROL`) on the automount path, or recorded by a handler mounting statically. |

Verbose (`VERBOSE` / `V`) appends:

| Column | Meaning |
|--------|---------|
| CMD | Read command used for the device: `NSCMD`, `TD64`, `SCSI` or `CMD`. |
| Start | Start block (LBA). |
| Blocks | Block count. |
| Size | Size in MB. |

## Examples

### A GPT card with three FAT partitions, mounted

The card was inserted at runtime; `cfd.prefs` set `CONTROL_FAT -d-D`, so that value appears in the Ctrl column and applies to every FAT mount.

```
Name         Device        Unit Part Src Pri DosType    Text Flags MFlg Ctrl
------------ ------------- ---- ---- --- --- ---------- ---- ----- ----- ----------
CFa0         compactflash.    0    0 GPT   0 0x46415400 FAT. P--M      0 -d-D
CFa1         compactflash.    0    1 GPT   0 0x46415400 FAT. P--M      0 -d-D
CFa2         compactflash.    0    2 GPT   0 0x46415400 FAT. P--M      0 -d-D
```

The `P--M` flags read: present, mounted (not bootable, not nomount). The Text of `0x46415400` is `FAT.` (the trailing `\0` prints as `.`).

### A single MBR partition reattached over a 3-partition GPT card (the `I` flag)

Starting from the three-FAT GPT card above (all `P--M`), that card was removed and a single-partition MBR card inserted in its place. The scan re-matches the new card's one partition to the `CFa0` slot - note its Src flips `GPT`->`MBR`, the fresh card's scheme. The `CFa1` and `CFa2` handlers were never unmounted, and the MBR card has no partition for them, so those slots go `I` (invalid): the present bit clears while mounted stays.

```
Name         Device        Unit Part Src Pri DosType    Text Flags MFlg Ctrl
------------ ------------- ---- ---- --- --- ---------- ---- ----- ----- ----------
CFa0         compactflash.    0    0 MBR   0 0x46415400 FAT. P--M      0 -d-D
CFa1         compactflash.    0    1 GPT   0 0x46415400 FAT. I--M      0 -d-D
CFa2         compactflash.    0    2 GPT   0 0x46415400 FAT. I--M      0 -d-D
```

`CFa0` re-mounted cleanly as `P--M` with the new card's `MBR` scheme. `CFa1` / `CFa2` read `I--M` - invalid but still mounted: the handlers hold the mounts, and their Src stays `GPT` (the removed card's value) since nothing refreshed them. Contrast a card pulled with no replacement: those slots read `---M` (leading `-`), plain absent rather than invalid.

### An RDB card with PFS partitions

```
Name         Device        Unit Part Src Pri DosType    Text Flags MFlg Ctrl
------------ ------------- ---- ---- --- --- ---------- ---- ----- ----- ----------
SDH10        compactflash.    0    0 RDB   0 0x4D414300 MAC. P-N-      0
SDH11        compactflash.    0    1 RDB   0 0x4D414300 MAC. P-N-      0
SDH0         compactflash.    0    2 RDB   0 0x50465303 PFS. PB-M      0
SDH1         compactflash.    0    3 RDB   0 0x50465303 PFS. P--M      0
SDH2         compactflash.    0    4 RDB   0 0x50465303 PFS. P--M      0
```

`SDH0` is bootable (`B`). `SDH10` and `SDH11` are marked nomount (`N`) in their RDB entries, so they are published but not mounted (no `M`). RDB partitions carry no `cfd.prefs` Flags / CONTROL, so MFlg is `0` and Ctrl is empty.

### Verbose

```
Name         Device        Unit Part Src Pri DosType    Text Flags MFlg Ctrl       CMD   Start   Blocks   Size
------------ ------------- ---- ---- --- --- ---------- ---- ----- ----- ---------- ----- ------- -------- ------
CFa0         compactflash.    0    0 GPT   0 0x46415400 FAT. P--M      0 -d-D       NSCMD    2048  4194304  2048M
```

## See also

- `cfd.prefs` (the `FLAGS` / `CONTROL` knobs, global and `_<fs>` per-filesystem) supplies the MFlg / Ctrl values for partitions cfd automounts; statically mounted partitions show the values their handler opened the device with instead.
- `lsfsres` (fat95) lists `FileSystem.resource`: the handlers, where `lsptres` lists the partitions they mount.
