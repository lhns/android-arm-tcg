# 0003 — initwrap: canonical switch_root to satisfy the zygote fd-whitelist

## Status
Accepted.

## Context
We boot our own minimal initramfs (`initwrap`) so we can override the image's
first-stage `/init` with a patched copy. initwrap must hand off to the real
init on the system partition via a root switch.

A naive hand-rolled switch (`MS_MOVE newroot onto /` then `chroot`) left forked
services — notably the **zygote** — in a mount namespace whose root was still
`/newroot`. On Android P the zygote runs a static, exact-string **fd whitelist**
over every open fd when it forks `system_server`. With the namespace rooted at
`/newroot`, the kernel's `d_path()` prefixes every fd as `/newroot/dev/null`,
`/newroot/.../trace_marker`, libraries at `/newroot/system/lib64/...`; none match
the whitelist, so the zygote `FatalError`s and crash-loops, and `system_server`
never starts. The API-28 whitelist is not relaxable by prop or env (dynamic
whitelisting is Android 10+). `chroot(".")` alone does not fix it: it changes
`fs->root` but not the mount-namespace root, and `MS_MOVE` onto `/` stacks on
the initramfs rootfs (which cannot be moved), leaving the `/newroot` mount entry
in the namespace.

## Decision
Use the canonical AOSP `switch_root` sequence in `src/initwrap.c`:
1. `mount(NULL, "/", NULL, MS_REC|MS_PRIVATE, NULL)` first — `MS_MOVE` onto `/`
   returns `EINVAL` if the source or its parent is a shared mount, and that
   silent failure is exactly what strands the root at `/newroot`;
2. `MS_MOVE` `/dev`, `/proc`, `/sys` **into** newroot so the new root is
   self-contained and every submount is reachable from it;
3. only then `chdir(newroot)`, `MS_MOVE . onto /`, `chroot(".")`.

Do **not** bind a shell/script over `app_process64` from initwrap: the tmpfs
copy relabels it `tmpfs:s0` and init refuses the zygote domain transition even
under permissive. Any such wrapper belongs over the zygote at runtime, after
root, where it gets the correct label.

## Consequences
- The zygote forks with root `/`; every fd passes the whitelist; no crash loop.
- The root switch is a single self-contained C binary, cross-compiled static;
  the ramdisk is rebuilt around it at run time, never committed.
- Verified empirically: `readlink /proc/<zygote>/root` = `/`, zero fork
  whitelist aborts, `system_server` reaches `systemReady`.
