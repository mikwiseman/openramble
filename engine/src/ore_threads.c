// ore_threads.c - see ore_threads.h.
#include "ore_threads.h"

#include <stdlib.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef HANDLE             thread_t;
typedef CRITICAL_SECTION   mutex_t;
typedef CONDITION_VARIABLE cond_t;
#define mutex_init(m) InitializeCriticalSection(m)
#define mutex_destroy(m) DeleteCriticalSection(m)
#define mutex_lock(m) EnterCriticalSection(m)
#define mutex_unlock(m) LeaveCriticalSection(m)
#define cond_init(c) InitializeConditionVariable(c)
#define cond_destroy(c) ((void) 0)
#define cond_wait(c, m) SleepConditionVariableCS(c, m, INFINITE)
#define cond_broadcast(c) WakeAllConditionVariable(c)
#else
#include <pthread.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <pthread/qos.h>
#endif
typedef pthread_t       thread_t;
typedef pthread_mutex_t mutex_t;
typedef pthread_cond_t  cond_t;
#define mutex_init(m) pthread_mutex_init(m, NULL)
#define mutex_destroy(m) pthread_mutex_destroy(m)
#define mutex_lock(m) pthread_mutex_lock(m)
#define mutex_unlock(m) pthread_mutex_unlock(m)
#define cond_init(c) pthread_cond_init(c, NULL)
#define cond_destroy(c) pthread_cond_destroy(c)
#define cond_wait(c, m) pthread_cond_wait(c, m)
#define cond_broadcast(c) pthread_cond_broadcast(c)
#endif

#if defined(_MSC_VER)
#include <intrin.h>
typedef volatile long atomic_i32;
ORE_INLINE int a_fetch_add(atomic_i32 * a, int v) { return (int) _InterlockedExchangeAdd(a, v); }
ORE_INLINE int a_load(atomic_i32 * a) { return (int) _InterlockedOr(a, 0); }
ORE_INLINE void a_store(atomic_i32 * a, int v) { _InterlockedExchange(a, v); }
ORE_INLINE int a_fetch_or(atomic_i32 * a, int v) { return (int) _InterlockedOr(a, v); }
ORE_INLINE int a_cas(atomic_i32 * a, int expect, int v) {
    return _InterlockedCompareExchange(a, v, expect) == expect;
}
#else
typedef int atomic_i32;
ORE_INLINE int a_fetch_add(atomic_i32 * a, int v) { return __atomic_fetch_add(a, v, __ATOMIC_SEQ_CST); }
ORE_INLINE int a_load(atomic_i32 * a) { return __atomic_load_n(a, __ATOMIC_SEQ_CST); }
ORE_INLINE void a_store(atomic_i32 * a, int v) { __atomic_store_n(a, v, __ATOMIC_SEQ_CST); }
ORE_INLINE int a_fetch_or(atomic_i32 * a, int v) { return __atomic_fetch_or(a, v, __ATOMIC_SEQ_CST); }
ORE_INLINE int a_cas(atomic_i32 * a, int expect, int v) {
    return __atomic_compare_exchange_n(a, &expect, v, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}
#endif

// How long a thread spins before it sleeps, in microseconds. Jobs inside one
// recognition follow each other within tens of microseconds, and waking a
// sleeping thread costs about as much, so workers stay awake across them. An
// instruction count would not do: the pause instruction takes about 40 ns on
// x86 and almost no time on arm64.
#define ORE_SPIN_US 150.0

#if defined(_WIN32)
static double now_us(void) {
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double) c.QuadPart * 1e6 / (double) f.QuadPart;
}
#else
#include <time.h>
static double now_us(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double) t.tv_sec * 1e6 + (double) t.tv_nsec * 1e-3;
}
#endif

// `state` counts the workers inside the current job; the caller sets CLOSED
// when it has no more chunks to hand out. A worker that wakes after that does
// not join, so the caller never waits for a thread that never started.
#define JOB_CLOSED 0x40000000

ORE_INLINE void cpu_relax(void) {
#if ORE_X86
#if defined(_MSC_VER)
    _mm_pause();
#else
    __builtin_ia32_pause();
#endif
#elif ORE_ARM64 && !defined(_MSC_VER)
    __asm__ __volatile__("yield");
#endif
}

struct ore_pool;
typedef struct {
    struct ore_pool * pool;
    int               index;  // 1..n-1
    thread_t          handle;
} worker_t;

struct ore_pool {
    int        n_threads;
    worker_t * workers;
    mutex_t    mu;
    cond_t     cv_work;  // workers wait here for a new job
    cond_t     cv_done;  // the caller waits here for the workers to finish
    // The current job. `generation` changes once per job.
    atomic_i32   generation;
    atomic_i32   next;   // next unclaimed index
    atomic_i32   state;  // workers inside the job, and JOB_CLOSED
    int          n, grain;
    ore_range_fn fn;
    void *       ctx;
    int          stop;
};

int ore_cpu_count(void) {
#if defined(_WIN32)
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return si.dwNumberOfProcessors > 0 ? (int) si.dwNumberOfProcessors : 1;
#else
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int) n : 1;
#endif
}

static void run_chunks(ore_pool * p, int thread) {
    for (;;) {
        const int begin = a_fetch_add(&p->next, p->grain);
        if (begin >= p->n) break;
        const int end = ORE_MIN(begin + p->grain, p->n);
        p->fn(p->ctx, begin, end, thread);
    }
}

#if defined(_WIN32)
static DWORD WINAPI worker_main(LPVOID arg) {
#else
static void * worker_main(void * arg) {
#endif
    worker_t * w    = (worker_t *) arg;
    ore_pool * p    = w->pool;
    int        seen = 0;
#if defined(__APPLE__)
    // Recognition is something a person is waiting for.
#ifndef ORE_WORKER_QOS
#define ORE_WORKER_QOS QOS_CLASS_USER_INITIATED
#endif
    pthread_set_qos_class_self_np(ORE_WORKER_QOS, 0);
#endif
    for (;;) {
        // Spin briefly for the next job, then sleep.
        int gen = a_load(&p->generation);
        if (gen == seen) {
            const double until = now_us() + ORE_SPIN_US;
            for (int spin = 1; gen == seen; ++spin) {
                cpu_relax();
                gen = a_load(&p->generation);
                if ((spin & 63) == 0 && now_us() > until) break;
            }
        }
        if (gen == seen) {
            mutex_lock(&p->mu);
            while ((gen = a_load(&p->generation)) == seen && !p->stop) cond_wait(&p->cv_work, &p->mu);
            mutex_unlock(&p->mu);
        }
        if (p->stop) break;
        seen = gen;
        int joined = 0;
        for (;;) {
            const int st = a_load(&p->state);
            if (st & JOB_CLOSED) break;
            if (a_cas(&p->state, st, st + 1)) {
                joined = 1;
                break;
            }
        }
        if (!joined) continue;
        run_chunks(p, w->index);
        if (a_fetch_add(&p->state, -1) - 1 == JOB_CLOSED) {
            mutex_lock(&p->mu);
            cond_broadcast(&p->cv_done);
            mutex_unlock(&p->mu);
        }
    }
#if defined(_WIN32)
    return 0;
#else
    return NULL;
#endif
}

ore_pool * ore_pool_new(int n_threads) {
    if (n_threads <= 0) n_threads = ORE_MIN(ore_cpu_count(), 4);
    if (n_threads > 64) n_threads = 64;
    ore_pool * p = (ore_pool *) calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->n_threads = 1;
    mutex_init(&p->mu);
    cond_init(&p->cv_work);
    cond_init(&p->cv_done);
    if (n_threads > 1) {
        p->workers = (worker_t *) calloc((size_t) n_threads - 1, sizeof(worker_t));
        if (!p->workers) {
            ore_pool_free(p);
            return NULL;
        }
        for (int i = 1; i < n_threads; ++i) {
            worker_t * w = &p->workers[i - 1];
            w->pool      = p;
            w->index     = i;
#if defined(_WIN32)
            w->handle = CreateThread(NULL, 0, worker_main, w, 0, NULL);
            if (!w->handle) break;
#else
            if (pthread_create(&w->handle, NULL, worker_main, w) != 0) break;
#endif
            p->n_threads = i + 1;  // only the threads that started count
        }
    }
    return p;
}

void ore_pool_free(ore_pool * p) {
    if (!p) return;
    mutex_lock(&p->mu);
    p->stop = 1;
    a_fetch_add(&p->generation, 1);
    cond_broadcast(&p->cv_work);
    mutex_unlock(&p->mu);
    for (int i = 1; i < p->n_threads; ++i) {
#if defined(_WIN32)
        WaitForSingleObject(p->workers[i - 1].handle, INFINITE);
        CloseHandle(p->workers[i - 1].handle);
#else
        pthread_join(p->workers[i - 1].handle, NULL);
#endif
    }
    mutex_destroy(&p->mu);
    cond_destroy(&p->cv_work);
    cond_destroy(&p->cv_done);
    free(p->workers);
    free(p);
}

int ore_pool_threads(const ore_pool * p) { return p ? p->n_threads : 1; }

void ore_parallel_for(ore_pool * p, int n, int grain, ore_range_fn fn, void * ctx) {
    if (n <= 0) return;
    if (grain < 1) grain = 1;
    if (!p || p->n_threads == 1 || n <= grain) {
        fn(ctx, 0, n, 0);
        return;
    }
    p->n     = n;
    p->grain = grain;
    p->fn    = fn;
    p->ctx   = ctx;
    a_store(&p->next, 0);
    a_store(&p->state, 0);
    mutex_lock(&p->mu);
    a_fetch_add(&p->generation, 1);
    cond_broadcast(&p->cv_work);
    mutex_unlock(&p->mu);

    run_chunks(p, 0);

    // Every chunk is claimed. Close the job and wait only for the workers
    // that are inside it.
    if (a_fetch_or(&p->state, JOB_CLOSED) != 0) {
        const double until = now_us() + ORE_SPIN_US;
        for (int spin = 1; a_load(&p->state) != JOB_CLOSED; ++spin) {
            cpu_relax();
            if ((spin & 63) == 0 && now_us() > until) break;
        }
        if (a_load(&p->state) != JOB_CLOSED) {
            mutex_lock(&p->mu);
            while (a_load(&p->state) != JOB_CLOSED) cond_wait(&p->cv_done, &p->mu);
            mutex_unlock(&p->mu);
        }
    }
}
