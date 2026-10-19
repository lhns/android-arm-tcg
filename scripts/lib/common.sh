#!/bin/sh
# common.sh -- shared paths, logging, adb wrapper and the byte-patch helper.
# Sourced by the numbered scripts:  . "$(dirname "$0")/lib/common.sh"
#
# Parameterise the SDK root with SDK_ROOT (default <repo>/sdk). Everything the
# scripts download, extract or build lives under SDK_ROOT or BUILD_DIR; the repo
# itself stays text-only.

# Resolve the repo root from this file's location (works however it is sourced).
_this="${0:-}"
LIB_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/lib" 2>/dev/null && pwd) || LIB_DIR=$(pwd)
REPO_ROOT=$(CDPATH= cd -- "$LIB_DIR/../.." && pwd)

SDK_ROOT=${SDK_ROOT:-$REPO_ROOT/sdk}
BUILD_DIR=${BUILD_DIR:-$REPO_ROOT/build}
IMG=${IMG:-$SDK_ROOT/system-images/android-28/google_apis/arm64-v8a}
EMU_DIR=${EMU_DIR:-$SDK_ROOT/emulator}
QEMU=${QEMU:-$EMU_DIR/qemu/linux-x86_64/qemu-system-aarch64-headless}
ADB_BIN=${ADB_BIN:-$SDK_ROOT/platform-tools/adb}
SERIAL=${SERIAL:-emulator-5554}

BOOT_PATCHES=${BOOT_PATCHES:-$REPO_ROOT/patches/boot-patches.toml}
PATCHER=${PATCHER:-$REPO_ROOT/scripts/lib/patch_bytes.py}
PYTHON=${PYTHON:-python3}

mkdir -p "$BUILD_DIR"

log()  { echo "[$(date +%T)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# adb to our emulator instance.
adbx() { "$ADB_BIN" -s "$SERIAL" "$@"; }
# adb shell, single command, with a generous timeout (the TCG shell is slow).
ash()  { timeout "${ADB_TIMEOUT:-150}" "$ADB_BIN" -s "$SERIAL" shell "$@"; }

# apply_patch <patch-id> <file>
# Applies one boot-patches.toml entry to a file. Exit 0 = patched or already
# patched; 3 = needle absent (caller decides); nonzero else = hard abort.
apply_patch() {
  "$PYTHON" "$PATCHER" "$BOOT_PATCHES" "$1" "$2"
}

# require <cmd...>  -- abort if a tool is missing.
require() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"; done
}
