# oat-patches: framework patches for TCG (generic recipe)

These patch compiled framework code (`.oat`/`.odex`) so an arm64 guest behaves
under single-core TCG, where interpreted work that takes milliseconds on real
hardware takes seconds-to-minutes. They fall into two groups:

- **Group A — reach `systemReady`.** Required for the boot to come up and hold.
- **Group B — install a large APK.** Only needed if you also want to install a
  large (hundreds-of-megabyte) package; see [docs/INSTALL.md](../docs/INSTALL.md).

Unlike the [boot patches](boot-patches.toml), every offset here is
**build-specific** — it lives inside compiled files whose layout changes with
the exact system image. Do **not** treat any single offset/byte sequence below
as universal; re-derive it per build with the on-guest `oatdump`. All of these
go in the **services oat** (except the finalizer one, in `boot-core-libart.oat`)
and must be present **before** boot (bake into `system.img`, or stage in
`build/oat/` for `40-bringup.sh` to bind — binds must precede the zygote start).

---

## Group A — reach `systemReady`

1. **GNSS provider init hang → neutralise.** Under TCG the `gnss@1.0` HAL does
   not answer a geofence capability query in time, which parks `system_server`'s
   **main** looper and freezes `ActivityManager`. Patch
   `GnssLocationProvider.isSupported()` to return `false` so the framework never
   creates the GNSS/geofence provider. Leave the HAL **running** (do not sleeper
   it): the class `<clinit>` still calls `IGnss::getService()`, which returns
   quickly only while the HAL is up; a sleepered/absent HAL makes `<clinit>`
   block forever instead.
2. **Framework Watchdog `<init>` timeout → raise.** The `Watchdog` monitor kills
   `system_server` when a monitored handler is blocked longer than its timeout
   (default 60000 ms, and it kills at *half* that). A multi-minute interpreted
   operation trips it. Raise the timeout well beyond any operation you need to
   survive. Pair with `WdCtl` (`src/wdctl/`); on its own the controller does not
   stop every kill path, and on its own the timeout raise is the reliable lever.
3. **Finalizer watchdog timeout → raise.** ART's finalizer daemon aborts the VM
   if a single `finalize()` runs longer than ~10 s (`10e9` ns). Raise the
   constant (e.g. to 1 h) in `boot-core-libart.oat`.

## Group B — install a large APK

4. **`skipVerify` — drop the redundant second signature verify.**
   `PackageManagerService.collectCertificatesLI` is forced to `skipVerify=true`,
   dropping the **second** APK Signature-v2 digest that `scanPackageLI` would
   otherwise run over the whole APK. On a large APK that second pass is tens of
   minutes of single-threaded interpreted SHA under TCG. Signing details are
   still collected, so PMS does **not** reject the package.

   > **SECURITY:** this disables a signature-verification step. It is acceptable
   > **only** on a throwaway, isolated emulator used for ARM bring-up. Never
   > carry a system image patched this way beyond that emulator, and never treat
   > a package installed with it as signature-verified.

5. **PROC_START timeout → always use the long branch.**
   `ActivityManagerService.handleProcessStartedLocked` picks a process-attach
   timeout with a ternary (`usingWrapper ? 1200000 : 10000` ms). Under TCG a
   helper process (the package-copy / default container service the installer
   binds) cannot attach within the stock 10 s and the install wedges. Force the
   `1200000 ms` branch for **every** start: turn the selecting `cbnz` into an
   unconditional branch, and bump the now-dead `10000` fallback immediate to a
   harmlessly large value (so it is inert).

---

## Finding the offsets per build (on-guest `oatdump`)

The API-28 system image ships `/system/bin/oatdump`. Run it in the guest
against the file you want to patch; for this build the ELF `oatdata` section
starts at file offset `0x1000`, so **file offset = oat `code_offset` + 0x1000**.
Confirm that delta for your build from the oat header before relying on it.
Locate each site by the surrounding **byte signature**, not a hardcoded offset
(a signature-located patch still lands if an unrelated change shifts the code;
use a byte patcher that verifies the before-bytes and aborts on a mismatch).

```sh
# --- Group A ---

# 1. GNSS gate
oatdump --oat-file=/system/framework/oat/arm64/services.odex \
        --class-filter=GnssLocationProvider --method-filter=isSupported
#   Overwrite the 4-instruction native call (adrp/ldr/ldr/blr) with "return 0":
#   movz w0,#0 + 3x nop  ->  00 00 80 52  1f 20 03 d5  1f 20 03 d5  1f 20 03 d5

# 2. Watchdog <init> timeout
oatdump --oat-file=/system/framework/oat/arm64/services.odex \
        --class-filter=Watchdog --method-filter='<init>'
#   The default (0xEA60 = 60000 ms) is loaded by a single movz. A single movz
#   cannot hold a much larger value, so redirect it (b) to a trampoline in a run
#   of zero-padding in the same oat that does movz/movk of the larger timeout
#   into the same register, then branches back after the original movz.

# 3. Finalizer watchdog
oatdump --oat-file=/system/framework/arm64/boot-core-libart.oat \
        --method-filter=finalize
#   10e9 ns is loaded by a movz/movk/movk triple. Replace the three immediates
#   to load a larger value (e.g. 3.6e12 ns = 1 h) into the same register.

# --- Group B ---

# 4. skipVerify
oatdump --oat-file=/system/framework/oat/arm64/services.odex \
        --class-filter=PackageManagerService --method-filter=collectCertificatesLI
#   Find the `mov x2, x21` that forwards skipVerify into the parse and change it
#   to `movz w2, #1`:  e2 03 15 aa  ->  22 00 80 52

# 5. PROC_START timeout
oatdump --oat-file=/system/framework/oat/arm64/services.odex \
        --class-filter=ActivityManagerService --method-filter=handleProcessStartedLocked
#   (a) the `cbnz w23, <short-timeout>` that selects 10000 vs 1200000 becomes an
#       unconditional branch to the long-timeout target:  77 00 00 35  ->  03 00 00 14
#   (b) the now-dead 10000 fallback immediate (movz x3,...) is bumped large:
#       03 e2 84 d2  ->  e3 ff 9f d2   (movz x3,#0xffff)
```

### Example byte sequences (illustrative, build-specific — verify before use)

These are from the pinned build (see `scripts/00-setup.sh`), with a few bytes of
surrounding context so you can locate each site uniquely. They are **not
portable** to another image; re-derive with the steps above.

| id | before (context) | orig → new | after (context) |
|----|------------------|-----------|-----------------|
| GNSS gate | — | native call → `00 00 80 52 1f 20 03 d5 1f 20 03 d5 1f 20 03 d5` | — |
| Finalizer 10s→1h | — | `02 80 9c d2 62 81 aa f2 42 00 c0 f2` → `02 00 94 d2 02 17 a6 f2 c2 68 c0 f2` | — |
| Watchdog `<init>` | — | single `movz 0xEA60` → `b <trampoline>`; trampoline loads larger ms | — |
| skipVerify | `00 18 00 51  e1 03 19 aa` | `e2 03 15 aa` → `22 00 80 52` | `20 1a 00 d0  00 88 45 f9` |
| PROC_START branch | `d4 ba 3a b5  21 d3 40 b9` | `77 00 00 35` → `03 00 00 14` | — |
| PROC_START imm (dead) | — | `03 e2 84 d2` → `e3 ff 9f d2` | `03 00 00 14  03 f0 89 d2` |

## Applying and deploying

ART checks the odex→vdex checksum (the vdex is left untouched), not the reverse,
so a code-byte patch to the odex is accepted. Two ways to deploy a patched file:

- **Bake into `system.img`** (same byte size, so the inode + SELinux xattr are
  preserved): active from the very first boot, before anything can intervene —
  which keeps the *unpatched* `system_server` from crash-looping. Preferred.
- **Push + bind-mount at runtime** from the bring-up script over
  `/system/framework/oat/arm64/services.odex` and
  `/system/framework/arm64/boot-core-libart.oat`. A bind only affects processes
  started *after* it, so bind **before** the zygote (re)start.

If you want the install layer, apply **Group A and Group B together** to the one
services odex before boot (plus the finalizer patch to `boot-core-libart.oat`),
then follow [docs/INSTALL.md](../docs/INSTALL.md). Patched files are build
artifacts and are never committed.
