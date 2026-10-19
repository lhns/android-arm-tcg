# Bring-up: boot to systemReady under TCG

This is the end-to-end sequence the scripts automate, the reasoning behind each
step, and the gotchas. Scope is reaching and holding `systemReady` (the
`package` service up). App install/launch is out of scope.

## Pipeline

```
00-setup        download pinned emulator + system image + tools
10-patch-image  byte-patch the downloaded binaries; rebuild vendor as raw ext4
20-build-ramdisk cross-compile initwrap; rebuild the ramdisk around it
30-launch       start qemu in pure TCG (no KVM), headless, background
40-bringup      adb root; in-guest workarounds; wait for the package service
```

## Boot chain (why the patches exist)

1. **Kernel keeps the initramfs.** The front-end puts `skip_initramfs` on the
   kernel cmdline, which tells the kernel to ignore our ramdisk and boot
   system-as-root directly. Renaming the token (`keep_initramfs`) in both the
   emulator binary and the kernel makes the kernel run the initramfs `/init` —
   our `initwrap`.
2. **`initwrap` does a canonical switch_root** (see `src/initwrap.c` and
   [ADR 0003](adr/0003-initwrap-switch-root-fd-whitelist.md)). It mounts the
   system partition, overrides its `/init` with the patched `/init.real`, moves
   `/dev /proc /sys` into the new root, `MS_MOVE`s the new root onto `/`, and
   `chroot`s. The canonical sequence (and, critically, `MS_REC|MS_PRIVATE`
   first) is what keeps the forked zygote rooted at `/` rather than `/newroot`;
   otherwise the zygote's fd-whitelist rejects every `/newroot/...` fd and
   crash-loops.
3. **First-stage device wait.** `/init.real`'s `InitRequiredDevices` aborts when
   a by-name uevent for a required device never arrives under this emulated
   topology. The `init-required-devices-timeout` patch forces the OK return so
   boot proceeds to the vendor/data mounts.
4. **Mounts.** The front-end builds the guest fstab `dev` path from a template
   that resolves to a by-name symlink first stage never creates; the
   `fstab-dev-vde` patch points it at the whole-disk node `/dev/block/vde`.
   Vendor is presented raw on `vde` only if it begins with an ext4 superblock,
   so 10-patch-image carves the ext4 partition out of the GPT-wrapped
   `vendor.img`. `forceencrypt` is blanked in the vendor fstab so vold mounts
   `/data` instead of skipping it (which would keep the zygote from starting).

## In-guest bring-up (40-bringup)

Everything here is lost on a qemu/zygote restart, so the step is idempotent and
re-runnable.

- **`setenforce 0`.** First-boot policy surprises under TCG otherwise reboot-loop
  the bring-up.
- **Stop `tombstoned`.** Under TCG `crash_dump` is pathologically slow and can
  deadlock the guest if a crasher held a lock. With it stopped, incidental
  crashes die fast and do not wedge the single core.
- **HAL sleepers.** Several vendor/system HALs crash in their static
  constructors under TCG (`std::bad_alloc`, SIGSEGV), relaunch, and eat the one
  core. The crash-loopers are: `statsd`, `storaged`,
  `android.hardware.audio@2.0`, `android.hardware.broadcastradio@1.1`,
  `android.hardware.media.omx@1.0`, `hardware.google.media.c2@1.0`. The vendor
  ones are removed at the image level; the two system ones are bind-covered with
  a sleeper (`src/sleeper.sh`). init refuses to exec a `shell_data_file`, so the
  service stays dead rather than looping — which is what we want.
- **Media stub.** Pie's `SystemServer` always starts `AudioService`, whose
  `systemReady()` blocks the system_server **main** thread waiting for
  `media.audio_policy` / `media.sound_trigger_hw`; `StorageManagerService` then
  never becomes ready. The real media HALs never register (they crashed). A tiny
  root process (`src/stub/Stub.java`) registers those media names with a Binder
  that just answers no-exception + 0, which is enough to unblock the waiters.
  **Do not register SurfaceFlinger** — a dummy one makes `DisplayManagerService`
  time out. `svc.list` adds `storaged`, because `StorageManagerService.connect()`
  needs both `vold` and `storaged` registered.
- **Zygote restart after the stub is up.** The first system_server (started at
  boot, before the stub) dies in init when it reaches AudioService /
  StorageManager with nothing registered; the restarted one finds the stub up
  and reaches `systemReady`.
- **Framework timeout / init-hang oats.** Optional but recommended for a stable
  systemReady (see [`patches/oat-patches.md`](../patches/oat-patches.md)): the
  GNSS provider init hang parks the main looper under TCG; the framework
  Watchdog kills system_server when a monitored handler blocks during a long
  interpreted operation; the finalizer watchdog aborts the VM on a slow
  `finalize()`. Bake the patched oats into `system.img` (active from first boot)
  or stage them in `build/oat/` for 40-bringup to bind. `WdCtl`
  (`src/wdctl/WdCtl.java`) complements the Watchdog timeout by answering "keep
  waiting".

## Gotchas

- The TCG shell is slow. Use one command per `adb shell`, with 30–150 s
  timeouts. `pidof` / `getprop` / `service check` are the reliable liveness
  checks; `ps -A` and multi-command scripts often look hung.
- `adb root` restarts adbd; after it, give the device a few seconds and
  `wait-for-device`. Repeatedly thrashing `adb root`/`reconnect` drives the
  device "offline" — do it once.
- `service check package` reporting `found` is the real readiness test;
  `sys.boot_completed=1` can be stale across a zygote restart.
- Bind mounts and `setenforce 0` do not survive a guest reboot — re-run
  40-bringup.
- Keep the screen off (`input keyevent 223`); a screen-on guest spends most of
  the single core on vsync/rendering.
