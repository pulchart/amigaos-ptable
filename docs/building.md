# Building ptable

## Requirements

Podman. Every target runs in the [amiga-toolchain](https://github.com/pulchart/container-amiga-toolchain) image, which holds vasm, vbcc, the NDK, the test and lint tools, md2guide and lha. Outside the image `make` runs the requested targets there, in one container; inside it, as in CI, make runs them directly. make pulls a newer `latest` when the registry has one; `TOOLCHAIN_IMAGE=` selects another image, such as a dated tag or the Docker Hub copy.

`make` and `make guides` write the binaries and guides to `dist/`, which git ignores except for the version stamps `dist/*.version`.

CI builds, lints and tests every pull request and master push in the same image and uploads `dist/` as the `ptable-dist` artifact.

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
| `make lint` | ruff and yamllint |
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
