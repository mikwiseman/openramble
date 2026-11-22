// ore_kernels.h - the arithmetic the engine spends its time in.
//
// The encoder is matrix products of one shape: a weight matrix against every
// frame of the clip. A general tensor library multiplies one weight row by one
// frame at a time. These kernels put the frames in the vector lanes instead:
// activations are stored in blocks of 16 frames, interleaved four columns at a
// time, so one instruction multiplies four weights by 8 or 16 frames and the
// results land one frame per lane. Nothing is ever summed across a register.
//
// One table of function pointers per instruction set, chosen once at start
// from what the processor reports. Every table computes the same integers and
// accumulates floats in the same order, so a clip gives the same bits whichever
// table runs it, on any processor with fused multiply-add (every x86 with
// AVX2, every arm64).
#ifndef ORE_KERNELS_H
#define ORE_KERNELS_H

#include "ore_base.h"

#define ORE_FB 16  // frames per block

// Number of 16-frame blocks that hold `rows` frames.
ORE_INLINE int ore_frame_blocks(int rows) { return (rows + ORE_FB - 1) / ORE_FB; }

// Activations quantized to int8 for a Q4_K or Q8_0 product.
//   q : [ntb][n / 4][16 frames][4 columns]  (64 bytes per group of 4 columns)
//   d : [ntb][nb][16 frames]                 scale of each scale-block
//   gs: [ntb][nb][8][16 frames]              Q4_K only: sum of each 32 columns
// Scale-blocks are 256 columns for Q4_K (ggml's Q8_K) and 32 for Q8_0. Lanes
// past the last frame are zero.
typedef struct {
    int       rows;  // valid frames
    int       n;     // columns: a multiple of 256 (Q4_K) or 32 (Q8_0)
    int       nb;    // scale-blocks per frame
    int       ntb;   // 16-frame blocks
    int8_t *  q;
    float *   d;
    int32_t * gs;
    size_t    cap;
    void *    mem;
} ore_qact;

// Makes room for rows x n with scale-blocks of `block` columns (256 or 32).
// Returns 0 when out of memory.
int  ore_qact_reserve(ore_qact * a, int rows, int n, int block);
void ore_qact_free(ore_qact * a);

typedef struct ore_kernels {
    const char * name;

    // x: frames of n floats, `xstride` floats apart. Fills 16-frame blocks
    // [tb0, tb1) of `out`, which ore_qact_reserve sized.
    void (*quantize_q8k)(const float * x, size_t xstride, int tb0, int tb1, ore_qact * out);
    void (*quantize_q80)(const float * x, size_t xstride, int tb0, int tb1, ore_qact * out);

    // y[t * ystride + r] = sum_k W[r][k] * x[t][k] for r in [r0, r1), all t.
    // W is rows of n_in Q4_K values (n_in / 256 blocks of 144 bytes each).
    void (*gemm_q4k)(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y, size_t ystride);
    // The same for Q8_0 weights (n_in / 32 blocks of 34 bytes per row).
    void (*gemm_q80)(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y, size_t ystride);

    // y[t * ystride + r] = sum_k W[r][k] * x[t][k], r in [r0, r1), t in
    // [0, rows), summed in order of k with fused multiply-add. W row r starts
    // at w + r * wstride elements and is contiguous in k; `w_is_f16` selects
    // half or single precision. The frames come packed by ore_pack16:
    // xp[(tb * n_in + k) * 16 + f]. `scratch` holds 4 * n_in floats.
    void (*gemm_f32)(const void * w, int w_is_f16, size_t wstride, int n_in, int r0, int r1, const float * xp,
                     int rows, float * y, size_t ystride, float * scratch);

    // The element-wise steps. Sums run in 16 lanes (element i in lane i % 16)
    // that are added pairwise at the end, so the result does not depend on
    // the register width.

    // y = gamma * (x - mean) / sqrt(var + eps) + beta over n values.
    void (*layer_norm)(const float * x, float * y, int n, const float * gamma, const float * beta, float eps);
    // x[i] = x[i] / (1 + exp(-x[i]))
    void (*silu)(float * x, size_t n);
    // out[i] = a[i] * (1 / (1 + exp(-b[i])))
    void (*glu)(const float * a, const float * b, float * out, size_t n);
    // s = softmax(s) over n values, in place.
    void (*softmax)(float * s, int n);
    // One frame of a depthwise convolution followed by the folded batch norm
    // and SiLU: acc[c] = sum_j w[j * n + c] * taps[j][c] in order of j (a NULL
    // tap is a frame outside the clip and counts as zero);
    // out[c] = silu(acc[c] * scale[c] + bias[c]).
    void (*dwconv_bn_silu)(const float * const * taps, const float * w, int k, int n, const float * scale,
                           const float * bias, float * out);
    // The same accumulation with only a bias: out[c] = acc[c] + bias[c].
    void (*dwconv_bias)(const float * const * taps, const float * w, int k, int n, const float * bias, float * out);
    // y[r] = sum_k w[r * cols + k] * x[k] for one vector, fused, in the 16
    // lanes above.
    void (*gemv_f32)(const float * w, int rows, int cols, const float * x, float * y);
} ore_kernels;

// xp[(tb * n + k) * 16 + f] = x[(tb * 16 + f) * xstride + k], zero past `rows`.
// xp holds ore_frame_blocks(rows) * n * 16 floats. Packs blocks [tb0, tb1).
void ore_pack16(const float * x, size_t xstride, int rows, int n, int tb0, int tb1, float * xp);

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
