// ore_kernels.h - the arithmetic the engine spends its time in.
//
// One table of function pointers per instruction set, chosen once at start
// from what the processor reports. Every table computes the same integers;
// the float accumulation order is fixed (see each kernel), so a clip gives
// the same result whichever table runs it, as long as the processor has
// fused multiply-add (every x86 with AVX2, every arm64).
#ifndef ORE_KERNELS_H
#define ORE_KERNELS_H

#include "ore_base.h"

// Activations quantized for a Q4_K product: int8 values with one scale per
// 256 columns, the way ggml's Q8_K does it, laid out for the kernels.
typedef struct {
    int       rows;      // valid rows (frames)
    int       rows_pad;  // rows rounded up to 8; padding rows are zero
    int       n;         // columns, a multiple of 256
    int       nb;        // n / 256
    int8_t *  q;         // [rows_pad][n]
    float *   d;         // [nb][rows_pad]   scale of block b, row t
    int16_t * gs;        // [nb][rows_pad][8] sums of each group of 32 values
    size_t    cap;       // bytes held by `mem`
    void *    mem;
} ore_q8k;

// Makes room for rows x n; returns 0 when out of memory. Padding rows are
// cleared.
int  ore_q8k_reserve(ore_q8k * a, int rows, int n);
void ore_q8k_free(ore_q8k * a);

// Activations quantized for a Q8_0 product: int8 values with one scale per 32
// columns (held as the float a half-precision round trip gives, as ggml does).
typedef struct {
    int      rows, rows_pad, n, nb;  // nb = n / 32
    int8_t * q;                      // [rows_pad][n]
    float *  d;                      // [rows_pad][nb]
    size_t   cap;
    void *   mem;
} ore_q80;
int  ore_q80_reserve(ore_q80 * a, int rows, int n);
void ore_q80_free(ore_q80 * a);

typedef struct ore_kernels {
    const char * name;

    // x: rows of n floats, `xstride` floats apart. Quantizes rows [t0, t1).
    void (*quantize_q8k)(const float * x, size_t xstride, int t0, int t1, ore_q8k * out);
    void (*quantize_q80)(const float * x, size_t xstride, int t0, int t1, ore_q80 * out);

    // y[t * ystride + r] = sum_k W[r][k] * x[t][k] for r in [r0, r1), all t.
    // W is n_out rows of n_in Q4_K values (n_in / 256 blocks of 144 bytes).
    void (*gemm_q4k)(const uint8_t * w, int n_in, int r0, int r1, const ore_q8k * x, float * y, size_t ystride);
    // The same for Q8_0 weights (n_in / 32 blocks of 34 bytes per row).
    void (*gemm_q80)(const uint8_t * w, int n_in, int r0, int r1, const ore_q80 * x, float * y, size_t ystride);

    // y[t * ystride + r] = sum_k W[r][k] * x[t][k], r in [r0, r1), t in
    // [0, rows), summed in order of k with fused multiply-add.
    // W row r starts at w + r * wstride elements and is contiguous in k;
    // `w_is_f16` selects half or single precision. The frames come transposed:
    // xt[k * xt_stride + t], with xt_stride a multiple of 16 and the columns
    // past `rows` zero (see ore_transpose_pad). `scratch` holds 4 * n_in floats.
    void (*gemm_f32)(const void * w, int w_is_f16, size_t wstride, int n_in, int r0, int r1, const float * xt,
                     size_t xt_stride, int rows, float * y, size_t ystride, float * scratch);
} ore_kernels;

// xt[k * xt_stride + t] = x[t * xstride + k] for t < rows, zero for the rest of
// each row of xt. xt_stride >= rows.
void ore_transpose_pad(const float * x, size_t xstride, int rows, int n, float * xt, size_t xt_stride);

// The best table this processor can run.
const ore_kernels * ore_kernels_pick(void);
// A table by name ("generic", "neon", "avx2", ...), or NULL when this build or
// this processor does not have it.
const ore_kernels * ore_kernels_named(const char * name);

extern const ore_kernels ore_kernels_generic;
#if ORE_ARM64
extern const ore_kernels ore_kernels_neon;
#endif
#if ORE_X86
extern const ore_kernels ore_kernels_avx2;
#endif

#endif  // ORE_KERNELS_H
