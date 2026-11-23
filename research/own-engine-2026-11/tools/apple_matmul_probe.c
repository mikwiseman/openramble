// How fast can an Apple silicon processor multiply the encoder's matrices?
//
// One product of the Parakeet encoder: 4096 weight rows of 1024 values, by
// every frame of an 8 s clip. Timed four ways on one thread, with 8-bit
// weights and 8-bit activations (the float path uses the same numbers as
// floats): NEON dot products, the 8-bit matrix extension (M2 and later),
// the matrix unit's outer products (SME, M4 and later), and Accelerate's
// single-precision product. Every integer result is checked against a plain
// loop. Nothing here is the engine's kernel; it answers which instruction
// set is worth writing one for.
//
// Build:  clang -O3 -mcpu=apple-m4 -o probe apple_matmul_probe.c -framework Accelerate -lpthread
// Run:    ./probe [threads for the SME test]
#define ACCELERATE_NEW_LAPACK
#include <Accelerate/Accelerate.h>
#include <arm_neon.h>
#include <arm_sme.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { R = 4096, K = 1024, F = 112 };  // 112 frames: 9 s of speech, a multiple of 16

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static int8_t * W;   // R x K, row-major
static int8_t * X;   // F x K, frame-major
static int32_t * REF;

static void plain(int32_t * out) {
    for (int r = 0; r < R; r++)
        for (int f = 0; f < F; f++) {
            int32_t s = 0;
            for (int k = 0; k < K; k++) s += (int32_t)W[r * K + k] * X[f * K + k];
            out[r * F + f] = s;
        }
}

// NEON dot products: one row against four frames at a time.
static void neon_dot(int32_t * out) {
    for (int r = 0; r < R; r++) {
        const int8_t * w = W + (size_t)r * K;
        for (int f = 0; f < F; f += 4) {
            int32x4_t a0 = vdupq_n_s32(0), a1 = a0, a2 = a0, a3 = a0;
            const int8_t * x0 = X + (size_t)f * K, * x1 = x0 + K, * x2 = x1 + K, * x3 = x2 + K;
            for (int k = 0; k < K; k += 16) {
                int8x16_t wv = vld1q_s8(w + k);
                a0 = vdotq_s32(a0, wv, vld1q_s8(x0 + k));
                a1 = vdotq_s32(a1, wv, vld1q_s8(x1 + k));
                a2 = vdotq_s32(a2, wv, vld1q_s8(x2 + k));
                a3 = vdotq_s32(a3, wv, vld1q_s8(x3 + k));
            }
            out[r * F + f] = vaddvq_s32(a0);
            out[r * F + f + 1] = vaddvq_s32(a1);
            out[r * F + f + 2] = vaddvq_s32(a2);
            out[r * F + f + 3] = vaddvq_s32(a3);
        }
    }
}

// The 8-bit matrix extension: two rows by two frames per instruction.
// Weights and activations are interleaved in pairs once, outside the timing
// of neither: the packing is counted.
static void i8mm(int32_t * out, int8_t * wp, int8_t * xp) {
    // wp: for each row pair, K/8 blocks of [row a k..k+7 | row b k..k+7]
    for (int r = 0; r < R; r += 2)
        for (int k = 0; k < K; k += 8) {
            memcpy(wp + ((size_t)(r / 2) * (K / 8) + k / 8) * 16, W + (size_t)r * K + k, 8);
            memcpy(wp + ((size_t)(r / 2) * (K / 8) + k / 8) * 16 + 8, W + (size_t)(r + 1) * K + k, 8);
        }
    for (int f = 0; f < F; f += 2)
        for (int k = 0; k < K; k += 8) {
            memcpy(xp + ((size_t)(f / 2) * (K / 8) + k / 8) * 16, X + (size_t)f * K + k, 8);
            memcpy(xp + ((size_t)(f / 2) * (K / 8) + k / 8) * 16 + 8, X + (size_t)(f + 1) * K + k, 8);
        }
    for (int r = 0; r < R; r += 2) {
        const int8_t * w = wp + (size_t)(r / 2) * (K / 8) * 16;
        for (int f = 0; f < F; f += 8) {
            int32x4_t a0 = vdupq_n_s32(0), a1 = a0, a2 = a0, a3 = a0;
            const int8_t * x0 = xp + (size_t)(f / 2) * (K / 8) * 16;
            const int8_t * x1 = x0 + (K / 8) * 16, * x2 = x1 + (K / 8) * 16, * x3 = x2 + (K / 8) * 16;
            for (int b = 0; b < K / 8; b++) {
                int8x16_t wv = vld1q_s8(w + b * 16);
                a0 = vmmlaq_s32(a0, wv, vld1q_s8(x0 + b * 16));
                a1 = vmmlaq_s32(a1, wv, vld1q_s8(x1 + b * 16));
                a2 = vmmlaq_s32(a2, wv, vld1q_s8(x2 + b * 16));
                a3 = vmmlaq_s32(a3, wv, vld1q_s8(x3 + b * 16));
            }
            int32x4_t a[4] = { a0, a1, a2, a3 };
            for (int j = 0; j < 4; j++) {
                // lanes: [ra*fa, ra*fb, rb*fa, rb*fb]
                out[r * F + f + 2 * j] = vgetq_lane_s32(a[j], 0);
                out[r * F + f + 2 * j + 1] = vgetq_lane_s32(a[j], 1);
                out[(r + 1) * F + f + 2 * j] = vgetq_lane_s32(a[j], 2);
                out[(r + 1) * F + f + 2 * j + 1] = vgetq_lane_s32(a[j], 3);
            }
        }
    }
}

// The matrix unit: 16 rows by 16 frames per instruction, four values of k
// in each. Weights and activations are interleaved in sixteens.
typedef struct { int32_t * out; const int8_t * wp; const int8_t * xp; int r0, r1; } sme_job;

__arm_locally_streaming __arm_new("za") static void sme_rows(const sme_job * job) {
    const svbool_t all8 = svptrue_b8();
    const svbool_t all32 = svptrue_b32();
    for (int g = job->r0 / 16; g < job->r1 / 16; g++) {
        const int8_t * w = job->wp + (size_t)g * (K / 4) * 64;
        for (int fg = 0; fg < F / 16; fg += 4) {
            const int8_t * x0 = job->xp + (size_t)fg * (K / 4) * 64;
            const int8_t * x1 = x0 + (K / 4) * 64, * x2 = x1 + (K / 4) * 64, * x3 = x2 + (K / 4) * 64;
            const int tiles = (F / 16 - fg) < 4 ? (F / 16 - fg) : 4;
            svzero_za();
            for (int b = 0; b < K / 4; b++) {
                svint8_t wv = svld1_s8(all8, w + b * 64);
                svmopa_za32_s8_m(0, all8, all8, wv, svld1_s8(all8, x0 + b * 64));
                if (tiles > 1) svmopa_za32_s8_m(1, all8, all8, wv, svld1_s8(all8, x1 + b * 64));
                if (tiles > 2) svmopa_za32_s8_m(2, all8, all8, wv, svld1_s8(all8, x2 + b * 64));
                if (tiles > 3) svmopa_za32_s8_m(3, all8, all8, wv, svld1_s8(all8, x3 + b * 64));
            }
#define STORE_TILE(t) \
            if (tiles > t) for (int i = 0; i < 16; i++) \
                svst1_s32(all32, job->out + (size_t)(g * 16 + i) * F + (fg + t) * 16, \
                          svread_hor_za32_s32_m(svdup_s32(0), all32, t, i));
            STORE_TILE(0) STORE_TILE(1) STORE_TILE(2) STORE_TILE(3)
        }
    }
}

static void * sme_thread(void * arg) { sme_rows(arg); return NULL; }

static void sme_pack(int8_t * wp, int8_t * xp) {
    for (int g = 0; g < R / 16; g++)
        for (int b = 0; b < K / 4; b++)
            for (int i = 0; i < 16; i++)
                memcpy(wp + ((size_t)g * (K / 4) + b) * 64 + i * 4, W + (size_t)(g * 16 + i) * K + b * 4, 4);
    for (int g = 0; g < F / 16; g++)
        for (int b = 0; b < K / 4; b++)
            for (int j = 0; j < 16; j++)
                memcpy(xp + ((size_t)g * (K / 4) + b) * 64 + j * 4, X + (size_t)(g * 16 + j) * K + b * 4, 4);
}

static int same(const int32_t * out, const char * name) {
    long bad = 0;
    for (long i = 0; i < (long)R * F; i++) bad += out[i] != REF[i];
    if (bad) printf("  %s: %ld of %ld values DIFFER from the plain loop\n", name, bad, (long)R * F);
    return bad == 0;
}

int main(int argc, char ** argv) {
    int sme_threads = argc > 1 ? atoi(argv[1]) : 1;
    const double work = (double)R * K * F;
    W = malloc((size_t)R * K);
    X = malloc((size_t)F * K);
    REF = malloc(sizeof(int32_t) * R * F);
    int32_t * out = malloc(sizeof(int32_t) * R * F);
    srand(7);
    for (size_t i = 0; i < (size_t)R * K; i++) W[i] = (int8_t)(rand() % 31 - 15);
    for (size_t i = 0; i < (size_t)F * K; i++) X[i] = (int8_t)(rand() % 255 - 127);
    plain(REF);
    printf("%d rows of %d by %d frames, %.0f M multiply-adds\n", R, K, F, work / 1e6);

    double best;
#define TIME(reps, call) best = 1e9; for (int i = 0; i < reps; i++) { double t = now(); call; t = now() - t; if (t < best) best = t; }

    TIME(5, neon_dot(out));
    printf("  NEON dot product, 1 thread:        %7.2f ms  %7.1f G multiply-adds/s  %s\n", best * 1e3, work / best / 1e9, same(out, "neon") ? "same" : "");

    int8_t * wp2 = malloc((size_t)R * K), * xp2 = malloc((size_t)F * K);
    TIME(5, i8mm(out, wp2, xp2));
    printf("  8-bit matrix extension, 1 thread:  %7.2f ms  %7.1f G multiply-adds/s  %s (packing counted)\n", best * 1e3, work / best / 1e9, same(out, "i8mm") ? "same" : "");

    int8_t * wp = malloc((size_t)R * K), * xp = malloc((size_t)F * K);
    double t = now();
    sme_pack(wp, xp);
    printf("  (packing for the matrix unit: %.2f ms, scalar)\n", (now() - t) * 1e3);
    for (int n = 1; n <= sme_threads; n *= 2) {
        best = 1e9;
        for (int rep = 0; rep < 7; rep++) {
            pthread_t ids[64];
            sme_job jobs[64];
            double t0 = now();
            for (int i = 0; i < n; i++) {
                jobs[i] = (sme_job){ out, wp, xp, (R / 16 * i / n) * 16, (R / 16 * (i + 1) / n) * 16 };
                pthread_create(&ids[i], NULL, sme_thread, &jobs[i]);
            }
            for (int i = 0; i < n; i++) pthread_join(ids[i], NULL);
            double dt = now() - t0;
            if (dt < best) best = dt;
        }
        printf("  matrix unit (SME), %d thread%s:       %7.2f ms  %7.1f G multiply-adds/s  %s\n", n, n > 1 ? "s" : " ", best * 1e3, work / best / 1e9, same(out, "sme") ? "same" : "");
    }

    float * wf = malloc(sizeof(float) * R * K), * xf = malloc(sizeof(float) * F * K), * of = malloc(sizeof(float) * R * F);
    for (size_t i = 0; i < (size_t)R * K; i++) wf[i] = W[i];
    for (size_t i = 0; i < (size_t)F * K; i++) xf[i] = X[i];
    TIME(7, cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, R, F, K, 1.0f, wf, K, xf, K, 0.0f, of, F));
    long bad = 0;
    for (long i = 0; i < (long)R * F; i++) bad += (int32_t)of[i] != REF[i];
    printf("  Accelerate, single precision:      %7.2f ms  %7.1f G multiply-adds/s  %s\n", best * 1e3, work / best / 1e9, bad ? "DIFFERS" : "same");
    return 0;
}
