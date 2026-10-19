# Performance under TCG

This guest runs under pure software emulation (QEMU TCG, `-accel off`). Every
guest instruction is translated and interpreted on the host, so the levers are
different from a KVM-accelerated guest. The findings below are from the pinned
emulator (37.3.3, QEMU 2.12 base) and the API-28 arm64 `ranchu` kernel.

## One vCPU is fastest. Do not raise `-cores`.

Counter-intuitively, `-cores 1` beats 2 and 4 on the **stock** kernel + binary:

- Stock MTTCG is slower at every count: ~1.3–1.8x slower at 2 vCPUs and
  ~2.2–3x slower at 4. A 4-vCPU guest is barely responsive (an `adb shell` can
  take tens of seconds).
- `-accel tcg,thread=single` (round-robin all vCPUs on one host thread) is safe
  but within noise of 1 vCPU, and makes `system_server` ~2x slower at 4 vCPUs.

### Why

The guest's SLUB allocator uses 128-bit `LDXP`/`STXP` for `cmpxchg_double` in
its fast paths (every `kmalloc`/`kfree`). This QEMU build has **no 128-bit host
atomic** (`cmpxchg16b`), so each such op takes the `cpu_loop_exit_atomic`
stop-the-world path: all vCPUs halt for the exclusive section. A secondary cost
is guest inner-shareable `TLBI` instructions, which go through a synced
stop-the-world broadcast. With one vCPU these paths still run but have no other
vCPU to stop, so they are cheap.

A diagnostic patch that skipped the exclusive section let 4 vCPUs reach early
boot ~2x faster — but it breaks atomicity (a lost `cmpxchg_double` on a shared
`struct page` silently corrupts the allocator), and the patched guest wedged
minutes into `system_server`. **Not usable.**

### If you really need SMP

The only safe route is a guest kernel whose allocator does not use
`cmpxchg_double` — build with `CONFIG_SLAB` (SLAB uses none), or keep SLUB but
make `system_has_cmpxchg_double()` return 0 / drop `HAVE_CMPXCHG_DOUBLE`. Run it
on the stock binary via a `KERNEL=` override. To bring secondary vCPUs up at all
under TCG you also need PSCI (the launch script appends
`-qemu -global arm-cpu.psci-conduit=1` automatically when `CORES>1`, because
`ranchu` never sets the conduit itself and the kernel otherwise logs "psci: no
cpu_on method" and leaves secondaries powered off). This kernel-rebuild route is
untested here.

## Guest RAM: keep `-memory` at 4096 MiB

Do **not** raise it. At 6144/8192 MiB ART cannot `mmap` the contiguous region
space its concurrent-copying GC needs under TCG, and `system_server` aborts at
startup (`heap.cc: Check failed: region_space_mem_map != nullptr`), crash-looping
before `systemReady`. For the same reason, do not raise `dalvik.vm.heapsize`
above the 256m default (the `heapsize-cap` boot patch keeps a direct launch from
forcing 576m).

## Cut guest competition, not vCPU count

The real throughput lever under TCG is reducing how many guest threads compete
for the one core. A single-threaded workload with three busy competitors runs
~4x slower than alone. So: keep the ANR-looping and GL-rendering apps quiet and
turn the screen off (`input keyevent 223`) — the bring-up script does the latter
once `systemReady` is reached. The crash-loop HALs are the other big CPU sink;
they are disabled at the image level (10-patch-image) and sleepered at runtime
(40-bringup).

## What does not help

- **Pinning / nice / `chrt`:** vCPU-thread runqueue wait is ~1–5%, too small to
  matter; the bottleneck is inside the translator, not host scheduling.
- **`-tb-size`:** no TB flushes occur in these runs, so it is irrelevant.
- **`slub_debug=F`** on the kernel cmdline (to route around the `cmpxchg_double`
  fast paths): made things far worse. Dropped.
