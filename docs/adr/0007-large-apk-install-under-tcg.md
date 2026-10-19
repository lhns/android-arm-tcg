# 0007 — Large-APK install under TCG

## Status
Accepted.

## Context
Installing a large (hundreds-of-megabyte) APK into the guest is an optional
layer on top of boot-to-`systemReady`. Two framework behaviours block it under
single-core TCG, and a third property makes completion unreliable:

- `PackageManagerService.scanPackageLI` runs a **second** full APK
  Signature-v2 digest after the installer already verified once — tens of
  minutes of single-threaded interpreted SHA on a large APK.
- `ActivityManagerService.handleProcessStartedLocked` gives a newly started
  helper process (the package-copy / default container service) only ~10 s to
  attach; under TCG it cannot, and the install wedges.
- Even past those, a long cold package scan is where the stochastic
  `0xffffff8X` memory corruption ([ADR 0006](0006-tcg-contention-memory-corruption-limitation.md))
  tends to land, crash-looping `system_server`. A crash-looping boot-scan's PMS
  reconcile pass *deletes* the committed package.

## Decision
Add a thin install layer (`scripts/50-install-apk.sh`,
[docs/INSTALL.md](../INSTALL.md)) plus two build-specific services-oat patches
(Group B in [patches/oat-patches.md](../../patches/oat-patches.md)):

1. **Skip the redundant second v2 verify** (`collectCertificatesLI` →
   `skipVerify=true`). **Security tradeoff:** this disables a signature-
   verification step; it is acceptable only on a throwaway, isolated bring-up
   emulator and such an image must never be carried further.
2. **Extend the process-start timeout** (`handleProcessStartedLocked` forced onto
   the 1,200,000 ms branch for every start).
3. **Accept that completion is stochastic** under host contention. The script
   drives a detached, on-guest, logged install and bakes in guards: probe PMS
   health before installing; abort on a `system_server` crash-loop rather than
   ever crash-looping the boot-scan; and stop at committed-but-unregistered
   instead of restart-looping. Retries are *fresh full boots*, never in-boot
   zygote thrashing.

## Consequences
- A large arm64-only APK can be installed on the x86_64 host with no KVM — the
  point of the whole toolkit — but only on a quiet, un-overcommitted host, and
  not guaranteed on any single run (per ADR 0006).
- The two oat patches must be present before boot; they share the services odex
  with the Group-A patches.
- The signature-verify skip is a real, documented security reduction, scoped to
  the emulator and never beyond it.
- Boot-to-`systemReady` is unaffected and remains reliable; only the install on
  top of it is stochastic.
