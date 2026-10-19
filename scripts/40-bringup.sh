#!/bin/sh
# 40-bringup.sh -- in-guest bring-up to systemReady, driven over adb from the
# host. Idempotent; re-run after any qemu/zygote restart (binds and setenforce
# do not survive a reboot).
#
# Sequence:
#   adb root; setenforce 0; stop tombstoned
#   bind a sleeper over the HALs that crash-loop in their static constructors
#   (optionally) bind patched framework oats for the watchdog/finalizer/GNSS
#     fixes (see patches/oat-patches.md) if you staged them in build/oat/
#   start the media-service stub (+ svc.list storaged) so AudioService and
#     StorageManagerService unblock
#   restart the zygote so a fresh system_server picks up the stub + oats
#   start WdCtl (IActivityController "keep waiting")
#   wait until `service check package` reports found == systemReady
set -e
. "$(dirname "$0")/lib/common.sh"
require javac "$ADB_BIN"
T=/data/local/tmp
OATSTAGE="$BUILD_DIR/oat"     # optional: drop patched services odex / boot-core-libart oat here

# --- host side: build the helper dexes ---------------------------------------
D8="$SDK_ROOT/build-tools/28.0.3/d8"
AJAR="$SDK_ROOT/platforms/android-28/android.jar"
DEXDIR="$BUILD_DIR/dex"
build_dex() {   # <name> <src> <MainGlob>
  out="$DEXDIR/$1"; mkdir -p "$out"
  javac --release 8 -cp "$AJAR" -d "$out" "$2"
  "$D8" --min-api 28 --lib "$AJAR" --output "$out" "$out"/$3
  cp "$out/classes.dex" "$DEXDIR/$1.dex"
}
if [ ! -f "$DEXDIR/stub.dex" ] || [ ! -f "$DEXDIR/wdctl.dex" ]; then
  [ -f "$AJAR" ] || die "android.jar missing -- run 00-setup.sh"
  [ -f "$D8" ]   || die "d8 missing -- run 00-setup.sh"
  log "== build helper dexes"
  build_dex stub  "$REPO_ROOT/src/stub/Stub.java"   'Stub*.class'
  build_dex wdctl "$REPO_ROOT/src/wdctl/WdCtl.java"  'WdCtl*.class'
fi

# --- wait for the device and get root ----------------------------------------
log "== wait for adb device"
"$ADB_BIN" start-server >/dev/null 2>&1 || true
until [ "$(adbx get-state 2>/dev/null)" = device ]; do sleep 10; done
timeout 60 adbx root >/dev/null 2>&1 || true
sleep 5
timeout 300 adbx wait-for-device
until ash id 2>/dev/null | grep -q uid=0; do sleep 10; done
log "== adb root ok"

# --- push helpers -------------------------------------------------------------
adbx push "$REPO_ROOT/src/sleeper.sh" "$T/sleeper.sh" >/dev/null
adbx push "$DEXDIR/stub.dex"  "$T/stub.dex"  >/dev/null
adbx push "$DEXDIR/wdctl.dex" "$T/wdctl.dex" >/dev/null
ash "chmod 755 $T/sleeper.sh"

# --- guest-side bring-up (one script, run detached) ---------------------------
# Optional patched oats: bind them if staged. Without them the first
# system_server may Watchdog-crash-loop; prefer baking them into system.img per
# patches/oat-patches.md for a hands-off boot.
BIND_OAT=""
if [ -f "$OATSTAGE/services.odex" ]; then
  adbx push "$OATSTAGE/services.odex" "$T/services.odex" >/dev/null
  BIND_OAT="$BIND_OAT services"
fi
if [ -f "$OATSTAGE/boot-core-libart.oat" ]; then
  adbx push "$OATSTAGE/boot-core-libart.oat" "$T/boot-core-libart.oat" >/dev/null
  BIND_OAT="$BIND_OAT libart"
fi
[ -n "$BIND_OAT" ] || log "NOTE: no patched oats staged in build/oat/ -- see patches/oat-patches.md (bake into system.img for a clean first boot)"

log "== run guest bring-up"
ash "T=$T BIND_OAT='$BIND_OAT' sh -s" <<'GUEST'
set -x
exec >>$T/bringup.log 2>&1
echo "== bringup start uptime=$(cat /proc/uptime)"
setenforce 0
echo "enforce=$(getenforce)"

# Stop tombstoned: under TCG crash_dump is pathologically slow (it ptrace-stops
# the crasher, then hits its own SIGALRM minutes later) and can deadlock the
# guest if the crasher held a lock. With it stopped, a crash just dies fast.
stop tombstoned

# HAL crash loops: bind the sleeper over each binary, and stop the two system
# daemons. init refuses to exec a shell_data_file, so the service stays dead.
for b in /system/bin/statsd /system/bin/storaged \
    /vendor/bin/hw/android.hardware.audio@2.0-service \
    /vendor/bin/hw/android.hardware.broadcastradio@1.1-service \
    /vendor/bin/hw/android.hardware.media.omx@1.0-service \
    /vendor/bin/hw/hardware.google.media.c2@1.0-service; do
  [ -e "$b" ] || continue
  grep -q " $b " /proc/mounts || mount -o bind $T/sleeper.sh "$b"
done
for s in statsd storaged vendor.audio-hal-2-0 broadcastradio-hal vendor.media.omx hardware-google-media-c2-hal-1-0; do
  stop "$s" 2>/dev/null || true
done

# Optional: bind staged patched oats (watchdog/finalizer/GNSS fixes). Binds must
# precede the zygote (re)start to affect system_server.
if echo "$BIND_OAT" | grep -q services && [ -f $T/services.odex ]; then
  while grep -q " /system/framework/oat/arm64/services.odex " /proc/mounts; do
    umount /system/framework/oat/arm64/services.odex 2>/dev/null || break
  done
  mount -o bind $T/services.odex /system/framework/oat/arm64/services.odex
  echo "bound patched services.odex"
fi
if echo "$BIND_OAT" | grep -q libart && [ -f $T/boot-core-libart.oat ]; then
  grep -q " /system/framework/arm64/boot-core-libart.oat " /proc/mounts || \
    mount -o bind $T/boot-core-libart.oat /system/framework/arm64/boot-core-libart.oat
  echo "bound patched boot-core-libart.oat"
fi

running() {  # running <MainClass>: an app_process64 with that class alive?
  for p in $(pidof app_process64); do
    grep -q "$1" /proc/$p/cmdline 2>/dev/null && return 0
  done
  return 1
}

# Media stub (AudioService / StorageManager waits). svc.list adds storaged:
# StorageManagerService only connects once both vold and storaged are registered.
echo storaged > $T/svc.list
if ! running Stub; then
  CLASSPATH=$T/stub.dex setsid /system/bin/app_process64 /system/bin Stub >$T/stub.log 2>&1 </dev/null &
  echo "stub started pid $!"
fi

# Restart the zygote AFTER the stub is registered: the first system_server
# (started at boot, before the stub) dies in init when it reaches AudioService /
# StorageManager with no media.audio_policy / storaged; the restarted one finds
# the stub up and reaches systemReady.
echo "restart zygote at uptime=$(cat /proc/uptime)"
stop zygote; start zygote

# Watchdog controller: answers "keep waiting" so a handler blocked during a long
# interpreted operation does not get system_server killed.
if ! running WdCtl; then
  CLASSPATH=$T/wdctl.dex setsid /system/bin/app_process64 /system/bin WdCtl >$T/wdctl.log 2>&1 </dev/null &
  echo "wdctl started pid $!"
fi
echo "== bringup done uptime=$(cat /proc/uptime)"
GUEST

# --- wait for systemReady (the package service) -------------------------------
log "== wait for package service (systemReady)"
i=0
until ash service check package 2>/dev/null | grep -q ": found"; do
  i=$((i + 1)); [ "$i" -ge 120 ] && die "package service not up after ~40 min"
  sleep 20
done
log "== READY: package service up (systemReady reached)"
# The front-end keeps the screen on, which eats most of the single TCG core on
# vsync/rendering. Turn it off for a quiet guest (keyevent 224 wakes it again).
ash input keyevent 223 >/dev/null 2>&1 || true
log "== 40-bringup done"
