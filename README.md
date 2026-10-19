# android-arm-tcg

Reproducibly boot and bring up **Android (API 28, `arm64-v8a`, `google_apis`)
under QEMU TCG on an x86_64 host with no hardware virtualization (no KVM)**,
all the way to a working `systemReady` (the `package` service is up).

The stock Android emulator refuses to run an arm64 guest on an x86_64 host
without KVM. This toolkit takes the pure-software TCG path instead: it downloads
a pinned SDK and system image, applies a set of boot byte-patches to the
downloaded files, builds a small init-wrapper ramdisk, launches QEMU in
pure-TCG mode (`-accel off`), and runs an in-guest bring-up sequence that works
around the handful of services that misbehave under a single interpreted vCPU.

Scope is **boot to `systemReady`**. Installing or running specific apps is out
of scope. The project is a generic Android-on-ARM-emulation bring-up toolkit.

## Why this is hard (and why TCG at all)

- **No `/dev/kvm`.** On an x86_64 host without nested virtualization you cannot
  KVM-accelerate anything, and you cannot KVM-run an *arm64* guest even with
  KVM (KVM does not emulate a foreign ISA). So an arm64 Android guest on an
  x86_64 host means full software emulation: QEMU TCG.
- The emulator gates arm64-on-x86_64 behind an env flag
  (`ANDROID_I_WANT_MY_TCG=yes`) and `-accel off`. Once there, TCG is the whole
  problem: one interpreted guest core, vendor HALs that crash in their static
  constructors, watchdogs that fire during multi-minute interpreted operations,
  and a first-stage boot that assumes devices that never appear. This toolkit
  encodes the fixes for each.

## Prerequisites

- An x86_64 Linux host (or a container on one). A build/run container is
  provided in [`docker/Dockerfile`](docker/Dockerfile) (`eclipse-temurin:21-jdk`
  plus the cross-compiler, image tools, and a software GL stack for the headless
  emulator).
- Host packages if you are not using the container: `unzip`, `e2fsprogs`
  (`debugfs`/`mke2fs`), `qemu-utils` (`qemu-img`), `cpio`, `gcc-aarch64-linux-gnu`
  + `binutils-aarch64-linux-gnu`, `python3`, a JDK (for the two helper dexes),
  and a software GL stack (Mesa/llvmpipe) for the "headless" emulator binary
  (it still dlopens a host GL).
- Disk: the download is a few GB; the extracted/patched images and `/data`
  overlay need roughly 10 GB free.

## Quickstart

Scripts are numbered and run in order. Each is idempotent and parameterises its
SDK root (`SDK_ROOT`, default `./sdk`).

```sh
scripts/00-setup.sh        # download pinned cmdline-tools, emulator, system image, tools
scripts/10-patch-image.sh  # apply the boot byte-patches to the downloaded files
scripts/20-build-ramdisk.sh# cross-compile initwrap, rebuild the ramdisk around it
scripts/30-launch.sh       # launch qemu-system-aarch64 in pure TCG
scripts/40-bringup.sh      # in-guest bring-up: sleepers, media stub, zygote, wait for package
```

`30-launch.sh` runs the emulator in the background and writes its console log;
`40-bringup.sh` waits for adb, takes `adb root`, and drives the guest to
`systemReady`. Both parameterise `CORES` (default 1 — fastest under TCG, see
[docs/PERF.md](docs/PERF.md)) and `MEM` (default 4096 MiB).

### Optional: install a large APK

Installing a large (hundreds-of-megabyte) APK into the running guest is an
optional layer on top of `systemReady`:

```sh
scripts/50-install-apk.sh /path/to/app.apk
```

It needs two extra build-specific oat patches applied **before boot** (Group B
in [patches/oat-patches.md](patches/oat-patches.md), one of which skips a
signature-verify step — read the security note). Completing a large-APK install
under contended software TCG is **stochastic and host-contention-gated**: it
needs a quiet host and is not guaranteed on any single run. See
[docs/INSTALL.md](docs/INSTALL.md) for the full protocol, the safety guards, and
the honest caveats.

Using the container:

```sh
docker build -t android-arm-tcg docker/
docker run --rm -it -v "$PWD:/work" -w /work android-arm-tcg \
  sh -c 'scripts/00-setup.sh && scripts/10-patch-image.sh && \
         scripts/20-build-ramdisk.sh && scripts/30-launch.sh && scripts/40-bringup.sh'
```

## Layout

| Path | What |
|------|------|
| `scripts/00..40` | the bring-up pipeline (download, patch, build, launch, in-guest) |
| `scripts/50-install-apk.sh` | optional: install a large APK into the running guest |
| `scripts/lib/`   | shared shell helpers and the byte patcher |
| `src/initwrap.c` | the switch-root init wrapper (the key boot fix) |
| `src/stub/`, `src/wdctl/`, `src/sleeper.sh` | in-guest bring-up helpers (source only) |
| `patches/boot-patches.toml` | boot byte-patch specs (offsets/bytes as text) applied to downloaded files |
| `patches/oat-patches.md` | generic oat recipe: Group A (reach systemReady — watchdog/finalizer timeouts, GNSS init hang) + Group B (install a large APK) |
| `tools/tcg-probe/` | a standalone TCG correctness/stability stress probe |
| `docs/PERF.md`, `docs/BRINGUP.md`, `docs/INSTALL.md` | performance rationale, bring-up sequence/gotchas, large-APK install protocol |
| `docs/adr/` | architecture decision records |

## No binaries, by construction

This repository contains **only text**. Every binary (SDK, system image,
ramdisk, compiled helpers, patched odex/oat) is downloaded or built at runtime
by the scripts. The patch specs are offsets and bytes *as text*; the scripts
apply them to the downloaded files and verify the before/after bytes. See
[`.gitignore`](.gitignore) and [`docs/adr`](docs/adr/README.md).
