// transcribe.cpp under the spike's runner contract: runner [--backend metal|cpu]
// [--threads N] --model PATH manifest.jsonl out.jsonl. Links the CTranscribe
// framework the app ships (or a build of the fork with the same API).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "transcribe.h"

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void json_string(FILE * out, const char * s) {
    fputc('"', out);
    for (; *s; ++s) {
        if (*s == '"' || *s == '\\') { fputc('\\', out); fputc(*s, out); }
        else if ((unsigned char) *s < 0x20) fprintf(out, "\\u%04x", *s);
        else fputc(*s, out);
    }
    fputc('"', out);
}

// The value of "key" in one manifest line; the manifest has no escapes in it.
static int field(const char * line, const char * key, char * out, size_t cap) {
    char pattern[64];
    snprintf(pattern, sizeof pattern, "\"%s\": \"", key);
    const char * at = strstr(line, pattern);
    if (!at) { snprintf(pattern, sizeof pattern, "\"%s\":\"", key); at = strstr(line, pattern); }
    if (!at) return 0;
    at += strlen(pattern);
    const char * end = strchr(at, '"');
    size_t n = (size_t) (end - at) < cap - 1 ? (size_t) (end - at) : cap - 1;
    memcpy(out, at, n);
    out[n] = 0;
    return 1;
}

int main(int argc, char ** argv) {
    const char * model = NULL, * manifest = NULL, * output = NULL;
    transcribe_backend_request backend = TRANSCRIBE_BACKEND_METAL;
    int threads = 1;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--model")) model = argv[++i];
        else if (!strcmp(argv[i], "--threads")) threads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--backend")) backend = !strcmp(argv[++i], "cpu") ? TRANSCRIBE_BACKEND_CPU : TRANSCRIBE_BACKEND_METAL;
        else if (!manifest) manifest = argv[i];
        else output = argv[i];
    }
    if (!model || !manifest || !output) { fprintf(stderr, "usage: runner --model M [--backend metal|cpu] [--threads N] manifest out\n"); return 64; }

    double t0 = now();
    struct transcribe_model_load_params lp; transcribe_model_load_params_init(&lp); lp.backend = backend;
    struct transcribe_model * m = NULL;
    if (transcribe_model_load_file(model, &lp, &m) != TRANSCRIBE_OK) return 2;
    struct transcribe_session_params sp; transcribe_session_params_init(&sp); sp.n_threads = threads;
    struct transcribe_session * s = NULL;
    if (transcribe_session_init(m, &sp, &s) != TRANSCRIBE_OK) return 3;
    double load = now() - t0;
    fprintf(stderr, "load_seconds %.3f\n", load);

    FILE * in = fopen(manifest, "r"), * out = fopen(output, "w");
    fprintf(out, "{\"id\": \"__load__\", \"load_seconds\": %.6f, \"runner\": \"transcribe.cpp %s\", \"model\": ", load, transcribe_version());
    json_string(out, model);
    fprintf(out, "}\n");
    char line[8192], id[512], path[4096];
    while (fgets(line, sizeof line, in)) {
        if (!field(line, "id", id, sizeof id) || !field(line, "path", path, sizeof path)) continue;
        FILE * f = fopen(path, "rb");
        fseek(f, 0, SEEK_END); long n = (ftell(f) - 44) / 2; fseek(f, 44, SEEK_SET);
        short * pcm = malloc((size_t) n * 2); fread(pcm, 2, (size_t) n, f); fclose(f);
        float * x = malloc((size_t) n * sizeof(float));
        for (long i = 0; i < n; ++i) x[i] = pcm[i] / 32768.0f;
        struct transcribe_run_params rp; transcribe_run_params_init(&rp); rp.timestamps = TRANSCRIBE_TIMESTAMPS_NONE;
        double start = now();
        int st = transcribe_run(s, x, (int) n, &rp);
        double wall = now() - start;
        fprintf(out, "{\"id\": ");
        json_string(out, id);
        fprintf(out, ", \"text\": ");
        json_string(out, st == TRANSCRIBE_OK ? transcribe_full_text(s) : "");
        fprintf(out, ", \"audio_seconds\": %.3f, \"wall_seconds\": %.6f}\n", n / 16000.0, wall);
        fflush(out);
        free(pcm); free(x);
    }
    fclose(in); fclose(out);
    transcribe_session_free(s); transcribe_model_free(m);
    return 0;
}
