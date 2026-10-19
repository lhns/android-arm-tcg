# tcg-probe

A standalone correctness/stability stress probe for an arm64 guest running
under software QEMU TCG. It is independent of the Android bring-up: push the
static binary into any arm64 guest and run it.

It exists because sustained, contended TCG execution of a managed runtime can
intermittently corrupt a single 64-bit pointer's high word to a stale
kernel-range value (`0xffffff8X........`), faulting at a non-canonical address
(see [docs/adr/0006](../../docs/adr/0006-tcg-contention-memory-corruption-limitation.md)).
This probe tries to reproduce that signature in pure C, with no runtime, by
maximising single-vCPU preemption (many threads) and hammering the suspected
codegen: zero-extended `ldr w` loads then 64-bit deref, deep/indirect calls,
`stp`/`ldp` stack traffic, callee-saved register canaries across syscalls, and
strided TLB-thrashing memory canaries.

It detects transient bad loads vs persistent bad memory (via re-read), register
save/restore corruption across exceptions, and recovers from SIGSEGV to keep
counting. In practice this pure-C probe stays **clean** at the host-contention
levels where a full managed runtime crash-loops, which is itself a useful
result: it narrows the trigger to the runtime's own hot paths under contention
rather than a standalone, reproducible codegen bug.

## Build and run

```sh
aarch64-linux-gnu-gcc -O2 -static -pthread -o tcg-probe tools/tcg-probe/tcg-probe.c
adb push tcg-probe /data/local/tmp/
adb shell /data/local/tmp/tcg-probe 1800 64    # seconds, threads
adb shell cat /data/local/tmp/tcg-probe.log
```

A `DONE ... memcorr=0 regcorr=0 valmism=0 segv=0` line means no corruption was
observed in that window.
