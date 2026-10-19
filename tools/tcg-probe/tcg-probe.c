/* tcg-probe.c -- a standalone TCG correctness/stability stress probe.
 *
 * Static aarch64. Maximizes preemption on a single vCPU (many pthreads) and
 * exercises codegen patterns that a managed runtime hammers: ldr-w pointer
 * loads with zero-extension then 64-bit deref, deep/indirect call chains,
 * stp/ldp stack pointer traffic, callee-saved register canaries held across
 * syscalls, and large strided memory canaries to thrash the softmmu TLB.
 *
 * It looks for a specific failure signature seen on heavily-contended software
 * TCG: a 64-bit pointer whose HIGH word is intermittently replaced by a stale
 * kernel-range value (0xffffff8X........), causing a fault at a non-canonical
 * address. The probe detects both transient bad LOADS and persistent bad
 * memory, and recovers from SIGSEGV so it can keep counting.
 *
 * Signals logged to /data/local/tmp/tcg-probe.log (one line per event):
 *   MEMCORR  exp got rr tid it addr  (64-bit canary high word wrong)
 *   REGCORR  which got tid            (callee-saved reg wrong after syscall)
 *   VALMISM  exp got tid              (deref returned wrong value)
 *   SEGV     fa pc tid x10 x24        (SIGSEGV, recovered via siglongjmp)
 * A MEMCORR whose 'rr' (re-read) is correct => a transient bad LOAD; otherwise
 * memory was written bad. STAT lines summarise ops/s and per-class counters.
 *
 * usage: tcg-probe [seconds] [nthreads]   (defaults: 1800, 64)
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <signal.h>
#include <setjmp.h>
#include <ucontext.h>
#include <fcntl.h>
#include <time.h>
#include <sys/mman.h>
#include <errno.h>

static int   g_run = 1;
static int   g_logfd = 2;
static uint64_t g_ops = 0;          /* total verify/deref ops, atomic */
static uint64_t g_memcorr = 0;
static uint64_t g_regcorr = 0;
static uint64_t g_valmism = 0;
static uint64_t g_segv = 0;
static uint64_t g_ffff = 0;         /* events whose bad value matched 0xffffff8X */

#define A_ADD(p,v) __atomic_add_fetch((p),(v),__ATOMIC_RELAXED)
#define SENTINEL_HI 0x00000000u     /* valid user-range high half */

/* ---- async-signal-safe hex line writer ---- */
static void put_hex(char **p, uint64_t v) {
    static const char hx[] = "0123456789abcdef";
    *(*p)++ = '0'; *(*p)++ = 'x';
    int started = 0;
    for (int s = 60; s >= 0; s -= 4) {
        int d = (v >> s) & 0xf;
        if (d || started || s == 0) { *(*p)++ = hx[d]; started = 1; }
    }
}
static void put_str(char **p, const char *s){ while(*s) *(*p)++ = *s++; }
static void put_u(char **p, uint64_t v){
    char t[24]; int n=0; if(!v){*(*p)++='0';return;}
    while(v){t[n++]='0'+(v%10);v/=10;} while(n) *(*p)++=t[--n];
}
static int is_kern(uint64_t v){ return (v >> 36) == 0xffffff8ull; } /* 0xffffff8X........ */

/* ---- SIGSEGV recovery: thread-local jump buffer ---- */
static __thread sigjmp_buf tls_jb;
static __thread int        tls_armed = 0;
static __thread uint64_t   tls_iter = 0;
static __thread int        tls_tid  = 0;

static void segv_handler(int sig, siginfo_t *si, void *uc_) {
    (void)sig;
    ucontext_t *uc = (ucontext_t*)uc_;
    uint64_t pc = 0, x10 = 0, x24 = 0;
#if defined(__aarch64__)
    pc  = uc->uc_mcontext.pc;
    x10 = uc->uc_mcontext.regs[10];
    x24 = uc->uc_mcontext.regs[24];
#endif
    uint64_t fa = (uint64_t)si->si_addr;
    A_ADD(&g_segv, 1);
    if (is_kern(fa) || is_kern(x10) || is_kern(x24)) A_ADD(&g_ffff, 1);
    char buf[256], *p = buf;
    put_str(&p, "SEGV fa="); put_hex(&p, fa);
    put_str(&p, " pc=");     put_hex(&p, pc);
    put_str(&p, " tid=");    put_u(&p, tls_tid);
    put_str(&p, " it=");     put_u(&p, tls_iter);
    put_str(&p, " x10=");    put_hex(&p, x10);
    put_str(&p, " x24=");    put_hex(&p, x24);
    *p++ = '\n';
    (void)!write(g_logfd, buf, p - buf);
    if (tls_armed) siglongjmp(tls_jb, 1);
    _exit(42); /* fault outside an armed region: should not happen */
}

static void logline(const char *kind, uint64_t a, uint64_t b, uint64_t c,
                    int tid, uint64_t it, uint64_t addr) {
    char buf[256], *p = buf;
    put_str(&p, kind); *p++=' ';
    put_str(&p,"exp="); put_hex(&p,a);
    put_str(&p," got="); put_hex(&p,b);
    put_str(&p," rr=");  put_hex(&p,c);
    put_str(&p," tid="); put_u(&p,tid);
    put_str(&p," it=");  put_u(&p,it);
    put_str(&p," addr=");put_hex(&p,addr);
    *p++='\n';
    (void)!write(g_logfd, buf, p-buf);
}

/* ---- indirect-call / deep-chain work ---- */
static uint64_t f0(uint64_t x){ return x ^ (x<<1); }
static uint64_t f1(uint64_t x){ return x + 0x9e3779b97f4a7c15ull; }
static uint64_t f2(uint64_t x){ return (x>>7) | (x<<57); }
static uint64_t f3(uint64_t x){ return x * 2654435761u; }
typedef uint64_t (*fn_t)(uint64_t);
static fn_t g_fns[4] = { f0, f1, f2, f3 };
static uint64_t deep(uint64_t x, int d){
    if (d<=0) return x;
    fn_t f = g_fns[(x ^ d) & 3];
    /* stp/ldp of pointers to/from stack */
    void *slots[4] = { (void*)f, (void*)&g_fns, (void*)x, (void*)(uintptr_t)d };
    asm volatile("" :: "r"(slots) : "memory");
    x = f(x);
    return deep(x, d-1) ^ (uint64_t)(uintptr_t)slots[(x)&3];
}

/* ---- memory-canary thread (also runs ldr-w deref as WORK) ---- */
#define ARR_WORDS (262144)          /* 2 MiB per thread */
typedef struct { int tid; } targ_t;

static void *mem_thread(void *a) {
    targ_t *t = (targ_t*)a;
    tls_tid = t->tid;
    uint64_t *arr = (uint64_t*)malloc(ARR_WORDS * sizeof(uint64_t));
    uint32_t *refs = (uint32_t*)malloc(ARR_WORDS * sizeof(uint32_t));
    if (!arr || !refs) { return NULL; }
    for (uint32_t i=0;i<ARR_WORDS;i++) refs[i] = (uint32_t)((i*8u) % (ARR_WORDS*8u));
    uint64_t base = (uint64_t)(uintptr_t)arr;
    uint64_t iter = 0;
    while (__atomic_load_n(&g_run,__ATOMIC_RELAXED)) {
        tls_iter = iter;
        if (sigsetjmp(tls_jb,1)) { tls_armed=0; iter++; continue; }
        tls_armed = 1;
        /* write canaries: high=sentinel, low=derived counter */
        for (uint32_t i=0;i<ARR_WORDS;i++)
            arr[i] = ((uint64_t)SENTINEL_HI<<32) | (uint32_t)(t->tid*2654435761u + i + iter);
        asm volatile("" ::: "memory");
        /* WORK between write and read -------------------------------- */
        uint64_t acc = iter;
        /* (a) runtime-style: ldr w offset, zero-extend, add base, ldr x */
        for (uint32_t i=0;i<4096;i++){
            uint32_t idx = (uint32_t)((acc*1103515245u+12345u) & (ARR_WORDS-1));
            uint64_t off = refs[idx];           /* a 32-bit value */
            uint64_t v;
            asm volatile(
                "ldr w9, [%1, %2, lsl #2]\n"    /* w9 = refs[idx] (ldr w, zero-ext) */
                "add x9, %3, x9\n"              /* x9 = base + (uint64)off */
                "ldr %0, [x9]\n"                /* deref as 64-bit */
                : "=r"(v) : "r"(refs), "r"((uint64_t)idx), "r"(base)
                : "x9","memory");
            acc += v;
        }
        /* (b) deep call chains / indirect calls */
        acc ^= deep(acc, 24);
        /* (c) tight arithmetic */
        for (int k=0;k<2000;k++) acc = acc*6364136223846793005ull + 1442695040888963407ull;
        asm volatile("" :: "r"(acc) : "memory");
        /* read canaries back, strided (TLB thrash), verify high==sentinel */
        uint32_t idx = (uint32_t)(iter & (ARR_WORDS-1));
        for (uint32_t n=0;n<ARR_WORDS;n++){
            uint64_t w = arr[idx];
            if ((uint32_t)(w>>32) != SENTINEL_HI) {
                asm volatile("" ::: "memory");
                uint64_t rr = arr[idx];          /* re-read: transient vs persistent */
                A_ADD(&g_memcorr,1);
                if (is_kern(w)) A_ADD(&g_ffff,1);
                logline("MEMCORR", ((uint64_t)SENTINEL_HI<<32), w, rr,
                        t->tid, iter, (uint64_t)(uintptr_t)&arr[idx]);
            }
            idx = (uint32_t)((idx*1103515245u+12345u) & (ARR_WORDS-1));
        }
        A_ADD(&g_ops, ARR_WORDS + 4096);
        iter++;
    }
    tls_armed=0;
    return NULL;
}

/* ---- pointer worker: mmap low region, hammer ref->ptr deref ---- */
#define RGN (16u*1024*1024)
static void *ptr_thread(void *a) {
    targ_t *t = (targ_t*)a;
    tls_tid = t->tid;
    void *rgn = mmap(NULL, RGN, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (rgn == MAP_FAILED) return NULL;
    uint64_t base = (uint64_t)(uintptr_t)rgn;
    uint32_t nref = RGN/64;
    uint32_t *refs = (uint32_t*)malloc(nref*sizeof(uint32_t));
    for (uint32_t i=0;i<nref;i++){
        uint32_t off = (i*64u) % (RGN-8u);
        refs[i] = off & ~7u;
        *(uint64_t*)((char*)rgn + refs[i]) = base + refs[i];   /* marker = its own addr */
    }
    uint64_t iter=0;
    while (__atomic_load_n(&g_run,__ATOMIC_RELAXED)) {
        tls_iter = iter;
        if (sigsetjmp(tls_jb,1)) { tls_armed=0; iter++; continue; }
        tls_armed = 1;
        for (uint32_t i=0;i<nref;i++){
            uint64_t v;
            asm volatile(
                "ldr w9, [%1, %2, lsl #2]\n"   /* w9 = refs[i], zero-extended */
                "add x9, %3, x9\n"             /* base + off */
                "ldr %0, [x9]\n"               /* deref (would fault at 0xffffff8X if hi corrupt) */
                : "=r"(v) : "r"(refs), "r"((uint64_t)i), "r"(base)
                : "x9","memory");
            uint64_t expect = base + refs[i];
            if (v != expect) {
                A_ADD(&g_valmism,1);
                if (is_kern(v)) A_ADD(&g_ffff,1);
                logline("VALMISM", expect, v, 0, t->tid, iter, base+refs[i]);
            }
        }
        A_ADD(&g_ops, nref);
        iter++;
    }
    tls_armed=0;
    return NULL;
}

/* ---- register-canary + syscall-storm thread ----
 * Holds sentinels in x19..x28 across getpid() syscalls; verifies none changed.
 * Tests the kernel/TCG exception-entry save/restore path. */
static void *reg_thread(void *a) {
    targ_t *t = (targ_t*)a;
    tls_tid = t->tid;
    uint64_t base = 0x4141414100000000ull | ((uint64_t)(uint32_t)t->tid);
    uint64_t iter=0;
    while (__atomic_load_n(&g_run,__ATOMIC_RELAXED)) {
        uint64_t bad_idx = 0xff, bad_val = 0;
        uint64_t itc = 100000;
        /* Tight asm loop: load sentinels into x19..x28, loop {svc getpid; check}.
         * x0 is CLOBBERED (getpid returns pid in x0) -- must be in the clobber list
         * so GCC does not park %2/%3 in x0. On mismatch capture the failing reg's
         * actual value so a 0xffffff8X corruption is visible. */
        asm volatile(
            "mov x19, %2\n add x20, %2, #1\n add x21, %2, #2\n add x22, %2, #3\n"
            "add x23, %2, #4\n add x24, %2, #5\n add x25, %2, #6\n add x26, %2, #7\n"
            "add x27, %2, #8\n add x28, %2, #9\n"
            "mov x11, %3\n"                   /* inner iterations */
            "1:\n"
            "mov x8, #172\n svc #0\n"         /* getpid: kernel must preserve x19..x28 */
            "cmp x19, %2\n b.ne 90f\n"
            "sub x9, x20, %2\n cmp x9, #1\n b.ne 91f\n"
            "sub x9, x21, %2\n cmp x9, #2\n b.ne 92f\n"
            "sub x9, x22, %2\n cmp x9, #3\n b.ne 93f\n"
            "sub x9, x23, %2\n cmp x9, #4\n b.ne 94f\n"
            "sub x9, x24, %2\n cmp x9, #5\n b.ne 95f\n"
            "sub x9, x25, %2\n cmp x9, #6\n b.ne 96f\n"
            "sub x9, x26, %2\n cmp x9, #7\n b.ne 97f\n"
            "sub x9, x27, %2\n cmp x9, #8\n b.ne 98f\n"
            "sub x9, x28, %2\n cmp x9, #9\n b.ne 99f\n"
            "subs x11, x11, #1\n b.ne 1b\n"
            "mov %0, #0xff\n mov %1, xzr\n b 3f\n"   /* ok */
            "90:\n mov %0,#19\n mov %1,x19\n b 3f\n"
            "91:\n mov %0,#20\n mov %1,x20\n b 3f\n"
            "92:\n mov %0,#21\n mov %1,x21\n b 3f\n"
            "93:\n mov %0,#22\n mov %1,x22\n b 3f\n"
            "94:\n mov %0,#23\n mov %1,x23\n b 3f\n"
            "95:\n mov %0,#24\n mov %1,x24\n b 3f\n"
            "96:\n mov %0,#25\n mov %1,x25\n b 3f\n"
            "97:\n mov %0,#26\n mov %1,x26\n b 3f\n"
            "98:\n mov %0,#27\n mov %1,x27\n b 3f\n"
            "99:\n mov %0,#28\n mov %1,x28\n"
            "3:\n"
            : "=&r"(bad_idx), "=&r"(bad_val)
            : "r"(base), "r"(itc)
            : "x0","x8","x9","x11","x19","x20","x21","x22","x23","x24","x25","x26","x27","x28","memory","cc");
        if (bad_idx != 0xff) {
            A_ADD(&g_regcorr,1);
            if (is_kern(bad_val)) A_ADD(&g_ffff,1);
            logline("REGCORR", base + (bad_idx-19), bad_val, 0, t->tid, iter, bad_idx);
        }
        A_ADD(&g_ops, 100000);
        iter++;
    }
    return NULL;
}

int main(int argc, char **argv) {
    int secs = (argc>1)? atoi(argv[1]) : 1800;
    int nthr = (argc>2)? atoi(argv[2]) : 64;
    if (nthr < 8) nthr = 8;

    g_logfd = open("/data/local/tmp/tcg-probe.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (g_logfd < 0) g_logfd = 2;

    struct sigaction sa; memset(&sa,0,sizeof sa);
    sa.sa_sigaction = segv_handler; sa.sa_flags = SA_SIGINFO|SA_NODEFER;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);

    /* thread mix: ~75% mem, few reg, few ptr */
    int n_reg = 4, n_ptr = 4;
    if (nthr < 16) { n_reg = 2; n_ptr = 2; }
    int n_mem = nthr - n_reg - n_ptr;

    pthread_t *th = calloc(nthr, sizeof(pthread_t));
    targ_t    *ta = calloc(nthr, sizeof(targ_t));
    int idx=0;
    for (int i=0;i<n_mem;i++){ ta[idx].tid=idx; pthread_create(&th[idx],NULL,mem_thread,&ta[idx]); idx++; }
    for (int i=0;i<n_reg;i++){ ta[idx].tid=idx; pthread_create(&th[idx],NULL,reg_thread,&ta[idx]); idx++; }
    for (int i=0;i<n_ptr;i++){ ta[idx].tid=idx; pthread_create(&th[idx],NULL,ptr_thread,&ta[idx]); idx++; }

    char hdr[128]; int hn = snprintf(hdr,sizeof hdr,
        "START secs=%d nthr=%d mem=%d reg=%d ptr=%d pid=%d\n",
        secs,nthr,n_mem,n_reg,n_ptr,(int)getpid());
    (void)!write(g_logfd,hdr,hn);

    time_t t0 = time(NULL), last = t0; uint64_t last_ops = 0;
    while (time(NULL) - t0 < secs) {
        struct timespec ts = {5,0}; nanosleep(&ts,NULL);
        time_t now = time(NULL);
        if (now - last >= 30) {
            uint64_t ops = __atomic_load_n(&g_ops,__ATOMIC_RELAXED);
            double dt = (double)(now-last);
            char ln[320]; int n = snprintf(ln,sizeof ln,
                "STAT t=%lds ops=%llu dops/s=%.0f memcorr=%llu regcorr=%llu valmism=%llu segv=%llu kern0xffffff8=%llu\n",
                (long)(now-t0),(unsigned long long)ops,(ops-last_ops)/dt,
                (unsigned long long)__atomic_load_n(&g_memcorr,0),
                (unsigned long long)__atomic_load_n(&g_regcorr,0),
                (unsigned long long)__atomic_load_n(&g_valmism,0),
                (unsigned long long)__atomic_load_n(&g_segv,0),
                (unsigned long long)__atomic_load_n(&g_ffff,0));
            (void)!write(g_logfd,ln,n);
            (void)!write(1,ln,n);
            last = now; last_ops = ops;
        }
    }
    __atomic_store_n(&g_run,0,__ATOMIC_RELAXED);
    for (int i=0;i<nthr;i++) pthread_join(th[i],NULL);

    uint64_t ops = __atomic_load_n(&g_ops,0);
    char ln[320]; int n = snprintf(ln,sizeof ln,
        "DONE ops=%llu memcorr=%llu regcorr=%llu valmism=%llu segv=%llu kern0xffffff8=%llu\n",
        (unsigned long long)ops,
        (unsigned long long)__atomic_load_n(&g_memcorr,0),
        (unsigned long long)__atomic_load_n(&g_regcorr,0),
        (unsigned long long)__atomic_load_n(&g_valmism,0),
        (unsigned long long)__atomic_load_n(&g_segv,0),
        (unsigned long long)__atomic_load_n(&g_ffff,0));
    (void)!write(g_logfd,ln,n); (void)!write(1,ln,n);
    return 0;
}
