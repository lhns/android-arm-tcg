# Architecture Decision Records

Short records of the hard-to-reverse decisions behind this toolkit. Each is
Status / Context / Decision / Consequences. All are scoped to booting an arm64
Android guest to `systemReady` under software QEMU TCG.

- [0001](0001-software-tcg-no-kvm.md) — Software TCG, no KVM
- [0002](0002-single-vcpu-fastest-under-tcg.md) — Single vCPU is fastest under TCG
- [0003](0003-initwrap-switch-root-fd-whitelist.md) — initwrap: canonical switch_root to satisfy the zygote fd-whitelist
- [0004](0004-hal-sleepers-and-media-stub-bringup.md) — HAL sleepers + a media-service stub for bring-up
- [0005](0005-watchdog-finalizer-timeout-patching.md) — Patch framework watchdog/finalizer timeouts
- [0006](0006-tcg-contention-memory-corruption-limitation.md) — TCG contention-driven memory corruption is an environmental limit
- [0007](0007-large-apk-install-under-tcg.md) — Large-APK install under TCG (optional layer)
