# 0001 — Software TCG, no KVM

## Status
Accepted.

## Context
The target is an **arm64** Android guest on an **x86_64** host with no
hardware virtualization available (`/dev/kvm` absent). KVM cannot help here
twice over: it is unavailable, and even where present it does not emulate a
foreign ISA, so it cannot run an arm64 guest on an x86_64 CPU. The stock Android
emulator refuses an arm64 guest on an x86_64 host by default.

## Decision
Run the guest under pure software emulation: QEMU TCG with `-accel off`, behind
the emulator's `ANDROID_I_WANT_MY_TCG=yes` escape hatch. Accept that every guest
instruction is translated/interpreted on the host and design the whole toolkit
around that cost.

## Consequences
- Boot is slow (tens of minutes cold) and the guest is CPU-bound on one host
  thread per vCPU; timeouts throughout the tooling are generous.
- Services that assume near-hardware timing misbehave (HAL static-constructor
  crashes, watchdog kills) and need the workarounds in ADRs 0003–0005.
- Correctness, not just speed, is affected under sustained load (ADR 0006).
- Pinning the exact emulator/image build matters, because the boot byte-patches
  are offset/signature-specific.
