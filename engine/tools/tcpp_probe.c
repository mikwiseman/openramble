// tcpp_probe - times transcribe.cpp (the runtime the app ships today) on the
// CPU backend, for comparison with the engine. Not part of the library.
//
//   tcpp_probe time MODEL.gguf CLIP.wav THREADS [REPS] [SECONDS...]
//   tcpp_probe dump MODEL.gguf LIST.txt THREADS      (one WAV path per line)
#include "tools.h"

#include <transcribe.h>

static void quiet(transcribe_log_level l, const char * m, void * u) {
    (void) l;
    (void) m;
    (void) u;
}

int main(int argc, char ** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: tcpp_probe time|dump MODEL WAV|LIST THREADS [REPS] [SECONDS...]\n");
        return 2;
    }
    const int dump    = strcmp(argv[1], "dump") == 0;
    const int threads = atoi(argv[4]);
    transcribe_log_set(quiet, NULL);
    struct transcribe_model_load_params lp;
    transcribe_model_load_params_init(&lp);
    lp.backend                 = TRANSCRIBE_BACKEND_CPU;
    struct transcribe_model * m = NULL;
    double                    t0 = now_ms();
    if (transcribe_model_load_file(argv[2], &lp, &m) != TRANSCRIBE_OK) {
        fprintf(stderr, "load failed\n");
        return 1;
    }
    struct transcribe_session_params sp;
    transcribe_session_params_init(&sp);
    sp.n_threads                 = threads;
    struct transcribe_session * s = NULL;
    if (transcribe_session_init(m, &sp, &s) != TRANSCRIBE_OK) {
        fprintf(stderr, "session failed\n");
        return 1;
    }
    const double load_ms = now_ms() - t0;

    if (dump) {
        FILE * list = fopen(argv[3], "r");
        if (!list) return 1;
        char   path[4096];
        double enc = 0, dec = 0;
        long   total = 0;
        while (fgets(path, sizeof path, list)) {
            path[strcspn(path, "\r\n")] = 0;
            long         n    = 0;
            float *      pcm  = wav_read(path, &n);
            const char * name = strrchr(path, '/');
            name              = name ? name + 1 : path;
            if (!pcm) {
                printf("%s\tUNREADABLE\n", name);
                continue;
            }
            if (n > 16000 * 28) n = 16000 * 28;
            struct transcribe_run_params rp;
            transcribe_run_params_init(&rp);
            rp.task       = TRANSCRIBE_TASK_TRANSCRIBE;
            rp.timestamps = TRANSCRIBE_TIMESTAMPS_TOKEN;
            transcribe_reset_timings(s);
            if (transcribe_run(s, pcm, (int) n, &rp) != TRANSCRIBE_OK) {
                printf("%s\tFAILED\n", name);
                free(pcm);
                continue;
            }
            struct transcribe_timings tm;
            transcribe_timings_init(&tm);
            transcribe_get_timings(s, &tm);
            enc += tm.encode_ms;
            dec += tm.decode_ms;
            total += n;
            printf("%s\t%s\t", name, transcribe_full_text(s));
            const int nt = transcribe_n_tokens(s);
            for (int i = 0; i < nt; ++i) {
                struct transcribe_token t;
                transcribe_token_init(&t);
                transcribe_get_token(s, i, &t);
                printf("%d@%lld ", t.id, (long long) t.t0_ms);
            }
            printf("\t");
            for (int i = 0; i < nt; ++i) {
                struct transcribe_token t;
                transcribe_token_init(&t);
                transcribe_get_token(s, i, &t);
                printf("%.6f ", t.p);
            }
            printf("\n");
            free(pcm);
        }
        fclose(list);
        fprintf(stderr, "audio %.0f s  encode %.0f ms  decode %.0f ms\n", total / 16000.0, enc, dec);
    } else {
        long    n   = 0;
        float * pcm = wav_read(argv[3], &n);
        if (!pcm || n < 16000) {
            fprintf(stderr, "cannot read %s\n", argv[3]);
            return 1;
        }
        const int reps = argc > 5 ? atoi(argv[5]) : 3;
        printf("transcribe.cpp %s, backend %s, threads %d, load %.0f ms\n", transcribe_version(),
               transcribe_model_backend(m), threads, load_ms);
        printf("seconds | wall min | median |  mel | encode | decode | chars\n");
        const double defaults[] = { 2, 4, 8, 16, 30 };
        const int    nl         = argc > 6 ? argc - 6 : 5;
        for (int li = 0; li < nl; ++li) {
            const double secs = argc > 6 ? atof(argv[6 + li]) : defaults[li];
            long         cn   = 0;
            float *      clip = clip_of(pcm, n, secs, &cn);
            double       walls[64];
            float        mel = 0, enc = 0, dec = 0;
            size_t       chars = 0;
            for (int r = 0; r < reps + 1 && r < 64; ++r) {
                struct transcribe_run_params rp;
                transcribe_run_params_init(&rp);
                rp.task       = TRANSCRIBE_TASK_TRANSCRIBE;
                rp.timestamps = TRANSCRIBE_TIMESTAMPS_NONE;
                transcribe_reset_timings(s);
                const double a  = now_ms();
                const int    st = transcribe_run(s, clip, (int) cn, &rp);
                const double b  = now_ms();
                if (st != TRANSCRIBE_OK) {
                    fprintf(stderr, "run failed %d\n", st);
                    return 1;
                }
                if (r >= 1) {
                    walls[r - 1] = b - a;
                    struct transcribe_timings tm;
                    transcribe_timings_init(&tm);
                    transcribe_get_timings(s, &tm);
                    if (r == 1 || b - a <= walls[0]) {
                        mel = tm.mel_ms;
                        enc = tm.encode_ms;
                        dec = tm.decode_ms;
                    }
                    chars = strlen(transcribe_full_text(s));
                }
            }
            qsort(walls, (size_t) reps, sizeof(double), cmp_double);
            printf("%7.1f | %8.1f | %6.1f | %4.1f | %6.1f | %6.1f | %zu\n", secs, walls[0], walls[reps / 2], mel, enc,
                   dec, chars);
            fflush(stdout);
            free(clip);
        }
        free(pcm);
    }
    transcribe_session_free(s);
    transcribe_model_free(m);
    return 0;
}
