#!/bin/sh
# 20-build-ramdisk.sh -- cross-compile src/initwrap.c and rebuild the boot
# ramdisk around it. NO ramdisk is committed: it is reconstructed here from the
# DOWNLOADED image's ramdisk plus the freshly compiled wrapper.
#
# Steps:
#   1. aarch64-linux-gnu-gcc -static  src/initwrap.c -> build/init (the wrapper)
#   2. unpack the downloaded ramdisk.img (gzip|cat + cpio)
#   3. preserve the image's /init as /init.real (the second stage) and apply the
#      init-required-devices-timeout byte-patch to it
#   4. install the compiled wrapper as /init
#   5. repack (cpio newc + gzip), root-owned, -> build/ramdisk-wrap.img
#
# Run as root so the repacked cpio records root ownership (the provided
# container does).
set -e
. "$(dirname "$0")/lib/common.sh"
require aarch64-linux-gnu-gcc cpio gzip "$PYTHON"

SRC="$REPO_ROOT/src/initwrap.c"
RAMDISK_IN="$IMG/ramdisk.img"
RD="$BUILD_DIR/rd"
OUT="$BUILD_DIR/ramdisk-wrap.img"
[ -f "$RAMDISK_IN" ] || die "ramdisk.img missing -- run 00-setup.sh"

log "== cross-compile initwrap"
aarch64-linux-gnu-gcc -static -O2 -o "$BUILD_DIR/init" "$SRC"

log "== unpack downloaded ramdisk"
rm -rf "$RD"; mkdir -p "$RD"
# Android ramdisks are usually gzip'd cpio-newc; tolerate an uncompressed one.
if gzip -t "$RAMDISK_IN" 2>/dev/null; then DECOMP="gzip -dc"; else DECOMP="cat"; fi
( cd "$RD" && $DECOMP "$RAMDISK_IN" | cpio -idm --quiet )
[ -f "$RD/init" ] || die "no /init in the unpacked ramdisk"

log "== preserve image init as /init.real and patch its device-wait timeout"
# If we already ran, /init.real holds the real init; otherwise the current /init is it.
if [ ! -f "$RD/init.real" ]; then
  cp -a "$RD/init" "$RD/init.real"
fi
apply_patch init-required-devices-timeout "$RD/init.real" \
  || die "init.real timeout patch failed"

log "== install compiled wrapper as /init"
cp "$BUILD_DIR/init" "$RD/init"
chmod 0750 "$RD/init" "$RD/init.real"

log "== repack ramdisk (root-owned)"
( cd "$RD" && find . | cpio -o -H newc --quiet | gzip -9 ) > "$OUT"
log "== 20-build-ramdisk done: $OUT ($(wc -c <"$OUT") bytes)"
