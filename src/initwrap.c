/* initwrap.c -- first-stage /init wrapper for the software-TCG arm64 boot.
 *
 * Built static for aarch64 and installed as /init in the rebuilt ramdisk; the
 * image's real first-stage init is preserved alongside it as /init.real.
 * initwrap mounts the system-as-root partition, bind-mounts the (patched)
 * /init.real over its /init, performs a CANONICAL switch_root, and execs it.
 *
 * The switch_root is the key boot fix. A naive "MS_MOVE newroot onto / then
 * chroot" leaves forked services (notably the zygote) on a mount namespace
 * whose root is still /newroot: the kernel d_path() then prefixes every one of
 * their fds with "/newroot/..." ("/newroot/dev/null", ".../trace_marker",
 * libraries at "/newroot/system/lib64/..."). Android P's zygote fork runs an
 * exact-string FD whitelist over every open fd, so each "/newroot/..." fd fails
 * the match and the zygote FatalError's and crash-loops -- system_server never
 * starts. (The API-28 whitelist is static; it cannot be relaxed by prop/env.)
 */
#include <unistd.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/wait.h>

static void kmsg(const char *s) {
  int fd = open("/dev/console", O_WRONLY);
  if (fd >= 0) { (void)write(fd, s, strlen(s)); close(fd); }
}

int main(int argc, char **argv, char **envp) {
  char msg[160];
  mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
  mount("sysfs", "/sys", "sysfs", 0, NULL);
  mount("proc", "/proc", "proc", 0, NULL);
  mkdir("/newroot", 0755);

  /* The system-as-root partition is the first partition of the system disk.
     Resolve its dev_t from sysfs and mknod it so we can mount it read-only. */
  int fd = open("/sys/block/vda/vda1/dev", O_RDONLY);
  char buf[32];
  int n = fd >= 0 ? read(fd, buf, sizeof(buf) - 1) : -1;
  if (fd >= 0) close(fd);
  if (n > 0) {
    buf[n] = 0;
    int maj = 0, min = 0;
    sscanf(buf, "%d:%d", &maj, &min);
    mkdir("/dev/block", 0755);
    unlink("/dev/block/vda1");
    mknod("/dev/block/vda1", S_IFBLK | 0600, makedev(maj, min));
  }
  if (mount("/dev/block/vda1", "/newroot", "ext4", MS_RDONLY, NULL) != 0) {
    snprintf(msg, sizeof(msg), "initwrap: vda1 errno %d\n", errno);
    kmsg(msg);
    return 1;
  }
  /* Override the partition's own /init with the patched /init.real that ships
     in this ramdisk (second stage). */
  if (mount("/init.real", "/newroot/init", NULL, MS_BIND, NULL) != 0) {
    snprintf(msg, sizeof(msg), "initwrap: bind errno %d\n", errno);
    kmsg(msg);
    return 2;
  }

  /* Canonical switch_root (AOSP init/switch_root.cpp). Three things matter:
       1. make the whole tree MS_PRIVATE first -- MS_MOVE onto "/" returns
          EINVAL if the source or its parent is a shared mount, and a silent
          failure there is exactly what strands the root at /newroot;
       2. MS_MOVE /dev, /proc, /sys INTO newroot BEFORE moving newroot, so the
          new root is self-contained and every submount is reachable from it;
       3. only then MS_MOVE newroot onto / and chroot. */
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
    snprintf(msg, sizeof(msg), "initwrap: make-rprivate errno %d\n", errno);
    kmsg(msg);
  }
  mount("/dev", "/newroot/dev", NULL, MS_MOVE, NULL);
  mount("/proc", "/newroot/proc", NULL, MS_MOVE, NULL);
  mount("/sys", "/newroot/sys", NULL, MS_MOVE, NULL);
  if (chdir("/newroot") != 0) return 3;
  if (mount(".", "/", NULL, MS_MOVE, NULL) != 0) {
    snprintf(msg, sizeof(msg), "initwrap: move errno %d\n", errno);
    kmsg(msg);
    return 4;
  }
  if (chroot(".") != 0) {
    snprintf(msg, sizeof(msg), "initwrap: chroot errno %d\n", errno);
    kmsg(msg);
    return 5;
  }
  chdir("/");

  /* Drop to permissive before the second stage, so that first-boot policy
     surprises under TCG do not reboot-loop the bring-up. */
  if (fork() == 0) {
    execl("/system/bin/setenforce", "setenforce", "0", (char *)NULL);
    _exit(127);
  }
  wait(NULL);

  argv[0] = "/init";
  execve("/init", argv, envp);
  snprintf(msg, sizeof(msg), "initwrap: exec errno %d\n", errno);
  kmsg(msg);
  return 6;
}
