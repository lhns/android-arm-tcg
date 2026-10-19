# 0006 — TCG contention-driven memory corruption is an environmental limit

## Status
Accepted (documents a known limitation, not a fix).

## Context
Under sustained load in the full Android runtime, a single 64-bit pointer's
high word is intermittently replaced by a stale kernel-range value
(`0xffffff8X........`), so a later dereference faults at a non-canonical address.
The signature appears across unrelated processes (ART GC argument visitor,
RenderThread/swiftshader, Binder), always as a whole-64-bit-word replacement
with a structured-but-garbage value, only while the runtime is executing
non-boot-image AOT code with first-time method resolution under host-CPU
contention. It is **intermittent** and **host-load-correlated**, not
deterministic.

What was empirically **excluded** as the cause (each by a confound-controlled
negative, with a standalone aarch64 stress probe — `tools/tcg-probe/` — staying
clean at the same host-load levels where the runtime crash-loops):

- generic preemption and GP-register save/restore across sync and async (IRQ)
  exceptions (register canaries clean across ~1e7 EL0↔EL1 transitions);
- self-modifying code (anon and file-backed/COW, with `__clear_cache`);
- the GC Baker read-barrier + concurrent copying move;
- `fork`/COW and demand-faulted file-backed executable mappings;
- large VMA count / working-set footprint;
- AOT compilation itself; host memory pressure (tens of GB free while
  reproducing); KSM (off); LSE atomics (the emulated CPU is a Cortex-A57,
  ARMv8.0, no LSE — the runtime's CAS uses LL/SC).

A source audit of the emulator's QEMU (a 2.12-era fork, byte-vanilla upstream in
every hot translate/TLB/load-store/interrupt path) found **no** post-2.12
upstream correctness fix, absent from the fork, that matches the symptom with
preconditions satisfied on this single-vCPU, non-icount, aarch64 config.

## Decision
Treat this as an **environmental limitation of contended 2.12-era software TCG**,
not a cherry-pickable bug. There is no QEMU patch to apply and no runtime flag
that avoids it (the corruption is in a runtime AOT stub, not JIT; the GC choice
is baked into the boot image). The governing variable is host-hypervisor CPU
contention (steal). Document it; do not chase a code fix.

## Consequences
- Reaching `systemReady` is reliable; sustained heavy workloads on top of it are
  stochastically unstable and best run on a quiet, un-overcommitted host.
- `tools/tcg-probe/` is kept as a standalone way to check a host/build for the
  signature before relying on it.
- A genuinely better accelerator (real KVM, unavailable here; or a modern-QEMU
  emulator line) is the only categorical fix, and is out of scope.
