# 0002 — Single vCPU is fastest under TCG

## Status
Accepted.

## Context
Intuition says more vCPUs boot faster. Measured on the stock kernel + emulator
binary, the opposite holds: 2 vCPUs are ~1.3–1.8x slower than 1, and 4 are
~2.2–3x slower, sometimes barely responsive. The cause is the guest SLUB
allocator's 128-bit `LDXP`/`STXP` (`cmpxchg_double`) on every `kmalloc`/`kfree`:
this QEMU build has no 128-bit host atomic (`cmpxchg16b`), so each such op takes
the `cpu_loop_exit_atomic` stop-the-world path that halts all vCPUs. Inner-
shareable `TLBI` broadcasts add a second synced stop-the-world cost. With one
vCPU these paths have no other vCPU to stop and are cheap. (Full data in
[docs/PERF.md](../PERF.md).)

## Decision
Default to `-cores 1`. Default `-memory` to 4096 MiB (higher makes ART fail to
map its GC region space under TCG and `system_server` aborts). Expose `CORES`
and `MEM` as overrides but document them as expert knobs.

## Consequences
- Simplest, fastest, and most stable configuration for reaching `systemReady`.
- No MTTCG data races to reason about; most SMP-only QEMU concerns do not apply.
- True multi-core would require a guest kernel rebuilt without
  `cmpxchg_double` in the allocator (plus PSCI to start secondaries), which is
  out of scope and unverified here.
