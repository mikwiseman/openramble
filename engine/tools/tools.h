// tools.h - helpers shared by the command-line tools: a clock and a WAV reader.
#ifndef ORE_TOOLS_H
#define ORE_TOOLS_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static inline double now_ms(void) {
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double) c.QuadPart * 1000.0 / (double) f.QuadPart;
}
#else
#include <time.h>
static inline double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}
#endif

// Reads a 16 kHz PCM WAV (16-bit int or 32-bit float), first channel only.
// Returns malloc'd samples in [-1, 1] and sets *n, or NULL.
static inline float * wav_read(const char * path, long * n) {
    FILE * f = fopen(path, "rb");
    if (!f) return NULL;
    unsigned char h[12];
    if (fread(h, 1, 12, f) != 12 || memcmp(h, "RIFF", 4) != 0 || memcmp(h + 8, "WAVE", 4) != 0) {
        fclose(f);
        return NULL;
    }
    uint32_t sz = 0;
    int      ch = 1, bits = 16, fmt = 1;
    long     rate = 16000;
    for (;;) {
        unsigned char c[8];
        if (fread(c, 1, 8, f) != 8) {
            fclose(f);
            return NULL;
        }
        sz = (uint32_t) c[4] | (uint32_t) c[5] << 8 | (uint32_t) c[6] << 16 | (uint32_t) c[7] << 24;
        if (!memcmp(c, "fmt ", 4)) {
            unsigned char b[40] = { 0 };
            if (fread(b, 1, sz < 40 ? sz : 40, f) < 16) {
                fclose(f);
                return NULL;
            }
            if (sz > 40) fseek(f, (long) sz - 40, SEEK_CUR);
            fmt  = b[0] | b[1] << 8;
            ch   = b[2] | b[3] << 8;
            rate = (long) (b[4] | b[5] << 8 | b[6] << 16 | (uint32_t) b[7] << 24);
            bits = b[14] | b[15] << 8;
            if (fmt == 0xfffe && sz >= 26) fmt = b[24] | b[25] << 8;  // WAVE_FORMAT_EXTENSIBLE
            if (sz & 1) fseek(f, 1, SEEK_CUR);
        } else if (!memcmp(c, "data", 4)) {
            break;
        } else {
            fseek(f, (long) (sz + (sz & 1)), SEEK_CUR);
        }
    }
    if (rate != 16000 || ch < 1 || (bits != 16 && bits != 32)) {
        fclose(f);
        return NULL;
    }
    long    frames = (long) (sz / (uint32_t) (bits / 8) / (uint32_t) ch);
    float * out    = (float *) malloc(sizeof(float) * (size_t) (frames > 0 ? frames : 1));
    void *  raw    = malloc(sz ? sz : 1);
    if (!out || !raw) {
        fclose(f);
        free(out);
        free(raw);
        return NULL;
    }
    size_t got = fread(raw, 1, sz, f);
    fclose(f);
    frames = (long) (got / (size_t) (bits / 8) / (size_t) ch);
    if (bits == 16) {
        const int16_t * r = (const int16_t *) raw;
        for (long i = 0; i < frames; ++i) out[i] = (float) r[i * ch] / 32768.0f;
    } else if (fmt == 3) {
        const float * r = (const float *) raw;
        for (long i = 0; i < frames; ++i) out[i] = r[i * ch];
    } else {
        const int32_t * r = (const int32_t *) raw;
        for (long i = 0; i < frames; ++i) out[i] = (float) r[i * ch] / 2147483648.0f;
    }
    free(raw);
    *n = frames;
    return out;
}

// A clip of `seconds` made by repeating the samples as often as needed.
static inline float * clip_of(const float * pcm, long n, double seconds, long * out_n) {
    long    want = (long) (seconds * 16000.0);
    float * out  = (float *) malloc(sizeof(float) * (size_t) (want > 0 ? want : 1));
    if (!out) return NULL;
    for (long i = 0; i < want; ++i) out[i] = pcm[i % n];
    *out_n = want;
    return out;
}

static inline int cmp_double(const void * a, const void * b) {
    double x = *(const double *) a, y = *(const double *) b;
    return x < y ? -1 : x > y;
}

#endif  // ORE_TOOLS_H
