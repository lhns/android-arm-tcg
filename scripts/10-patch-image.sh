#!/bin/sh
# 10-patch-image.sh -- apply the boot byte-patches (patches/boot-patches.toml)
# to the DOWNLOADED emulator binary, guest kernel and a front-end library, and
# rebuild the vendor image (raw ext4 on vde, forceencrypt stripped, crash-loop
# HALs disabled). Idempotent and self-validating: each patch verifies its
# before-bytes/needle and a mismatched build aborts cleanly.
#
# The init.real timeout patch (same toml, id init-required-devices-timeout) is
# NOT applied here -- it lands in 20-build-ramdisk.sh on the extracted init.
set -e
. "$(dirname "$0")/lib/common.sh"
require "$PYTHON" dd od debugfs

[ -x "$QEMU" ] || die "emulator not found at $QEMU -- run 00-setup.sh"
[ -f "$IMG/kernel-ranchu" ] || die "kernel-ranchu missing -- run 00-setup.sh"

patch_required() { apply_patch "$1" "$2" || die "required patch '$1' on $2 failed"; }
patch_optional() {               # tolerate 'needle absent' (rc 3) for a best-effort file
  apply_patch "$1" "$2"; rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || die "patch '$1' on $2 failed (rc=$rc)"
}

log "== emulator binary patches"
patch_required soundhw-pci-abort   "$QEMU"
patch_required emu-keep-initramfs  "$QEMU"
patch_required heapsize-cap        "$QEMU"

log "== kernel patch"
patch_required kernel-keep-initramfs "$IMG/kernel-ranchu"

log "== guest fstab device string -> /dev/block/vde"
# Documented in libgfxstream_backend.so; also present in a few sibling libs.
# Require the documented one; best-effort the rest.
patch_required fstab-dev-vde "$EMU_DIR/lib64/libgfxstream_backend.so"
for lib in lib64/libandroid-emu-shared.so lib64/libandroid-webrtc.so nimble_bridge emulator; do
  [ -f "$EMU_DIR/$lib" ] && patch_optional fstab-dev-vde "$EMU_DIR/$lib" || true
done

log "== rebuild vendor image (raw ext4 on vde)"
VENDOR="$IMG/vendor.img"
GPT="$IMG/vendor.img.gpt"
RAW="$BUILD_DIR/vendor-arm64.img"
magic_at() { dd if="$1" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n'; }

if [ "$(magic_at "$VENDOR")" = 53ef ]; then
  log "   vendor.img is already raw ext4; re-validating patches on it"
  cp "$VENDOR" "$RAW"
else
  # Stock vendor.img is GPT-wrapped. The front-end presents vendor on vde only
  # if it starts with an ext4 superblock, so carve the single ext4 partition out
  # of the GPT and install it raw. Keep the stock GPT once for re-runs.
  [ -f "$GPT" ] || cp "$VENDOR" "$GPT"
  # Pinned image GPT: the one partition is first-LBA 2048, 196608 sectors.
  dd if="$GPT" bs=512 skip=2048 count=196608 of="$RAW" status=none
  [ "$(magic_at "$RAW")" = 53ef ] || die "carved vendor lacks ext4 magic -- GPT layout changed for this build?"
fi

# Blank the forceencrypt fs_mgr flag so vold mounts /data.
patch_required vendor-forceencrypt "$RAW"

# Remove the init .rc of the vendor HALs that crash-loop in their static
# constructors under TCG. Left running they saturate the single vCPU before the
# bring-up can sleeper them; none are needed to reach systemReady (media is
# stubbed). The bring-up still sleepers the two SYSTEM crash-loopers at runtime.
for rc in android.hardware.media.omx@1.0-service.rc \
          android.hardware.broadcastradio@1.1-service.rc \
          android.hardware.audio@2.0-service.rc \
          hardware.google.media.c2@1.0-service.rc; do
  debugfs -w -R "rm /etc/init/$rc" "$RAW" >/dev/null 2>&1 || true
done

cp "$RAW" "$VENDOR"
log "   vendor.img is now raw ext4 ($(wc -c <"$VENDOR") bytes), crash-loop HALs disabled"
log "== 10-patch-image done"
