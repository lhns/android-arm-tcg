# 0005 — Patch framework watchdog/finalizer timeouts

## Status
Accepted.

## Context
Framework timeouts are calibrated for near-hardware speed. Under single-core
TCG, interpreted operations that take milliseconds on real hardware take
seconds-to-minutes, tripping three timers that then kill `system_server` and
restart the world:

- The framework **Watchdog** kills `system_server` when a monitored handler is
  blocked past its timeout (default 60000 ms, and it kills at *half* that).
- The ART **finalizer watchdog** aborts the VM if a single `finalize()` exceeds
  ~10 s.
- The **GNSS provider init** hangs the system_server main looper under TCG (the
  HAL does not answer a capability query in time), freezing `ActivityManager`.

These fire during the normal slow operations of a first boot under TCG, so
`system_server` crash-loops and never holds `systemReady`.

## Decision
Patch the compiled framework (`.oat`/`.odex`) to tolerate TCG timing, per the
generic recipe in [`patches/oat-patches.md`](../../patches/oat-patches.md):
raise the Watchdog `<init>` timeout, raise the finalizer timeout, and neutralise
the GNSS provider (force `GnssLocationProvider.isSupported()` false so the
provider is never created, leaving the HAL running so its `<clinit>` returns
fast). Complement the Watchdog with `WdCtl`, an `IActivityController` that
answers "keep waiting". These offsets are **build-specific**: re-derive them per
image with on-guest `oatdump`; do not hardcode one build's offsets as universal.

## Consequences
- `system_server` survives long interpreted operations and holds `systemReady`.
- The patches are applied to downloaded files (baked into `system.img` or
  bind-mounted at runtime); no patched binary is committed.
- Coupling to a specific image build: a new image needs the offsets re-derived
  (the recipe is written to make that mechanical).
