// Memory pressure for the idle-swap reproduction: allocate GB of incompressible
// pages and keep touching them so they stay active, for at most `seconds`.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
static volatile sig_atomic_t stop = 0;
static void on_signal(int s) { (void)s; stop = 1; }
int main(int argc, char **argv) {
    double gb = argc > 1 ? atof(argv[1]) : 12;
    int seconds = argc > 2 ? atoi(argv[2]) : 600;
    size_t chunk = 256ull << 20, n = (size_t)(gb * 4);
    signal(SIGTERM, on_signal); signal(SIGINT, on_signal);
    uint64_t **chunks = calloc(n, sizeof *chunks), x = 88172645463325252ull;
    time_t start = time(NULL);
    for (size_t i = 0; i < n && !stop; i++) {
        chunks[i] = malloc(chunk);
        if (!chunks[i]) { fprintf(stderr, "alloc failed at %zu\n", i); return 1; }
        for (size_t j = 0; j < chunk / 8; j++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; chunks[i][j] = x; }
    }
    printf("ready %.1f GB in %ld s\n", gb, (long)(time(NULL) - start)); fflush(stdout);
    size_t passes = 0;
    while (!stop && time(NULL) - start < seconds) {
        for (size_t i = 0; i < n && !stop; i++)
            for (size_t j = 0; j < chunk / 8; j += 2048) chunks[i][j] += 1;  // one write per 16 KB page
        passes++;
    }
    printf("done passes=%zu\n", passes); fflush(stdout);
    return 0;
}
