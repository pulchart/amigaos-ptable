# Building ptable

## Requirements

* vasm (`vasmm68k_mot`), default path `/opt/vasm` (`VASM_HOME=`)
* vbcc and the NDK for `lsptres`, default path `/opt/vbcc` (`VBCC_HOME=`), NDK in `NDK/`
* `../cfd/tools/md2guide.py` and python3 for the guides, `lha` for releases

## Release

```sh
make clean; make; make guide; make release
```

## Targets

| Target | Does |
|--------|------|
| `make` | ptable.library (small, full; 68000, 68020) and `lsptres` |
| `make guide` | AmigaGuide files from Markdown |
| `make stage` | archive tree in `build/stage` |
| `make release` | Aminet LHA archive and readme |
| `make test` | emulated test suite |
| `make clean`, `distclean` | cleanup |

## Install script

`make stage` joins the fragments in `install/` into `Install` and replaces `@VERSION@`. `Install.info` starts it with `Installer`.

| File | Does |
|------|------|
| `ptable.head` | version, final report names `SYS:`, welcome, variables for `ptable.inc` |
| `common.inc` | `P_COPY`: copies a file, asks before replacing a newer one; `P_LOADMODULE`: one LoadModule line in `S:User-Startup` shared by cfd and fat95 |
| `ptable.inc` | CPU and small/full choice, `ptable.library` to `LIBS:`, optional `lsptres` |
| `ptable.tail` | `(exit)` |

`Install` = `ptable.head` + `common.inc` + `ptable.inc` + `ptable.tail`.

cfd and fat95 include `common.inc` and `ptable.inc` from here. Variables they set before `ptable.inc`: `ptable-src`, `ptable-libdir`, `ptable-ask-cpu`, `ptable-cpu`, `ptable-ask-lsptres`. It returns `ptable-cpu` and `ptable-flavor`.
