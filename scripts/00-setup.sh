#!/bin/sh
# 00-setup.sh -- download the PINNED SDK pieces into SDK_ROOT. Idempotent:
# re-running skips any piece already present, so it resumes after an interruption.
#
# Pinned, because every offset and tuning assumes an exact build:
#   emulator 37.3.3 (build 16489710), QEMU 2.12 base -- sdkmanager cannot pin it
#       (not in the current manifest), so the exact zip is overlaid by URL+SHA-256.
#   system-images;android-28;google_apis;arm64-v8a  (the arm64 Pie guest)
#   platform-tools (adb), build-tools;28.0.3 (d8), platforms;android-28
#       (android.jar: the javac/d8 bootclasspath for the helper dexes).
set -e
. "$(dirname "$0")/lib/common.sh"
require curl unzip sha256sum

DL="$SDK_ROOT/dl"
mkdir -p "$DL" "$SDK_ROOT"
have() { [ -e "$1" ]; }

# 1. cmdline-tools (sdkmanager host). Latest is fine; it is only the installer.
if ! have "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"; then
  log "== cmdline-tools"
  curl -L --fail -o "$DL/cmdline-tools.zip" \
    https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
  rm -rf "$DL/ct"; unzip -q "$DL/cmdline-tools.zip" -d "$DL/ct"
  mkdir -p "$SDK_ROOT/cmdline-tools/latest"
  mv "$DL/ct/cmdline-tools"/* "$SDK_ROOT/cmdline-tools/latest/"
  rm -rf "$DL/ct" "$DL/cmdline-tools.zip"
fi
SDKM="$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"

# 2. Stable packages via sdkmanager (resolves current revisions + licenses).
if ! have "$IMG/system.img" \
   || ! have "$SDK_ROOT/platform-tools/adb" \
   || ! have "$SDK_ROOT/build-tools/28.0.3/d8" \
   || ! have "$SDK_ROOT/platforms/android-28/android.jar"; then
  log "== sdkmanager: platform-tools build-tools;28.0.3 platforms;android-28 system-image"
  yes | "$SDKM" --sdk_root="$SDK_ROOT" --licenses >/dev/null 2>&1 || true
  yes | "$SDKM" --sdk_root="$SDK_ROOT" \
    "platform-tools" \
    "build-tools;28.0.3" \
    "platforms;android-28" \
    "system-images;android-28;google_apis;arm64-v8a"
fi

# 3. Pinned emulator 37.3.3.
EMUSHA=a0da0fa20903a69ae52ab501f30fc5c768dcce31434cd2f55d52addc1a2c0495
if ! have "$QEMU" || [ "$(cat "$EMU_DIR/.pinned" 2>/dev/null)" != 16489710 ]; then
  log "== emulator 37.3.3 (16489710)"
  curl -L --fail -o "$DL/emu.zip" \
    https://dl.google.com/android/repository/emulator-linux_x64-16489710.zip
  echo "$EMUSHA  $DL/emu.zip" | sha256sum -c -
  rm -rf "$EMU_DIR"
  unzip -q "$DL/emu.zip" -d "$SDK_ROOT"     # zip has a top-level emulator/
  echo 16489710 > "$EMU_DIR/.pinned"
  rm -f "$DL/emu.zip"
fi

log "== 00-setup done. SDK_ROOT=$SDK_ROOT"
for f in "$QEMU" "$IMG/system.img" "$IMG/vendor.img" "$IMG/kernel-ranchu" \
         "$IMG/ramdisk.img" "$SDK_ROOT/platform-tools/adb" "$SDK_ROOT/build-tools/28.0.3/d8"; do
  if have "$f"; then echo "OK      $f"; else echo "MISSING $f"; fi
done
