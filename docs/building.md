# Building ptable

## Requirements

Podman. Every target runs in the [amiga-toolchain](https://github.com/pulchart/container-amiga-toolchain) image, which holds vasm, vbcc, the NDK, the test and lint tools, md2guide and lha. Outside the image `make` runs the requested targets there, in one container; inside it, as in CI, make runs them directly. make pulls a newer `latest` when the registry has one; `TOOLCHAIN_IMAGE=` selects another image, such as a dated tag or the Docker Hub copy.

`make` and `make guides` write the binaries and guides to `dist/`, which git ignores except for the version stamps `dist/*.version`.

CI runs on every pull request, master push and manual run in the image's current digest. It lints, builds and tests in parallel and uploads the build as `ptable-dist.<version>`. Then it packs that build into the release archive, checks that the archive holds the build's libraries and lsptres and uploads the archive with its readme as `ptable.<version>`. Each run's summary lists the image, the built files, the test suites and the archive with a download link.

CI builds the head commit of a pull request, not the merge commit GitHub makes for it, and sets `CI_SUFFIX`, which replaces the version suffix of the archive and of every component: `-pr<n>.<hash>` in pull request n, `-master.<hash>` on a master push and `-ci.<hash>` in a manual run, with the short hash of the built commit. A CI build never carries the name of a release, the release archive comes from a local build. `<version>` above is the archive's version, such as `v20261122-pr12.6da062e`.

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
