# oat-patches: framework timeout / init-hang patches (generic recipe)

These three patches let `system_server` survive the long, slow operations that
are normal under single-core TCG (where interpreted work that takes
milliseconds on hardware takes minutes), so the boot reaches and holds
`systemReady`. Unlike the [boot patches](boot-patches.toml), their byte offsets
are **build-specific** — they live inside compiled `.oat`/`.odex` files whose
layout changes with the exact system image. Do **not** treat any single offset
below as universal; re-derive it per build with the on-guest `oatdump`.

All three target compiled framework code:

1. **GNSS provider init hang → neutralise.** Under TCG the `gnss@1.0` HAL does
   not answer a geofence capability query in time, which parks `system_server`'s
   **main** looper and freezes `ActivityManager`. Patch
   `GnssLocationProvider.isSupported()` (in the services oat) to return `false`
   so the framework never creates the GNSS/geofence provider. Leave the HAL
   **running** (do not sleeper it): the class `<clinit>` still calls
   `IGnss::getService()`, which returns quickly only while the HAL is up; a
   sleepered/absent HAL makes `<clinit>` block forever instead.
2. **Framework Watchdog `<init>` timeout → raise.** The `Watchdog` monitor kills
   `system_server` when a monitored handler is blocked longer than its timeout
   (default 60000 ms, and it kills at *half* that). A multi-minute interpreted
   operation trips it. Raise the timeout well beyond any operation you need to
   survive. Pair with `WdCtl` (an `IActivityController` that answers "keep
   waiting", see `src/wdctl/`); on its own the controller does not stop every
   kill path, and on its own the timeout raise is the reliable lever.
3. **Finalizer watchdog timeout → raise.** ART's finalizer daemon aborts the VM
   if a single `finalize()` runs longer than ~10 s (`10e9` ns). Under TCG a GC
   finalizer can exceed that. Raise the constant (e.g. to 1 h) in the boot image
   oat that carries it (`boot-core-libart.oat`).

## Finding the offsets per build (on-guest `oatdump`)

The API-28 system image ships `/system/bin/oatdump`. Run it in the guest
against the file you want to patch; for this build the ELF `oatdata` section
starts at file offset `0x1000`, so **file offset = oat `code_offset` + 0x1000**.
Confirm that delta for your build from the oat header before relying on it.

```sh
# 1. GNSS gate: find GnssLocationProvider.isSupported()'s native call.
oatdump --oat-file=/system/framework/oat/arm64/services.odex \
        --class-filter=GnssLocationProvider --method-filter=isSupported
#   Read the method's code_offset and the adrp/ldr/ldr/blr that calls the
#   native is-supported helper. Overwrite those 4 instructions (16 bytes) with
#   "return 0": movz w0,#0 + 3x nop  ->  00 00 80 52  1f 20 03 d5  1f 20 03 d5  1f 20 03 d5
#   (execution then falls through the existing epilogue and returns false).

# 2. Watchdog <init> timeout: find where the default timeout is loaded.
oatdump --oat-file=/system/framework/oat/arm64/services.odex \
        --class-filter=Watchdog --method-filter='<init>'
#   The default (60000 ms = 0xEA60) is loaded into a register by a single movz.
#   A single movz cannot hold a much larger value, so redirect it to a short
#   trampoline written into a run of zero-padding bytes in the same oat: the
#   trampoline does movz/movk of the larger timeout (ms) into the same register
#   then branches back to the instruction after the original movz.

# 3. Finalizer watchdog: find the 10e9 ns (10s) constant.
oatdump --oat-file=/system/framework/arm64/boot-core-libart.oat \
        --method-filter=finalize    # or grep the movz/movk sequence for 10e9 ns
#   10e9 ns is loaded by a movz/movk/movk triple into one register. Replace the
#   three immediates to load a larger value (e.g. 3.6e12 ns = 1 h) into the same
#   register. Same length, so the surrounding code is unchanged.
```

### Example immediates (illustrative, build-specific — verify before use)

For the pinned build the sequences were:

- **GNSS gate:** overwrite the 4-instruction native call with
  `00 00 80 52  1f 20 03 d5  1f 20 03 d5  1f 20 03 d5`.
- **Finalizer 10s → 1h:** `02 80 9c d2  62 81 aa f2  42 00 c0 f2`
  (movz/movk/movk of 10e9 ns) → `02 00 94 d2  02 17 a6 f2  c2 68 c0 f2`
  (3.6e12 ns), loading the new value into the same register.
- **Watchdog `<init>` 60s → larger:** replace the single `movz` that loads
  `0xEA60` with a `b` to a trampoline placed in a zeroed slot of the oat; the
  trampoline loads the larger timeout and branches back.

These exact bytes are **not portable** to another system image. Re-derive them
with the steps above. The patched files are build artifacts and are never
committed.

## Applying and deploying

ART checks the odex→vdex checksum (the vdex is left untouched), not the reverse,
so a code-byte patch to the odex is accepted. Two ways to deploy a patched file:

- **Bake into `system.img`** (same byte size, so the inode + SELinux xattr are
  preserved): the patch is then active from the very first boot, before the
  bring-up script runs — which keeps the *unpatched* `system_server` from
  Watchdog-crash-looping before anything can intervene. Preferred when you want
  a hands-off boot.
- **Push + bind-mount at runtime** from the bring-up script, over
  `/system/framework/oat/arm64/services.odex` and
  `/system/framework/arm64/boot-core-libart.oat`. A bind only affects processes
  started *after* it, so bind before the zygote (re)start. Simpler, but the
  first `system_server` may crash-loop until the bind + zygote restart land.

This recipe is scope-limited to reaching and holding `systemReady`. It contains
no app-install or app-verification steps.
