# Installing a large APK under TCG

This is an **optional layer on top of the boot-to-`systemReady` toolkit**. It
installs an arbitrary large (hundreds-of-megabyte) APK into the running guest.

> **Read this honestly:** completing a large-APK install under contended
> software TCG is **stochastic and host-contention-gated**. The single
> interpreted core and a shared/overcommitted host mean a long install can be
> tipped over by a transient memory-corruption event (the `0xffffff8X`
> signature, [ADR 0006](adr/0006-tcg-contention-memory-corruption-limitation.md)).
> `scripts/50-install-apk.sh` encodes the protocol and the safety guards, but it
> is **not guaranteed-reproducible**: it needs a quiet, un-overcommitted host and
> may need several fresh-boot retries. This is a limitation of the environment,
> not a bug in the script.

## Prerequisite: the Group-B oat patches must be in the image BEFORE boot

Apply the two **Group B** patches from
[`patches/oat-patches.md`](../patches/oat-patches.md) to the services oat
*in addition to* the Group-A (systemReady) patches, then boot:

- **`skipVerify`** — drops the redundant second APK Signature-v2 digest that
  `scanPackageLI` would otherwise run over the whole APK (tens of minutes of
  interpreted SHA under TCG on a large APK).
  **SECURITY:** this disables a signature-verification step. Only ever on a
  throwaway, isolated emulator; never carry such an image further.
- **PROC_START timeout** — forces `handleProcessStartedLocked` onto the long
  (1,200,000 ms) process-attach branch, because the package-copy helper cannot
  attach within the stock 10 s under TCG and the install would wedge.

Both live in the same services odex as the Group-A patches. Deploy that one
patched odex **before boot** (bake into `system.img`, preferred; or stage in
`build/oat/` so `40-bringup.sh` binds it before the zygote start). The patches
cannot be applied after the first `system_server` has already scanned.

## Full sequence

```
10-patch-image      (boot byte-patches)
20-build-ramdisk
# apply Group A + Group B oat patches to the services odex; bake or stage it
30-launch           (pure TCG, quiet host)
40-bringup          (to systemReady: package service up)
50-install-apk APK  (the install, with guards)
```

`scripts/50-install-apk.sh /path/to/app.apk` does, in order:

1. **Resolve** the package name from the APK (host-side `aapt`; override with
   `PKG=`).
2. **GUARD (a) — PMS health probe.** A known AOSP system app's launcher activity
   must resolve. After a *corrupt* cold scan, `getActivityInfo` returns null for
   **every** activity of **every** package — a globally corrupt resolver DB, not
   an app problem. If the probe fails, **abandon this boot cleanly** (kill qemu,
   remove the locks, relaunch `30`, re-run `40`) and retry. **Do not restart the
   zygote within a wedged boot** to "heal" — that is just another cold-scan coin
   flip.
3. **Stage + configure.** Push the APK; set `pm.dexopt.install=extract` (so a
   huge APK is not AOT-compiled inline); clear any stale `/data/app/vmdl*.tmp`
   (re-parsing a leftover staged APK during `PMS.<init>` is itself a crash
   trigger under TCG).
4. **Detached install.** Run `pm install -r -t -g` detached on the guest, logged
   to `/data/local/tmp/install.log`, so an adb client timeout cannot lose the
   result. This is the long step (the first signature verify + copy + commit).
5. **GUARD (b) — crash-loop abort.** While watching for the commit, track
   `system_server` restarts. If it starts crash-looping, **ABORT** (stop and
   report). **Never let the boot-scan crash-loop:** its PMS reconcile pass
   *deletes* the committed package. Retry only with a fresh full boot.
6. **Commit + finalize.** On commit, the finalize step (grant permissions /
   dexopt) often SIGKILLs and restarts `system_server`. An `EXIT:224` / "Broken
   pipe" at the very end is usually this benign finalize-restart, not a failure.
7. **The COLD boot-scan is what registers the package.** The restarted
   `system_server` scans the committed `/data/app/<pkg>-*` dir and writes
   `packages.xml`. The verdict is `pm path <pkg>` returning a path.

## Warm vs cold scan

The install itself runs on an **already-warm** `system_server` (methods linked),
which usually survives it. The **cold** post-commit boot-scan hammers the quick
resolution trampoline (first-time method resolution) over the whole package —
the exact path that trips the stochastic corruption — so it is the step most
likely to fail under host load. A committed package therefore sometimes needs
more than one cold boot before one scan lands clean and registers it.

## GUARD (c): committed-but-unregistered is a safe stop

If the install **commits** (the `/data/app/<pkg>-*` dir exists) but the cold
re-scan does **not** register it (`pm path` stays empty), **STOP there**. Leave
the dir in place. Do **not** restart-loop to force registration — that loop is
exactly what reconcile-deletes the package. A single later clean boot on a
quieter host will register the already-committed package. `50-install-apk.sh`
exits with status `2` in this state and says so.

## Gated retry (safe vs forbidden)

- **SAFE / authorized:** multiple **fresh full boots** with clean teardown (kill
  qemu by pid, remove `hardware-qemu.ini.lock` + `multiinstance.lock`, relaunch).
  Budget several boots per successful install — the clean cold scan is a
  stochastic ~1-in-few event, gated by host CPU steal/iowait, not by anything you
  control inside the guest.
- **FORBIDDEN:** crash-looping the zygote/boot-scan within one wedged boot; or
  installing onto a Gate-(a) failure. Both can destroy a committed package or
  burn 15–25 min/boot for nothing.

If a quiet host is not available, this environment cannot reliably complete the
cold scan; a less-contended host is required. None of this changes the
boot-to-`systemReady` result, which is reliable — only the large-APK install on
top of it is stochastic.
