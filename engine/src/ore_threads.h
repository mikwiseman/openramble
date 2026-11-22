// ore_threads.h - a small pool for loops over rows or frames.
//
// Work is handed out in chunks from a shared counter, so a thread the system
// has descheduled only holds up the one chunk it took; the others, the caller
// among them, finish the rest. Idle workers sleep on a condition variable
// after a short spin, so a busy machine is not made busier by waiting.
#ifndef ORE_THREADS_H
#define ORE_THREADS_H

#include "ore_base.h"

typedef struct ore_pool ore_pool;

// n_threads counts the calling thread: 1 means no workers. 0 picks a default
// from the number of processors. Returns NULL when out of memory.
ore_pool * ore_pool_new(int n_threads);
void       ore_pool_free(ore_pool * p);
int        ore_pool_threads(const ore_pool * p);

// fn(ctx, begin, end, thread) for chunks of [0, n), each `grain` long (the last
// may be shorter). `thread` is in [0, threads) and identifies the caller for
// per-thread scratch. Returns when every chunk is done. p may be NULL.
typedef void (*ore_range_fn)(void * ctx, int begin, int end, int thread);
void ore_parallel_for(ore_pool * p, int n, int grain, ore_range_fn fn, void * ctx);

// Number of processors the system reports, at least 1.
int ore_cpu_count(void);

#endif  // ORE_THREADS_H
