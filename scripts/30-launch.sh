#!/bin/sh
# 30-launch.sh -- launch the arm64 guest in pure software TCG (no KVM), headless.
# Creates the /data disk if missing, then starts qemu in the background and
# writes its console log to build/emu.log and its pid to build/qemu.pid.
#
#   CORES=1 MEM=4096 scripts/30-launch.sh
#
# CORES default 1 (fastest under TCG; >1 is ~2x slower on the stock kernel, see
# docs/PERF.md). MEM default 4096 MiB -- do NOT raise it: at 6144/8192 ART cannot
# mmap its concurrent-copying GC region space under TCG and system_server aborts
# at startup ("region_space_mem_map != nullptr"). 4096 is the confirmed-good value.
set -e
. "$(dirname "$0")/lib/common.sh"

CORES=${CORES:-1}
MEM=${MEM:-4096}
KERNEL=${KERNEL:-$IMG/kernel-ranchu}
RAMDISK=${RAMDISK:-$BUILD_DIR/ramdisk-wrap.img}
DATA="$BUILD_DIR/userdata-arm64.qcow2"
EMU_LOG="$BUILD_DIR/emu.log"
PIDFILE="$BUILD_DIR/qemu.pid"

[ -x "$QEMU" ]      || die "emulator not found -- run 00-setup.sh"
[ -f "$RAMDISK" ]   || die "ramdisk not built -- run 20-build-ramdisk.sh"
[ -f "$IMG/vendor.img" ] || die "vendor image missing -- run 10-patch-image.sh"

# --- /data disk (guest-compatible ext4 wrapped as qcow2) ---------------------
# Built host-side with a modern mke2fs, minus the features the guest's old
# e2fsck/kernel reject (no metadata_csum, no 64bit), so the guest never needs
# resize2fs. Never clobber an existing /data (FORCE=1 to recreate).
if [ ! -f "$DATA" ] || [ "${FORCE:-0}" = 1 ]; then
  require mke2fs qemu-img
  SIZE=${DATA_SIZE:-6G}
  log "== create /data ($SIZE ext4 -> qcow2)"
  RAW="$BUILD_DIR/userdata.raw"
  rm -f "$RAW" "$DATA"
  truncate -s "$SIZE" "$RAW"
  mke2fs -q -F -t ext4 -b 4096 -L data \
    -O ^metadata_csum,^64bit,^orphan_file,^metadata_csum_seed "$RAW"
  qemu-img convert -f raw -O qcow2 "$RAW" "$DATA"
  rm -f "$RAW"
fi

# --- launch -------------------------------------------------------------------
export LD_LIBRARY_PATH="$EMU_DIR/lib64/gles_swiftshader:$EMU_DIR/lib64"
export ANDROID_SDK_ROOT="$SDK_ROOT"
export ANDROID_I_WANT_MY_TCG=yes

rm -rf "$IMG/hardware-qemu.ini.lock" "$IMG/multiinstance.lock"
[ -f "$EMU_LOG" ] && mv "$EMU_LOG" "$EMU_LOG.prev" 2>/dev/null || true

# psci-conduit=1 (HVC) is only needed to bring up secondary vCPUs (CORES>1);
# ranchu never sets it under TCG. Harmless but omitted at CORES=1. See docs/PERF.md.
PSCI=""
[ "$CORES" -gt 1 ] && PSCI="-qemu -global arm-cpu.psci-conduit=1"

log "== launch qemu (TCG, CORES=$CORES MEM=${MEM}MiB) -> $EMU_LOG"
setsid "$QEMU" \
  -sysdir "$IMG" -system "$IMG/system.img" -vendor "$IMG/vendor.img" \
  -kernel "$KERNEL" -ramdisk "$RAMDISK" \
  -data "$DATA" \
  -memory "$MEM" -cores "$CORES" -no-window -no-audio -no-boot-anim -no-snapshot \
  -no-metrics -accel off -gpu swiftshader_indirect -feature -Vulkan \
  -ports 5554,5555 -show-kernel $PSCI </dev/null >"$EMU_LOG" 2>&1 &
echo $! > "$PIDFILE"
log "== 30-launch done: qemu pid $(cat "$PIDFILE"). Follow with: tail -f $EMU_LOG"
log "   next: scripts/40-bringup.sh"
