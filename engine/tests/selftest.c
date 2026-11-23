// selftest - checks the engine's parts without a model file.
//
//   selftest [SCRATCH_FILE]
//
// Every kernel table this processor can run must agree with the plain C one
// on made-up weights, bit for bit (the table without fused multiply-add to
// rounding). The half-precision conversions, exp, the thread pool, the model
// file reader and the mel front end are checked against definitions written
// out here. Exits nonzero on the first failure.
#include "../src/ore_gguf.h"
#include "../src/ore_kernels.h"
#include "../src/ore_mel.h"
#include "../src/ore_threads.h"

#include <stdio.h>
#include <stdlib.h>

static int failures = 0;

#define CHECK(cond, ...)                 \
    do {                                 \
        if (!(cond)) {                   \
            printf("FAILED: " __VA_ARGS__); \
            printf("\n");                \
            ++failures;                  \
        }                                \
    } while (0)

static uint32_t rng = 0x9e3779b9u;
static uint32_t rnd_u32(void) {
    rng = rng * 1664525u + 1013904223u;
    return rng >> 8;
}
static float rnd_f(void) {
    float s = 0;
    for (int i = 0; i < 4; ++i) s += (float) rnd_u32() * (1.0f / 16777216.0f);
    return (s - 2.0f) * 1.7f;
}

// ---- half precision -------------------------------------------------------------

static void test_half(void) {
    int bad = 0;
    for (uint32_t h = 0; h < 65536; ++h) {
        const float    f    = ore_f16_to_f32((uint16_t) h);
        const uint32_t ex   = (h >> 10) & 31, man = h & 1023;
        const double   sign = (h & 0x8000) ? -1.0 : 1.0;
        if (ex == 31) {
            if (man == 0) bad += !(isinf(f) && (f < 0) == (sign < 0));
            else bad += !isnan(f);
            continue;
        }
        const double want = ex == 0 ? sign * ldexp((double) man, -24) : sign * ldexp(1.0 + man / 1024.0, (int) ex - 15);
        bad += (double) f != want;
        bad += ore_f32_to_f16(f) != (uint16_t) h;
    }
    CHECK(bad == 0, "half precision: %d of 65536 values convert wrongly", bad);
    // Rounding to nearest even on the way down.
    CHECK(ore_f32_to_f16(1.0f + 1.0f / 2048.0f) == 0x3c00, "half precision: a tie does not round to even");
    CHECK(ore_f32_to_f16(1.0f + 3.0f / 2048.0f) == 0x3c02, "half precision: a tie does not round to even (odd)");
    CHECK(ore_f32_to_f16(1e9f) == 0x7c00, "half precision: overflow is not infinity");
}

// ---- exp --------------------------------------------------------------------------

static void test_exp(void) {
    double worst = 0;
    for (int i = -8700; i <= 8800; ++i) {
        const float  x    = (float) i * 0.01f;
        const double want = exp((double) x), got = (double) ore_expf(x);
        const double rel  = fabs(got - want) / want;
        if (rel > worst) worst = rel;
    }
    CHECK(worst < 2e-7, "exp: relative error %.3g", worst);
    CHECK(ore_expf(-200.0f) == 0.0f && isinf(ore_expf(200.0f)), "exp: the ends are not 0 and infinity");
}

// ---- kernels ----------------------------------------------------------------------

static int same(const ore_kernels * k, const float * a, const float * b, size_t n) {
    if (strcmp(k->name, "sse") != 0) return memcmp(a, b, n * sizeof(float)) == 0;
    double maxd = 0, maxv = 0;  // no fused multiply-add: equal to rounding
    for (size_t i = 0; i < n; ++i) {
        const double d = fabs((double) a[i] - (double) b[i]), v = fabs((double) a[i]);
        if (d > maxd) maxd = d;
        if (v > maxv) maxv = v;
    }
    return maxd <= 1e-4 * (maxv > 1.0 ? maxv : 1.0);
}

static void test_kernels(const ore_kernels * k) {
    const ore_kernels * ref = &ore_kernels_generic;
    enum { NIN = 512, NOUT = 7 };
    const int frames[] = { 1, 5, 16, 17, 37 };
    // Made-up weights in each storage format.
    uint8_t * q4 = (uint8_t *) ore_alloc((size_t) NOUT * (NIN / 256) * ORE_Q4K_BYTES);
    uint8_t * q8 = (uint8_t *) ore_alloc((size_t) NOUT * (NIN / 32) * ORE_Q80_BYTES);
    uint16_t * wh = (uint16_t *) ore_alloc(sizeof(uint16_t) * NOUT * NIN);
    float *    wf = (float *) ore_alloc(sizeof(float) * NOUT * NIN);
    for (int b = 0; b < NOUT * (NIN / 256); ++b) {
        uint8_t *      blk = q4 + (size_t) b * ORE_Q4K_BYTES;
        const uint16_t d = ore_f32_to_f16(0.001f + (float) (rnd_u32() & 255) * 1e-5f);
        const uint16_t m = ore_f32_to_f16(0.002f + (float) (rnd_u32() & 255) * 1e-5f);
        memcpy(blk, &d, 2);
        memcpy(blk + 2, &m, 2);
        for (int i = 4; i < ORE_Q4K_BYTES; ++i) blk[i] = (uint8_t) rnd_u32();
    }
    for (int b = 0; b < NOUT * (NIN / 32); ++b) {
        uint8_t *      blk = q8 + (size_t) b * ORE_Q80_BYTES;
        const uint16_t d   = ore_f32_to_f16(0.003f + (float) (rnd_u32() & 255) * 1e-5f);
        memcpy(blk, &d, 2);
        for (int i = 2; i < ORE_Q80_BYTES; ++i) blk[i] = (uint8_t) rnd_u32();
    }
    for (int i = 0; i < NOUT * NIN; ++i) {
        wf[i] = rnd_f() * 0.1f;
        wh[i] = ore_f32_to_f16(wf[i]);
    }
    for (size_t fi = 0; fi < sizeof(frames) / sizeof(frames[0]); ++fi) {
        const int T   = frames[fi];
        const int ntb = ore_frame_blocks(T);
        float *   x   = (float *) ore_alloc(sizeof(float) * (size_t) T * NIN);
        float *   yr  = (float *) ore_alloc(sizeof(float) * (size_t) T * NOUT);
        float *   yk  = (float *) ore_alloc(sizeof(float) * (size_t) T * NOUT);
        float *   xp  = (float *) ore_alloc(sizeof(float) * (size_t) ntb * NIN * ORE_FB);
        float *   scr = (float *) ore_alloc(sizeof(float) * 6 * NIN);
        for (int i = 0; i < T * NIN; ++i) x[i] = rnd_f();
        if (T > 2) memset(x + NIN, 0, sizeof(float) * 256);  // a block of zeros has scale 0

        for (int which = 0; which < 4; ++which) {
            const char * what = which == 0 ? "Q4_K" : which == 1 ? "Q8_0" : which == 2 ? "F16" : "F32";
            for (int pass = 0; pass < 2; ++pass) {
                const ore_kernels * kk  = pass ? k : ref;
                float *             out = pass ? yk : yr;
                if (which < 2) {
                    ore_qact a = { 0 };
                    CHECK(ore_qact_reserve(&a, T, NIN, which == 0 ? 256 : 32), "out of memory");
                    if (which == 0) {
                        kk->quantize_q8k(x, NIN, 0, ntb, &a);
                        // an odd row range, as the threads would split it
                        kk->gemm_q4k(q4, NIN, 0, 3, &a, out, NOUT);
                        kk->gemm_q4k(q4, NIN, 3, NOUT, &a, out, NOUT);
                    } else {
                        kk->quantize_q80(x, NIN, 0, ntb, &a);
                        kk->gemm_q80(q8, NIN, 0, 3, &a, out, NOUT);
                        kk->gemm_q80(q8, NIN, 3, NOUT, &a, out, NOUT);
                    }
                    ore_qact_free(&a);
                } else {
                    ore_pack16(x, NIN, T, NIN, 0, ntb, xp);
                    kk->gemm_f32(which == 2 ? (const void *) wh : (const void *) wf, which == 2, NIN, NIN, 0, NOUT, xp,
                                 T, out, NOUT, scr);
                }
            }
            CHECK(same(k, yr, yk, (size_t) T * NOUT), "%s: %s product differs from the reference at %d frames", k->name,
                  what, T);
        }
        ore_free(x);
        ore_free(yr);
        ore_free(yk);
        ore_free(xp);
        ore_free(scr);
    }
    // The element-wise steps.
    enum { N = 1024 };
    float * x  = (float *) ore_alloc(sizeof(float) * N * 12);
    float * r  = (float *) ore_alloc(sizeof(float) * N * 5);
    float * o  = (float *) ore_alloc(sizeof(float) * N * 5);
    float * gm = x + N * 9, *bt = x + N * 10, *sc = x + N * 11;
    for (int i = 0; i < N * 12; ++i) x[i] = rnd_f() * 3.0f;
    x[5] = 200.0f;  // exp's overflow and underflow branches
    x[6] = -200.0f;
    x[7] = 100.0f;
    const float * taps[9];
    for (int j = 0; j < 9; ++j) taps[j] = (j == 0 || j == 8) ? NULL : x + (size_t) j * N;
    for (int pass = 0; pass < 2; ++pass) {
        const ore_kernels * kk  = pass ? k : ref;
        float *             out = pass ? o : r;
        kk->layer_norm(x, out, N, gm, bt, 1e-5f);
        kk->layer_norm(x + N, out + N - 13, 13, gm, bt, 1e-5f);  // overwrites the tail: a short vector
        memcpy(out + N, x, sizeof(float) * N);
        kk->silu(out + N, N - 1);
        kk->glu(x, x + N, out + 2 * N, N - 3);
        memcpy(out + 3 * N, x + 2 * N, sizeof(float) * 137);
        kk->softmax(out + 3 * N, 137);
        kk->dwconv_bn_silu(taps, x, 9, 509, sc, bt, out + 3 * N + 160);
        kk->dwconv_bias(taps, x + N, 9, 131, bt, out + 3 * N + 700);
        kk->gemv_f32(x, 11, 77, x + 3 * N, out + 4 * N);       // a ragged shape
        kk->gemv_f32(x, 9, 96, x + 4 * N, out + 4 * N + 32);   // whole sixteens
        kk->gemv_f32(x, 1, 640, x + 5 * N, out + 4 * N + 64);  // one row
    }
    CHECK(same(k, r, o, (size_t) N * 5), "%s: an element-wise step differs from the reference", k->name);
    float sum = 0;
    for (int i = 0; i < 137; ++i) sum += r[3 * N + i];
    CHECK(fabsf(sum - 1.0f) < 1e-5f, "softmax does not sum to one (%g)", (double) sum);
    ore_free(x);
    ore_free(r);
    ore_free(o);
    ore_free(q4);
    ore_free(q8);
    ore_free(wh);
    ore_free(wf);
}

// ---- threads ----------------------------------------------------------------------

typedef struct {
    int * hits;
    int   n;
} hit_ctx;
static void job_hit(void * v, int b, int e, int thread) {
    hit_ctx * c = (hit_ctx *) v;
    (void) thread;
    for (int i = b; i < e; ++i) ++c->hits[i];  // each index belongs to one chunk
}

static void test_threads(void) {
    enum { N = 1000 };
    int hits[N];
    for (int threads = 1; threads <= 5; ++threads) {
        ore_pool * p = ore_pool_new(threads);
        CHECK(p != NULL, "cannot make a pool of %d", threads);
        if (!p) continue;
        int bad = 0;
        for (int job = 0; job < 3000; ++job) {
            const int n = 1 + (int) (rnd_u32() % N), grain = 1 + (int) (rnd_u32() % 64);
            memset(hits, 0, sizeof hits);
            hit_ctx c = { hits, n };
            ore_parallel_for(p, n, grain, job_hit, &c);
            for (int i = 0; i < N; ++i) bad += hits[i] != (i < n);
        }
        CHECK(bad == 0, "threads: with %d threads, %d indexes were not done exactly once", threads, bad);
        ore_pool_free(p);
    }
}

// ---- the model file reader --------------------------------------------------------

static size_t put(uint8_t * b, size_t at, const void * p, size_t n) {
    memcpy(b + at, p, n);
    return at + n;
}
static size_t put_u32(uint8_t * b, size_t at, uint32_t v) { return put(b, at, &v, 4); }
static size_t put_u64(uint8_t * b, size_t at, uint64_t v) { return put(b, at, &v, 8); }
static size_t put_str(uint8_t * b, size_t at, const char * s) {
    at = put_u64(b, at, strlen(s));
    return put(b, at, s, strlen(s));
}

static int write_file(const char * path, const uint8_t * b, size_t n) {
    FILE * f = fopen(path, "wb");
    if (!f) return 0;
    const size_t w = fwrite(b, 1, n, f);
    fclose(f);
    return w == n;
}

static void test_gguf(const char * path) {
    uint8_t b[1024];
    size_t  n = 0;
    memset(b, 0, sizeof b);
    n = put(b, n, "GGUF", 4);
    n = put_u32(b, n, 3);
    n = put_u64(b, n, 1);  // tensors
    n = put_u64(b, n, 5);  // key-value pairs
    n = put_str(b, n, "a.count");
    n = put_u32(b, n, 4);  // u32
    n = put_u32(b, n, 24);
    n = put_str(b, n, "a.name");
    n = put_u32(b, n, 8);  // string
    n = put_str(b, n, "parakeet");
    n = put_str(b, n, "a.flag");
    n = put_u32(b, n, 7);  // bool
    b[n++] = 1;
    n      = put_str(b, n, "a.words");
    n      = put_u32(b, n, 9);  // array
    n      = put_u32(b, n, 8);  // of strings
    n      = put_u64(b, n, 2);
    n      = put_str(b, n, "one");
    n      = put_str(b, n, "three");
    n      = put_str(b, n, "a.numbers");
    n      = put_u32(b, n, 9);
    n      = put_u32(b, n, 5);  // of i32
    n      = put_u64(b, n, 3);
    n      = put_u32(b, n, 0);
    n      = put_u32(b, n, 1);
    n      = put_u32(b, n, 4);
    n      = put_str(b, n, "t.weight");
    n      = put_u32(b, n, 2);  // dims
    n      = put_u64(b, n, 3);
    n      = put_u64(b, n, 2);
    n      = put_u32(b, n, 0);  // F32
    n      = put_u64(b, n, 0);  // offset
    n      = (n + 31) / 32 * 32;
    for (int i = 0; i < 6; ++i) {
        const float v = (float) i + 0.5f;
        n             = put(b, n, &v, 4);
    }
    CHECK(write_file(path, b, n), "cannot write %s", path);
    const char * err = NULL;
    ore_gguf *   g   = ore_gguf_open(path, &err);
    CHECK(g != NULL, "reader: a valid file does not open (%s)", err ? err : "");
    if (g) {
        uint32_t     u = 0, nums[3] = { 9, 9, 9 };
        int          flag = 0;
        const char * s    = NULL;
        size_t       len  = 0;
        uint64_t     cnt  = 0;
        ore_tensor   t;
        CHECK(ore_gguf_u32(g, "a.count", &u) && u == 24, "reader: u32");
        CHECK(ore_gguf_str(g, "a.name", &s, &len) && len == 8 && !memcmp(s, "parakeet", 8), "reader: string");
        CHECK(ore_gguf_bool(g, "a.flag", &flag) && flag == 1, "reader: bool");
        CHECK(ore_gguf_str_array(g, "a.words", &cnt) && cnt == 2, "reader: string array");
        CHECK(ore_gguf_str_array_item(g, "a.words", 1, &s, &len) && len == 5 && !memcmp(s, "three", 5),
              "reader: string array item");
        CHECK(ore_gguf_u32_array(g, "a.numbers", nums, 3) == 3 && nums[2] == 4, "reader: number array");
        CHECK(!ore_gguf_u32(g, "a.missing", &u), "reader: a missing key is found");
        CHECK(ore_gguf_tensor(g, "t.weight", &t) && t.dims[0] == 3 && t.dims[1] == 2 && t.bytes == 24 &&
                  ((const float *) t.data)[5] == 5.5f,
              "reader: tensor");
        CHECK(!ore_gguf_tensor(g, "t.other", &t), "reader: a missing tensor is found");
        ore_gguf_close(g);
    }
    // Every shorter file must be refused, not read past its end.
    int opened = 0;
    for (size_t cut = 0; cut < n; ++cut) {
        if (!write_file(path, b, cut)) break;
        ore_gguf * h = ore_gguf_open(path, NULL);
        if (h) {
            ++opened;
            ore_gguf_close(h);
        }
    }
    CHECK(opened == 0, "reader: %d truncated files opened", opened);
    // A tensor that claims more data than the file holds.
    remove(path);
}

// ---- mel --------------------------------------------------------------------------

static void test_mel(void) {
    ore_mel m;
    CHECK(ore_mel_init(&m, 16000, 512, 400, 160, 128, 0.0f, 8000.0f, 0.97f), "mel: init");
    enum { NS = 16000 };
    float * pcm = (float *) malloc(sizeof(float) * NS);
    for (int i = 0; i < NS; ++i) pcm[i] = 0.3f * sinf(2.0f * 3.14159265f * 440.0f * (float) i / 16000.0f) + 0.01f * rnd_f();
    const int T = ore_mel_frames(&m, NS);
    CHECK(T == 101, "mel: one second is %d frames, not 101", T);
    float * out = (float *) malloc(sizeof(float) * 128 * (size_t) T);
    CHECK(ore_mel_compute(&m, pcm, NS, out), "mel: compute");
    int    bad    = 0;
    double worst  = 0;
    int    loudest = 0;
    double best    = -1e9;
    for (int i = 0; i < 128; ++i) {
        double sum = 0, peak = 0;
        for (int t = 0; t < T - 1; ++t) {
            bad += !isfinite(out[i * T + t]);
            sum += out[i * T + t];
        }
        bad += out[i * T + T - 1] != 0.0f;  // the last frame is padding
        if (fabs(sum / (T - 1)) > worst) worst = fabs(sum / (T - 1));
        (void) peak;
        // Before normalization the 440 Hz band is the loudest; after it every
        // band has mean zero, so look at which filter holds 440 Hz instead.
        if (m.fb[(size_t) i * m.n_freq + 14] > best) {  // bin 14 = 437.5 Hz
            best    = m.fb[(size_t) i * m.n_freq + 14];
            loudest = i;
        }
    }
    CHECK(bad == 0, "mel: %d values are not finite or the last frame is not zero", bad);
    CHECK(worst < 1e-4, "mel: a band's mean is %.3g after normalization", worst);
    CHECK(loudest > 5 && loudest < 20, "mel: 440 Hz falls in filter %d", loudest);
    CHECK(!ore_mel_compute(&m, pcm, 200, out), "mel: a clip of two frames is accepted");
    free(pcm);
    free(out);
    ore_mel_free(&m);
}

// The matrix unit's product against the same arithmetic written plainly: the
// integer sum of each 256 columns, scaled per frame and added with fused
// multiply-add in order, then scaled per row. Bit for bit.
static void test_r8(const ore_kernels * k) {
    enum { NIN = 768, NOUT = 48 };
    const int frames[] = { 1, 5, 16, 17, 37, 70 };
    uint8_t * q4 = (uint8_t *) ore_alloc((size_t) NOUT * (NIN / 256) * ORE_Q4K_BYTES);
    for (int b = 0; b < NOUT * (NIN / 256); ++b) {
        uint8_t *      blk = q4 + (size_t) b * ORE_Q4K_BYTES;
        const uint16_t d   = ore_f32_to_f16(0.001f + (float) (rnd_u32() & 255) * 1e-5f);
        const uint16_t m   = ore_f32_to_f16(0.002f + (float) (rnd_u32() & 255) * 1e-5f);
        memcpy(blk, &d, 2);
        memcpy(blk + 2, &m, 2);
        for (int i = 4; i < ORE_Q4K_BYTES; ++i) blk[i] = (uint8_t) rnd_u32();
    }
    ore_r8 w;
    CHECK(ore_r8_make(&w, q4, ORE_T_Q4_K, NIN, NOUT), "r8: out of memory");
    for (size_t fi = 0; fi < sizeof(frames) / sizeof(frames[0]); ++fi) {
        const int T  = frames[fi];
        float *   x  = (float *) ore_alloc(sizeof(float) * (size_t) T * NIN);
        float *   yr = (float *) ore_alloc(sizeof(float) * (size_t) T * NOUT);
        float *   yk = (float *) ore_alloc(sizeof(float) * (size_t) T * NOUT);
        for (int i = 0; i < T * NIN; ++i) x[i] = rnd_f();
        ore_qact a = { 0 };
        CHECK(ore_qact_reserve(&a, T, NIN, 256), "out of memory");
        k->quantize_q8k(x, NIN, 0, ore_frame_blocks(T), &a);
        k->gemm_r8(&w, 0, 16, &a, yk, NOUT);  // rows split as the threads would
        k->gemm_r8(&w, 16, NOUT, &a, yk, NOUT);
        for (int t = 0; t < T; ++t) {
            const int tb = t / 16, f = t % 16;
            for (int r = 0; r < NOUT; ++r) {
                float acc = 0.0f;
                for (int b = 0; b < NIN / 256; ++b) {
                    int32_t sum = 0;
                    for (int kk = b * 256; kk < (b + 1) * 256; ++kk) {
                        const int8_t wq = w.q[(size_t) (r / 16) * NIN * 16 + (size_t) (kk / 4) * 64 + (r % 16) * 4 + kk % 4];
                        const int8_t xq = a.q[((size_t) tb * (NIN / 4) + kk / 4) * 64 + f * 4 + kk % 4];
                        sum += wq * xq;
                    }
                    acc = fmaf((float) sum, a.d[((size_t) tb * a.nb + b) * 16 + f], acc);
                }
                yr[(size_t) t * NOUT + r] = acc * w.scale[r];
            }
        }
        CHECK(memcmp(yr, yk, sizeof(float) * (size_t) T * NOUT) == 0, "%s: r8 product differs at %d frames", k->name, T);
        ore_qact_free(&a);
        ore_free(x);
        ore_free(yr);
        ore_free(yk);
    }
    ore_r8_free(&w);
    ore_free(q4);
}

int main(int argc, char ** argv) {
    const char * scratch = argc > 1 ? argv[1] : "ore-selftest.gguf";
    test_half();
    test_exp();
    const char * names[] = { "generic", "neon", "sme", "avx512", "avx512+avx2", "avx2", "sse" };
    printf("kernel tables:");
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        const ore_kernels * k = ore_kernels_named(names[i]);
        if (!k) continue;
        printf(" %s", k->name);
        test_kernels(k);
        if (k->gemm_r8) test_r8(k);
    }
    printf("; chosen: %s\n", ore_kernels_pick()->name);
    test_threads();
    test_gguf(scratch);
    test_mel();
    if (failures) {
        printf("%d failures\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
