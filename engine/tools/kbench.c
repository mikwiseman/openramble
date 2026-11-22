// kbench - time each kernel table on real weights and check that all tables
// compute the same numbers.
//
//   kbench MODEL.gguf [frames=100] [reps=5]
//
// Built with -DORE_BENCH_GGML and linked against ggml, it also runs ggml's own
// Q4_K routine the way ggml's matrix product calls it, for a like-for-like
// time and a bit-for-bit comparison.
#include "../src/ore_gguf.h"
#include "../src/ore_kernels.h"
#include "tools.h"

#ifdef ORE_BENCH_GGML
// ggml's internal routines, declared here as ggml-cpu/quants.h declares them.
void quantize_row_q8_K(const float * x, void * y, int64_t k);
void ggml_vec_dot_q4_K_q8_K(int n, float * s, size_t bs, const void * vx, size_t bx, const void * vy, size_t by, int nrc);
#define GGML_Q8K_BYTES 292
#endif

static uint32_t rng_state = 0x1234567u;
static float    rnd(void) {
    // sum of four uniforms: roughly normal, deterministic everywhere
    float s = 0;
    for (int i = 0; i < 4; ++i) {
        rng_state = rng_state * 1664525u + 1013904223u;
        s += (float) (rng_state >> 8) * (1.0f / 16777216.0f);
    }
    return (s - 2.0f) * 1.7f;
}

static void compare(const char * what, const float * a, const float * b, size_t n) {
    size_t diff = 0;
    double maxd = 0, maxv = 0;
    for (size_t i = 0; i < n; ++i) {
        if (memcmp(&a[i], &b[i], 4) != 0) ++diff;
        double d = (double) a[i] - (double) b[i];
        if (d < 0) d = -d;
        if (d > maxd) maxd = d;
        double v = a[i] < 0 ? -a[i] : a[i];
        if (v > maxv) maxv = v;
    }
    printf("    %-28s %zu of %zu differ, max |diff| %.3g (max |value| %.3g)\n", what, diff, n, maxd, maxv);
    if (diff) {
        printf("      first values: %.6g %.6g %.6g %.6g  against  %.6g %.6g %.6g %.6g\n", a[0], a[1], a[2], a[3], b[0],
               b[1], b[2], b[3]);
    }
}

typedef struct {
    const char * tensor;
    const char * label;
} job_t;

int main(int argc, char ** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: kbench MODEL.gguf [frames] [reps]\n");
        return 2;
    }
    const int    T    = argc > 2 ? atoi(argv[2]) : 100;
    const int    reps = argc > 3 ? atoi(argv[3]) : 5;
    const char * err  = NULL;
    ore_gguf *   g    = ore_gguf_open(argv[1], &err);
    if (!g) {
        fprintf(stderr, "open failed: %s\n", err);
        return 1;
    }
    const ore_kernels * tables[4];
    int                 n_tables = 0;
    tables[n_tables++]           = &ore_kernels_generic;
    const ore_kernels * best     = ore_kernels_pick();
    if (best != &ore_kernels_generic) tables[n_tables++] = best;
    printf("frames %d, reps %d, best table: %s\n", T, reps, best->name);
    const int ntb = ore_frame_blocks(T);
    int       bad = 0;

    const job_t jobs[] = {
        { "enc.blocks.0.ff1.linear1.weight", "Q4_K 1024 -> 4096" },
        { "enc.blocks.0.ff1.linear2.weight", "Q4_K 4096 -> 1024" },
        { "enc.blocks.0.attn.linear_q.weight", "Q4_K 1024 -> 1024" },
        { "enc.blocks.0.attn.linear_out.weight", "Q8_0 1024 -> 1024" },
        { "enc.blocks.0.conv.pointwise1.weight", "F16  1024 -> 2048" },
    };
    for (size_t ji = 0; ji < sizeof(jobs) / sizeof(jobs[0]); ++ji) {
        ore_tensor w;
        if (!ore_gguf_tensor(g, jobs[ji].tensor, &w)) {
            fprintf(stderr, "missing tensor %s\n", jobs[ji].tensor);
            return 1;
        }
        // GGUF dims: innermost first. Linear: [n_in, n_out]; conv: [1, n_in, n_out].
        const int    n_in  = (int) (w.n_dims == 3 ? w.dims[1] : w.dims[0]);
        const int    n_out = (int) (w.n_dims == 3 ? w.dims[2] : w.dims[1]);
        const double macs  = (double) T * n_in * n_out;
        printf("%s (%s), %.0f M multiply-adds\n", jobs[ji].label, jobs[ji].tensor, macs / 1e6);

        rng_state = 0x1234567u + (uint32_t) ji;
        float * x = (float *) ore_alloc((size_t) T * n_in * sizeof(float));
        for (size_t i = 0; i < (size_t) T * n_in; ++i) x[i] = rnd();
        float * yref = (float *) ore_alloc((size_t) T * n_out * sizeof(float));
        float * y    = (float *) ore_alloc((size_t) T * n_out * sizeof(float));

        for (int ti = 0; ti < n_tables; ++ti) {
            const ore_kernels * k      = tables[ti];
            float *             out    = ti == 0 ? yref : y;
            double              best_q = 1e30, best_m = 1e30;
            const int           nrep = ti == 0 ? 1 : reps;  // the reference is slow; once is enough
            if (w.type == ORE_T_Q4_K || w.type == ORE_T_Q8_0) {
                const int q4 = w.type == ORE_T_Q4_K;
                ore_qact  a  = { 0 };
                ore_qact_reserve(&a, T, n_in, q4 ? 256 : 32);
                for (int rep = 0; rep < nrep; ++rep) {
                    double t0 = now_ms();
                    if (q4) {
                        k->quantize_q8k(x, (size_t) n_in, 0, ntb, &a);
                    } else {
                        k->quantize_q80(x, (size_t) n_in, 0, ntb, &a);
                    }
                    double t1 = now_ms();
                    if (q4) {
                        k->gemm_q4k(w.data, n_in, 0, n_out, &a, out, (size_t) n_out);
                    } else {
                        k->gemm_q80(w.data, n_in, 0, n_out, &a, out, (size_t) n_out);
                    }
                    double t2 = now_ms();
                    if (t1 - t0 < best_q) best_q = t1 - t0;
                    if (t2 - t1 < best_m) best_m = t2 - t1;
                }
                ore_qact_free(&a);
            } else {
                float * xp      = (float *) ore_alloc((size_t) ntb * n_in * ORE_FB * sizeof(float));
                float * scratch = (float *) ore_alloc((size_t) 4 * n_in * sizeof(float));
                for (int rep = 0; rep < nrep; ++rep) {
                    double t0 = now_ms();
                    ore_pack16(x, (size_t) n_in, T, n_in, 0, ntb, xp);
                    double t1 = now_ms();
                    k->gemm_f32(w.data, w.type == ORE_T_F16, (size_t) n_in, n_in, 0, n_out, xp, T, out, (size_t) n_out,
                                scratch);
                    double t2 = now_ms();
                    if (t1 - t0 < best_q) best_q = t1 - t0;
                    if (t2 - t1 < best_m) best_m = t2 - t1;
                }
                ore_free(xp);
                ore_free(scratch);
            }
            printf("  %-8s prepare %7.2f ms, product %8.2f ms, %7.1f G multiply-adds/s\n", k->name, best_q, best_m,
                   macs / best_m / 1e6);
            if (ti > 0) {
                compare("against the reference:", yref, y, (size_t) T * n_out);
                if (memcmp(yref, y, (size_t) T * n_out * sizeof(float)) != 0) bad = 1;
            }
        }

#ifdef ORE_BENCH_GGML
        if (w.type == ORE_T_Q4_K) {
            const int    nb     = n_in / 256;
            const size_t rs     = (size_t) nb * GGML_Q8K_BYTES;
            uint8_t *    wd     = (uint8_t *) ore_alloc((size_t) T * rs);
            float *      yg     = (float *) ore_alloc((size_t) T * n_out * sizeof(float));
            const size_t nb01   = (size_t) nb * ORE_Q4K_BYTES;
            double       best_q = 1e30, best_m = 1e30;
            for (int rep = 0; rep < reps; ++rep) {
                double t0 = now_ms();
                for (int t = 0; t < T; ++t) quantize_row_q8_K(x + (size_t) t * n_in, wd + (size_t) t * rs, n_in);
                double t1 = now_ms();
                // ggml_compute_forward_mul_mat_one_chunk, one thread
                for (int iir1 = 0; iir1 < T; iir1 += 16) {
                    for (int iir0 = 0; iir0 < n_out; iir0 += 16) {
                        for (int ir1 = iir1; ir1 < iir1 + 16 && ir1 < T; ++ir1) {
                            float tmp[32];
                            for (int ir0 = iir0; ir0 < iir0 + 16 && ir0 < n_out; ++ir0) {
                                ggml_vec_dot_q4_K_q8_K(n_in, &tmp[ir0 - iir0], 0, w.data + (size_t) ir0 * nb01, 0,
                                                       wd + (size_t) ir1 * rs, 0, 1);
                            }
                            const int cnt = (iir0 + 16 < n_out ? iir0 + 16 : n_out) - iir0;
                            memcpy(yg + (size_t) ir1 * n_out + iir0, tmp, (size_t) cnt * sizeof(float));
                        }
                    }
                }
                double t2 = now_ms();
                if (t1 - t0 < best_q) best_q = t1 - t0;
                if (t2 - t1 < best_m) best_m = t2 - t1;
            }
            printf("  %-8s prepare %7.2f ms, product %8.2f ms, %7.1f G multiply-adds/s\n", "ggml", best_q, best_m,
                   macs / best_m / 1e6);
            compare("ggml against the reference:", yref, yg, (size_t) T * n_out);
            ore_free(wd);
            ore_free(yg);
        }
#endif
        ore_free(x);
        ore_free(yref);
        ore_free(y);
    }
    // The element-wise steps: every table must give the reference's bits.
    {
        enum { N = 1024, NS = 137 };
        float * x  = (float *) ore_alloc(sizeof(float) * N * 12);
        float * r  = (float *) ore_alloc(sizeof(float) * N * 4);
        float * o  = (float *) ore_alloc(sizeof(float) * N * 4);
        float * gm = x + N * 9, *bt = x + N * 10, *sc = x + N * 11;
        rng_state  = 99;
        for (int i = 0; i < N * 12; ++i) x[i] = rnd() * 3.0f;
        x[5] = 200.0f;  // exp's overflow and underflow branches
        x[6] = -200.0f;
        x[7] = 100.0f;
        const float * taps[9];
        for (int j = 0; j < 9; ++j) taps[j] = (j == 0 || j == 8) ? NULL : x + (size_t) j * N;
        printf("element-wise steps\n");
        for (int ti = 0; ti < n_tables; ++ti) {
            const ore_kernels * k   = tables[ti];
            float *             out = ti == 0 ? r : o;
            k->layer_norm(x, out, N, gm, bt, 1e-5f);
            memcpy(out + N, x, sizeof(float) * N);
            k->silu(out + N, N);
            k->glu(x, x + N, out + 2 * N, N - 3);
            memcpy(out + 3 * N, x + 2 * N, sizeof(float) * NS);
            k->softmax(out + 3 * N, NS);
            k->dwconv_bn_silu(taps, x, 9, N - 16, sc, bt, out + 3 * N + 160);
            if (ti > 0) {
                printf("  %s\n", k->name);
                compare("against the reference:", r, o, (size_t) N * 4);
                if (memcmp(r, o, sizeof(float) * N * 4) != 0) bad = 1;
            }
        }
        ore_free(x);
        ore_free(r);
        ore_free(o);
    }
    ore_gguf_close(g);
    if (bad) {
        printf("FAILED: a table disagrees with the reference\n");
        return 1;
    }
    return 0;
}
