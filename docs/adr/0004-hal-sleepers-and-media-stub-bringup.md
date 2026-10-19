# 0004 — HAL sleepers + a media-service stub for bring-up

## Status
Accepted.

## Context
Under TCG two classes of service block the path to `systemReady`:

1. **Crash-looping HALs.** Several vendor/system HALs fault in their static
   constructors under TCG (`std::bad_alloc`, SIGSEGV), get relaunched by init,
   and saturate the single vCPU while filling logcat: `statsd`, `storaged`,
   `android.hardware.audio@2.0`, `android.hardware.broadcastradio@1.1`,
   `android.hardware.media.omx@1.0`, `hardware.google.media.c2@1.0`.
2. **Blocking service waits.** Pie's `SystemServer` always starts
   `AudioService`, whose `systemReady()` blocks the system_server main thread on
   `media.audio_policy` / `media.sound_trigger_hw`; `StorageManagerService` then
   stays not-ready. The real media HALs never register (they crashed), so the
   wait never ends.

## Decision
- **Sleepers.** Disable the crash-loopers. Remove the vendor ones at the image
  level (their init `.rc`), and bind a sleeper script over the two system ones
  at runtime. init refuses to exec a `shell_data_file`, so the service stays
  dead instead of looping — the desired outcome.
- **Media stub.** Run a tiny root process that `ServiceManager.addService`s the
  media names with a Binder that answers no-exception + 0. That unblocks the
  waiters; nothing actually calls the media APIs during bring-up. **Do not**
  register SurfaceFlinger (a dummy one makes `DisplayManagerService` time out).
  Register `storaged` too (via `svc.list`): `StorageManagerService.connect()`
  needs both `vold` and `storaged`.
- **Zygote restart ordering.** Restart the zygote only after the stub is up, so
  the fresh `system_server` finds the media names registered and reaches
  `systemReady`.

## Consequences
- The single core is freed from crash-loop churn; the main thread no longer
  wedges on media/storage; `systemReady` is reachable.
- Sleepers and the stub are runtime state, lost on reboot, so bring-up is
  idempotent and re-runnable.
- The stub is a bring-up shim, not a real media implementation; media
  functionality is out of scope (scope is boot to `systemReady`).
