#!/bin/sh
# 50-install-apk.sh -- install an arbitrary large APK into the running guest,
# using the install protocol that works under contended single-core TCG.
#
#   scripts/50-install-apk.sh /path/to/app.apk
#   APK=/path/to/app.apk scripts/50-install-apk.sh
#
# PREREQUISITE: the two Group-B install patches (skipVerify + PROC_START) must
# already be in the services oat BEFORE the guest booted -- see
# patches/oat-patches.md and docs/INSTALL.md. This script does NOT patch the
# image; it only drives the install.
#
# READ docs/INSTALL.md first. Completing a large-APK install under contended TCG
# is STOCHASTIC and host-contention-gated (see docs/adr/0006): it needs a quiet
# host and is not guaranteed to succeed on any single run, even with this script.
#
# Guards baked in (do not remove):
#   (a) probe PMS health first -- a system app's activity must resolve; a corrupt
#       cold scan means ABANDON this boot (fresh boot), never install onto it.
#   (b) if system_server starts crash-looping, ABORT (stop + report). NEVER let
#       the boot-scan crash-loop: its reconcile deletes the committed package.
#   (c) if it commits but the cold re-scan does not register it, STOP at
#       committed-but-unregistered (leave the dir; a later single clean boot
#       registers it). Do NOT restart-loop to force it.
set -e
. "$(dirname "$0")/lib/common.sh"
require "$ADB_BIN"

APK=${APK:-$1}
[ -n "$APK" ] || die "usage: $0 <app.apk>   (or APK=... $0)"
[ -f "$APK" ] || die "APK not found: $APK"
T=/data/local/tmp
GUEST_APK="$T/app.apk"
CRASH_ABORT=${CRASH_ABORT:-3}        # system_server restarts before we abort

# --- resolve the package name (host-side, via aapt) --------------------------
PKG=${PKG:-}
if [ -z "$PKG" ]; then
  AAPT="$SDK_ROOT/build-tools/28.0.3/aapt"
  [ -x "$AAPT" ] || AAPT="$SDK_ROOT/build-tools/28.0.3/aapt2"
  PKG=$("$AAPT" dump badging "$APK" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)
fi
[ -n "$PKG" ] || die "could not determine package name from $APK; pass PKG=<name>"
log "package: $PKG"

# --- device + root ------------------------------------------------------------
"$ADB_BIN" start-server >/dev/null 2>&1 || true
[ "$(adbx get-state 2>/dev/null)" = device ] || die "no device; run 30-launch.sh + 40-bringup.sh first"
timeout 60 adbx root >/dev/null 2>&1 || true
sleep 5
timeout 300 adbx wait-for-device
until ash id 2>/dev/null | grep -q uid=0; do sleep 10; done
ash service check package 2>/dev/null | grep -q ": found" || die "package service not up; run 40-bringup.sh to systemReady first"

# --- GUARD (a): PMS health probe ---------------------------------------------
# After a corrupt cold scan, getActivityInfo returns null for EVERY activity of
# EVERY package (not an app problem). Probe with a known AOSP system app: if its
# launcher activity does not resolve, the resolver DB is corrupt -> abandon this
# boot cleanly (do a fresh full boot) rather than installing onto it.
log "== GUARD (a): probe PMS health"
probe=$(ash "am start -n com.android.settings/.Settings" 2>&1 | tr -d '\r')
if echo "$probe" | grep -qiE "does not exist|Error type 3"; then
  die "PMS cold scan is corrupt (a system activity will not resolve). ABANDON this boot: kill qemu, remove the locks, relaunch (30), re-run 40, then retry. Do NOT restart zygote within this boot."
fi
ash "am force-stop com.android.settings" >/dev/null 2>&1 || true
log "   PMS healthy"

# --- stage + configure --------------------------------------------------------
log "== push APK ($(wc -c <"$APK") bytes) -> $GUEST_APK"
timeout 3600 adbx push "$APK" "$GUEST_APK" >/dev/null || die "push failed"
# extract (not dex2oat) during install so a huge APK is not AOT-compiled inline.
ash "setprop pm.dexopt.install extract"
# Clear any stale staged dir: re-parsing a leftover vmdl during PMS.<init> is a
# known crash trigger under TCG.
ash "rm -rf /data/app/vmdl*.tmp" >/dev/null 2>&1 || true

# --- detached guest-side install, logged on-guest -----------------------------
# Run detached so an adb client timeout does not lose the result; the guest log
# is the source of truth.
ash "rm -f $T/install.log"
log "== pm install -r -t -g (detached on guest); this is the long step"
ash "setsid sh -c 'pm install -r -t -g $GUEST_APK >$T/install.log 2>&1; echo EXIT:\$? >>$T/install.log' </dev/null >/dev/null 2>&1 &"

# --- watch for commit, with the crash-loop guard ------------------------------
ss_last=$(ash pidof system_server 2>/dev/null | tr -d '\r' | awk '{print $1}')
restarts=0
committed=0
i=0
while [ "$i" -lt 240 ]; do          # up to ~2h of 30s polls
  i=$((i + 1))
  tail=$(ash "tail -3 $T/install.log 2>/dev/null" | tr -d '\r')
  if echo "$tail" | grep -qiE "^Success|EXIT:0"; then committed=1; break; fi
  if echo "$tail" | grep -qiE "EXIT:[1-9]|Failure|Broken pipe"; then
    # EXIT:224 / Broken pipe is the benign finalize-restart case; the package may
    # still have committed. Fall through to the pm path verdict below.
    log "   install log reports a non-clean exit: $(echo "$tail" | tail -1)"
    committed=1; break
  fi
  # GUARD (b): count system_server restarts.
  ss=$(ash pidof system_server 2>/dev/null | tr -d '\r' | awk '{print $1}')
  if [ -n "$ss" ] && [ -n "$ss_last" ] && [ "$ss" != "$ss_last" ]; then
    restarts=$((restarts + 1))
    log "   NOTE: system_server restarted (pid $ss_last -> $ss, restarts=$restarts)"
    [ "$restarts" -ge "$CRASH_ABORT" ] && die "system_server is crash-looping (restarts=$restarts). ABORT. Do NOT retry on this boot -- a crash-looping boot-scan reconcile-DELETES the package. Start a fresh full boot and retry on a quieter host."
  fi
  [ -n "$ss" ] && ss_last=$ss
  sleep 30
done
[ "$committed" = 1 ] || die "install did not finish within the watch window; check $T/install.log on the guest"

# --- GUARD (c): verify registration; the COLD boot-scan is what registers -----
# The finalize step often SIGKILLs + restarts system_server; the subsequent cold
# boot-scan of the committed /data/app dir is what writes packages.xml. Wait for
# pm path, keeping the crash-loop guard live.
log "== wait for the package to register (pm path)"
j=0
while [ "$j" -lt 60 ]; do
  j=$((j + 1))
  if ash "pm path $PKG" 2>/dev/null | grep -q "^package:"; then
    log "== INSTALLED + REGISTERED: $(ash pm path $PKG | tr -d '\r')"
    exit 0
  fi
  ss=$(ash pidof system_server 2>/dev/null | tr -d '\r' | awk '{print $1}')
  if [ -n "$ss" ] && [ -n "$ss_last" ] && [ "$ss" != "$ss_last" ]; then
    restarts=$((restarts + 1))
    [ "$restarts" -ge "$CRASH_ABORT" ] && die "system_server crash-looping during the post-commit scan (restarts=$restarts). STOP. The committed dir may be in /data/app; do NOT restart-loop (that deletes it). Let the guest settle, then try ONE clean boot on a quieter host."
  fi
  [ -n "$ss" ] && ss_last=$ss
  sleep 30
done

# Committed but not registered: a legitimate safe stopping point.
if ash "ls /data/app" 2>/dev/null | tr -d '\r' | grep -q "$PKG"; then
  log "STOP: committed-but-unregistered. /data/app holds the package dir but the"
  log "      cold scan has not registered it (pm path empty). Do NOT restart-loop"
  log "      to force it -- that reconcile can delete it. A single later clean boot"
  log "      on a quiet host will register it. See docs/INSTALL.md."
  exit 2
fi
die "install committed nothing (no /data/app dir for $PKG and pm path empty); check $T/install.log and retry on a quieter host"
