// ore-cli - run the engine from the command line.
//
//   ore-cli run  MODEL.gguf CLIP.wav [THREADS]
//   ore-cli time MODEL.gguf CLIP.wav THREADS [REPS] [SECONDS...]
//   ore-cli dump MODEL.gguf LIST.txt [THREADS]     one WAV path per line; prints
//                                                  name, text, tokens, confidences
//
// Environment, for testing: ORE_KERNELS names a kernel table ("generic");
// ORE_VOCABULARY is a file of words to favour, one per line; ORE_DUMP_DIR
// receives every intermediate tensor of a run as raw little-endian floats.
#include "ore.h"
#include "tools.h"

// Declared by the library for its tools.
ore_session * ore_session_open_kernels(const ore_model * model, int threads, const char * kernels);
typedef void (*ore_dump_fn)(void * user, const char * name, const float * data, int rows, int cols);
void          ore_session_set_dump(ore_session * s, ore_dump_fn fn, void * user);

static void dump_tensor(void * user, const char * name, const float * data, int rows, int cols) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%s.f32", (const char *) user, name);
    FILE * f = fopen(path, "wb");
    if (!f) return;
    fwrite(data, sizeof(float), (size_t) rows * (size_t) cols, f);
    fclose(f);
    snprintf(path, sizeof path, "%s/%s.shape", (const char *) user, name);
    f = fopen(path, "w");
    if (f) {
        fprintf(f, "%d %d\n", rows, cols);
        fclose(f);
    }
}

static int load_vocabulary(ore_session * s, const char * path) {
    FILE * f = fopen(path, "r");
    if (!f) return 0;
    static char   buf[512][128];
    const char *  terms[512];
    int           n = 0;
    while (n < 512 && fgets(buf[n], 128, f)) {
        buf[n][strcspn(buf[n], "\r\n")] = 0;
        if (buf[n][0]) {
            terms[n] = buf[n];
            ++n;
        }
    }
    fclose(f);
    return ore_session_set_vocabulary(s, terms, n) == ORE_OK;
}

int main(int argc, char ** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: ore-cli run|time|dump MODEL.gguf CLIP.wav|LIST.txt [THREADS] [REPS] [SECONDS...]\n");
        return 2;
    }
    const char * mode    = argv[1];
    const int    threads = argc > 4 ? atoi(argv[4]) : 0;
    const char * err     = NULL;
    double       t0      = now_ms();
    ore_model *  m       = ore_model_open(argv[2], &err);
    if (!m) {
        fprintf(stderr, "cannot open the model: %s\n", err);
        return 1;
    }
    const char *  kn = getenv("ORE_KERNELS");
    ore_session * s  = ore_session_open_kernels(m, threads, (kn && *kn) ? kn : NULL);
    if (!s) {
        fprintf(stderr, "cannot open a session\n");
        return 1;
    }
    const double load_ms = now_ms() - t0;
    const char * vocab   = getenv("ORE_VOCABULARY");
    if (vocab && *vocab && !load_vocabulary(s, vocab)) {
        fprintf(stderr, "cannot read %s\n", vocab);
        return 1;
    }
    const char * dd = getenv("ORE_DUMP_DIR");
    if (dd && *dd) ore_session_set_dump(s, dump_tensor, (void *) dd);

    if (strcmp(mode, "dump") == 0) {
        FILE * list = fopen(argv[3], "r");
        if (!list) {
            fprintf(stderr, "cannot read %s\n", argv[3]);
            return 1;
        }
        char   path[4096];
        double enc = 0, dec = 0;
        long   total = 0;
        while (fgets(path, sizeof path, list)) {
            path[strcspn(path, "\r\n")] = 0;
            if (!path[0]) continue;
            long         n    = 0;
            float *      pcm  = wav_read(path, &n);
            const char * name = strrchr(path, '/');
            name              = name ? name + 1 : path;
            if (!pcm) {
                printf("%s\tUNREADABLE\n", name);
                continue;
            }
            if (n > 16000 * 28) n = 16000 * 28;
            if (ore_run(s, pcm, (int) n) != ORE_OK) {
                printf("%s\tFAILED\n", name);
                free(pcm);
                continue;
            }
            ore_timings tm;
            ore_last_timings(s, &tm);
            enc += tm.encode_ms;
            dec += tm.decode_ms;
            total += n;
            printf("%s\t%s\t", name, ore_text(s));
            const int nt = ore_token_count(s);
            for (int i = 0; i < nt; ++i) {
                ore_token t;
                ore_token_at(s, i, &t);
                printf("%d@%lld ", (int) t.id, (long long) t.t0_ms);
            }
            printf("\t");
            for (int i = 0; i < nt; ++i) {
                ore_token t;
                ore_token_at(s, i, &t);
                printf("%.6f ", t.confidence);
            }
            printf("\n");
            free(pcm);
        }
        fclose(list);
        fprintf(stderr, "audio %.0f s  encode %.0f ms  decode %.0f ms\n", total / 16000.0, enc, dec);
    } else {
        long    n   = 0;
        float * pcm = wav_read(argv[3], &n);
        if (!pcm || n < 1600) {
            fprintf(stderr, "cannot read %s\n", argv[3]);
            return 1;
        }
        if (strcmp(mode, "run") == 0) {
            const ore_status st = ore_run(s, pcm, (int) n);
            if (st != ORE_OK) {
                fprintf(stderr, "run failed (%d)\n", (int) st);
                return 1;
            }
            ore_timings tm;
            ore_last_timings(s, &tm);
            printf("%s\n", ore_text(s));
            fprintf(stderr, "%.1f s of audio; load %.0f ms, mel %.1f, encode %.1f, decode %.1f ms; %s, %d threads\n",
                    n / 16000.0, load_ms, tm.mel_ms, tm.encode_ms, tm.decode_ms, ore_session_kernels(s),
                    ore_session_threads(s));
        } else {
            const int reps = argc > 5 ? atoi(argv[5]) : 3;
            printf("ore %s, %s, threads %d, load %.0f ms\n", ore_version(), ore_session_kernels(s), ore_session_threads(s),
                   load_ms);
            printf("seconds | wall min | median |  mel | encode | decode | chars\n");
            const double defaults[] = { 2, 4, 8, 16, 30 };
            const int    nl         = argc > 6 ? argc - 6 : 5;
            for (int li = 0; li < nl; ++li) {
                const double secs = argc > 6 ? atof(argv[6 + li]) : defaults[li];
                long         cn   = 0;
                float *      clip = clip_of(pcm, n, secs, &cn);
                double       walls[64];
                ore_timings  best = { 0, 0, 0 };
                size_t       chars = 0;
                for (int r = 0; r < reps + 1 && r < 64; ++r) {
                    const double a  = now_ms();
                    const int    st = (int) ore_run(s, clip, (int) cn);
                    const double b  = now_ms();
                    if (st != ORE_OK) {
                        fprintf(stderr, "run failed %d\n", st);
                        return 1;
                    }
                    if (r >= 1) {
                        walls[r - 1] = b - a;
                        if (r == 1 || b - a <= walls[0]) ore_last_timings(s, &best);
                        chars = strlen(ore_text(s));
                    }
                }
                qsort(walls, (size_t) reps, sizeof(double), cmp_double);
                printf("%7.1f | %8.1f | %6.1f | %4.1f | %6.1f | %6.1f | %zu\n", secs, walls[0], walls[reps / 2],
                       best.mel_ms, best.encode_ms, best.decode_ms, chars);
                fflush(stdout);
                free(clip);
            }
        }
        free(pcm);
    }
    ore_session_close(s);
    ore_model_close(m);
    return 0;
}
