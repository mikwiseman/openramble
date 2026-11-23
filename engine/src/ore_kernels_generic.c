// ore_kernels_generic.c - the kernels in plain C. This file is the definition
// of what every other table must compute; it is also what runs on a processor
// none of the others covers.
#include "ore_kernels.h"

#include <math.h>
#include <stdlib.h>

#if defined(_WIN32)
#include <malloc.h>
#endif

void * ore_alloc(size_t bytes) {
    if (bytes == 0) bytes = 64;
    bytes = (bytes + 63) & ~(size_t) 63;
#if defined(_WIN32)
    void * p = _aligned_malloc(bytes, 64);
#else
    void * p = NULL;
    if (posix_memalign(&p, 64, bytes) != 0) p = NULL;
#endif
    if (p) memset(p, 0, bytes);
    return p;
}

void ore_free(void * p) {
#if defined(_WIN32)
    _aligned_free(p);
#else
    free(p);
#endif
}

int ore_qact_reserve(ore_qact * a, int rows, int n, int block) {
    const int    ntb     = ore_frame_blocks(rows);
    const int    nb      = n / block;
    const size_t q_bytes = (size_t) ntb * (size_t) n * ORE_FB;
    const size_t d_bytes = (size_t) ntb * (size_t) nb * ORE_FB * sizeof(float);
    const size_t g_bytes = block == ORE_Q4K_BLOCK ? (size_t) ntb * (size_t) nb * 8 * ORE_FB * sizeof(int32_t) : 0;
    const size_t need    = q_bytes + d_bytes + g_bytes + 64;
    if (need > a->cap) {
        ore_free(a->mem);
        a->mem = ore_alloc(need);
        a->cap = a->mem ? need : 0;
        if (!a->mem) return 0;
    }
    a->rows = rows;
    a->n    = n;
    a->nb   = nb;
    a->ntb  = ntb;
    a->q    = (int8_t *) a->mem;
    a->d    = (float *) ((uint8_t *) a->mem + q_bytes);
    a->gs   = g_bytes ? (int32_t *) ((uint8_t *) a->mem + q_bytes + d_bytes) : NULL;
    return 1;
}

void ore_qact_free(ore_qact * a) {
    ore_free(a->mem);
    memset(a, 0, sizeof(*a));
}

void ore_pack16(const float * x, size_t xstride, int rows, int n, int tb0, int tb1, float * xp) {
    for (int tb = tb0; tb < tb1; ++tb) {
        float * blk = xp + (size_t) tb * n * ORE_FB;
        for (int f = 0; f < ORE_FB; ++f) {
            const int t = tb * ORE_FB + f;
            if (t < rows) {
                const float * xr = x + (size_t) t * xstride;
                for (int k = 0; k < n; ++k) blk[(size_t) k * ORE_FB + f] = xr[k];
            } else {
                for (int k = 0; k < n; ++k) blk[(size_t) k * ORE_FB + f] = 0.0f;
            }
        }
    }
}

// Round to nearest, ties to even, for |v| < 2^22 (the trick ggml uses).
ORE_INLINE int nearest_even(float v) {
    float   s = v + 12582912.f;
    int32_t i;
    memcpy(&i, &s, 4);
    return (i & 0x007fffff) - 0x00400000;
}

// Where frame f of block tb keeps columns [4 * k4, 4 * k4 + 4).
ORE_INLINE int8_t * qcell(const ore_qact * a, int tb, int k4, int f) {
    return a->q + (((size_t) tb * (size_t) (a->n / 4) + (size_t) k4) * ORE_FB + (size_t) f) * 4;
}

// ---- quantize ---------------------------------------------------------------

// ggml's Q8_K: per 256 values, the value of largest magnitude maps to -127.
static void quantize_q8k_generic(const float * x, size_t xstride, int tb0, int tb1, ore_qact * out) {
    const int nb = out->nb;
    for (int tb = tb0; tb < tb1; ++tb) {
        for (int f = 0; f < ORE_FB; ++f) {
            const int     t   = tb * ORE_FB + f;
            const float * row = x + (size_t) t * xstride;
            for (int b = 0; b < nb; ++b) {
                int8_t    tmp[256];
                int32_t   sums[8] = { 0 };
                float     d       = 0.0f;
                memset(tmp, 0, sizeof tmp);
                if (t < out->rows) {
                    const float * p    = row + b * 256;
                    float         vmax = p[0], vmin = p[0];
                    for (int j = 1; j < 256; ++j) {
                        if (p[j] > vmax) vmax = p[j];
                        if (p[j] < vmin) vmin = p[j];
                    }
                    const float mx = (-vmin > vmax) ? vmin : vmax;
                    if (mx != 0.0f) {
                        const float iscale = -127.f / mx;
                        for (int j = 0; j < 256; ++j) {
                            int v = nearest_even(iscale * p[j]);
                            if (v > 127) v = 127;
                            tmp[j] = (int8_t) v;
                            sums[j / 32] += v;
                        }
                        d = 1.0f / iscale;
                    }
                }
                for (int c = 0; c < 64; ++c) memcpy(qcell(out, tb, b * 64 + c, f), tmp + 4 * c, 4);
                out->d[((size_t) tb * nb + b) * ORE_FB + f] = d;
                for (int g = 0; g < 8; ++g) out->gs[(((size_t) tb * nb + b) * 8 + g) * ORE_FB + f] = sums[g];
            }
        }
    }
}

// ggml's Q8_0: per 32 values, scale = max|x| / 127 kept in half precision.
static void quantize_q80_generic(const float * x, size_t xstride, int tb0, int tb1, ore_qact * out) {
    const int nb = out->nb;
    for (int tb = tb0; tb < tb1; ++tb) {
        for (int f = 0; f < ORE_FB; ++f) {
            const int     t   = tb * ORE_FB + f;
            const float * row = x + (size_t) t * xstride;
            for (int b = 0; b < nb; ++b) {
                int8_t tmp[32];
                float  d = 0.0f;
                memset(tmp, 0, sizeof tmp);
                if (t < out->rows) {
                    const float * p    = row + b * 32;
                    float         amax = 0.0f;
                    for (int j = 0; j < 32; ++j) {
                        const float a = fabsf(p[j]);
                        if (a > amax) amax = a;
                    }
                    const float dd = amax / 127.0f;
                    const float id = dd != 0.0f ? 1.0f / dd : 0.0f;
                    d              = ore_f16_to_f32(ore_f32_to_f16(dd));
                    for (int j = 0; j < 32; ++j) tmp[j] = (int8_t) nearest_even(p[j] * id);
                }
                for (int c = 0; c < 8; ++c) memcpy(qcell(out, tb, b * 8 + c, f), tmp + 4 * c, 4);
                out->d[((size_t) tb * nb + b) * ORE_FB + f] = d;
            }
        }
    }
}

// ---- Q4_K product -----------------------------------------------------------

// For each weight row and each frame, block by block:
//   M = sum_g mins[g] * (sum of the frame's values in group g)
//   S = sum_g scales[g] * sum_i q4[g][i] * q8[g][i]
//   sum = fma(-(dx * dmin), M, sum);  sum = fma(dx * d, S, sum)
// which is the order ggml's arm64 kernel uses, so the result is the same bits.
static void gemm_q4k_generic(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y,
                             size_t ystride) {
    const int    nb = n_in / 256;
    const size_t rb = (size_t) nb * ORE_Q4K_BYTES;
    for (int r = r0; r < r1; ++r) {
        const uint8_t * wr = w + (size_t) r * rb;
        ore_q4k_hdr     h[ORE_Q4K_MAX_BLOCKS];
        ore_q4k_decode_row(wr, nb, h);
        for (int t = 0; t < x->rows; ++t) {
            const int tb = t / ORE_FB, f = t % ORE_FB;
            float     sum = 0.0f;
            for (int b = 0; b < nb; ++b) {
                const uint8_t * qs = wr + (size_t) b * ORE_Q4K_BYTES + 16;
                int32_t         M = 0, S = 0;
                for (int g = 0; g < 8; ++g) {
                    M += (int32_t) h[b].sm[8 + g] * x->gs[(((size_t) tb * nb + b) * 8 + g) * ORE_FB + f];
                    // Groups 2j and 2j + 1 are the low and high halves of the
                    // same 32 bytes.
                    const uint8_t * u     = qs + (g >> 1) * 32;
                    const int       shift = (g & 1) * 4;
                    int32_t         dot   = 0;
                    for (int c = 0; c < 8; ++c) {
                        const int8_t * a = qcell(x, tb, b * 64 + g * 8 + c, f);
                        for (int i = 0; i < 4; ++i) dot += (int32_t) ((u[4 * c + i] >> shift) & 0x0f) * a[i];
                    }
                    S += (int32_t) h[b].sm[g] * dot;
                }
                const float dx = x->d[((size_t) tb * nb + b) * ORE_FB + f];
                sum            = fmaf(-(dx * h[b].dmin), (float) M, sum);
                sum            = fmaf(dx * h[b].d, (float) S, sum);
            }
            y[(size_t) t * ystride + r] = sum;
        }
    }
}

// ---- Q8_0 product -----------------------------------------------------------

// Per 32 columns: the exact integer dot product, converted and multiplied by
// the product of the two scales, accumulated in column order.
static void gemm_q80_generic(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y,
                             size_t ystride) {
    const int    nb = n_in / 32;
    const size_t rb = (size_t) nb * ORE_Q80_BYTES;
    for (int r = r0; r < r1; ++r) {
        const uint8_t * wr = w + (size_t) r * rb;
        for (int t = 0; t < x->rows; ++t) {
            const int tb = t / ORE_FB, f = t % ORE_FB;
            float     sum = 0.0f;
            for (int b = 0; b < nb; ++b) {
                const uint8_t * blk = wr + (size_t) b * ORE_Q80_BYTES;
                const int8_t *  qw  = (const int8_t *) blk + 2;
                int32_t         dot = 0;
                for (int c = 0; c < 8; ++c) {
                    const int8_t * a = qcell(x, tb, b * 8 + c, f);
                    dot += qw[4 * c] * a[0] + qw[4 * c + 1] * a[1] + qw[4 * c + 2] * a[2] + qw[4 * c + 3] * a[3];
                }
                const float s = ore_f16_to_f32(ore_rd16(blk)) * x->d[((size_t) tb * nb + b) * ORE_FB + f];
                sum           = fmaf((float) dot, s, sum);
            }
            y[(size_t) t * ystride + r] = sum;
        }
    }
}

// ---- float product ----------------------------------------------------------

static void gemm_f32_generic(const void * w, int w_is_f16, size_t wstride, int n_in, int r0, int r1,
                             const float * xp, int rows, float * y, size_t ystride, float * scratch) {
    for (int r = r0; r < r1; ++r) {
        const float * wr;
        if (w_is_f16) {
            const uint16_t * h = (const uint16_t *) w + (size_t) r * wstride;
            for (int k = 0; k < n_in; ++k) scratch[k] = ore_f16_to_f32(h[k]);
            wr = scratch;
        } else {
            wr = (const float *) w + (size_t) r * wstride;
        }
        for (int t = 0; t < rows; ++t) {
            const float * col = xp + (size_t) (t / ORE_FB) * n_in * ORE_FB + (t % ORE_FB);
            float         sum = 0.0f;
            for (int k = 0; k < n_in; ++k) sum = fmaf(wr[k], col[(size_t) k * ORE_FB], sum);
            y[(size_t) t * ystride + r] = sum;
        }
    }
}

// ---- element-wise steps -------------------------------------------------------

// Sixteen running sums, added pairwise: (l + l+8), then (l + l+4), (l + l+2),
// and the last two.
ORE_INLINE float sum16(const float * s) {
    float t8[8], t4[4];
    for (int i = 0; i < 8; ++i) t8[i] = s[i] + s[i + 8];
    for (int i = 0; i < 4; ++i) t4[i] = t8[i] + t8[i + 4];
    return (t4[0] + t4[2]) + (t4[1] + t4[3]);
}

static void layer_norm_generic(const float * x, float * y, int n, const float * gamma, const float * beta, float eps) {
    float s[16] = { 0 };
    for (int i = 0; i < n; ++i) s[i & 15] = s[i & 15] + x[i];
    const float mean = sum16(s) / (float) n;
    float       v[16] = { 0 };
    for (int i = 0; i < n; ++i) {
        const float d = x[i] - mean;
        v[i & 15]     = fmaf(d, d, v[i & 15]);
    }
    const float var   = sum16(v) / (float) n;
    const float scale = 1.0f / sqrtf(var + eps);
    for (int i = 0; i < n; ++i) {
        const float d = x[i] - mean;
        const float t = (d * scale) * gamma[i];
        y[i]          = t + beta[i];
    }
}

static void silu_generic(float * x, size_t n) {
    for (size_t i = 0; i < n; ++i) x[i] = x[i] / (1.0f + ore_expf(0.0f - x[i]));
}

static void glu_generic(const float * a, const float * b, float * out, size_t n) {
    for (size_t i = 0; i < n; ++i) out[i] = a[i] * (1.0f / (1.0f + ore_expf(0.0f - b[i])));
}

static void softmax_generic(float * s, int n) {
    float mx = s[0];
    for (int i = 1; i < n; ++i) {
        if (s[i] > mx) mx = s[i];
    }
    float acc[16] = { 0 };
    for (int i = 0; i < n; ++i) {
        s[i]        = ore_expf(s[i] - mx);
        acc[i & 15] = acc[i & 15] + s[i];
    }
    const float inv = 1.0f / sum16(acc);
    for (int i = 0; i < n; ++i) s[i] = s[i] * inv;
}

static void dwconv_bn_silu_generic(const float * const * taps, const float * w, int k, int n, const float * scale,
                                   const float * bias, float * out) {
    for (int c = 0; c < n; ++c) {
        float acc = 0.0f;
        for (int j = 0; j < k; ++j) {
            if (taps[j]) acc = fmaf(w[(size_t) j * n + c], taps[j][c], acc);
        }
        const float t = acc * scale[c];
        const float u = t + bias[c];
        out[c]        = u / (1.0f + ore_expf(0.0f - u));
    }
}

static void dwconv_bias_generic(const float * const * taps, const float * w, int k, int n, const float * bias,
                                float * out) {
    for (int c = 0; c < n; ++c) {
        float acc = 0.0f;
        for (int j = 0; j < k; ++j) {
            if (taps[j]) acc = fmaf(w[(size_t) j * n + c], taps[j][c], acc);
        }
        out[c] = acc + bias[c];
    }
}

static void gemv_f32_generic(const float * w, int rows, int cols, const float * x, float * y) {
    for (int r = 0; r < rows; ++r) {
        const float * wr    = w + (size_t) r * cols;
        float         a[16] = { 0 };
        for (int k = 0; k < cols; ++k) a[k & 15] = fmaf(wr[k], x[k], a[k & 15]);
        y[r] = sum16(a);
    }
}

const ore_kernels ore_kernels_generic = {
    "generic",          quantize_q8k_generic, quantize_q80_generic, gemm_q4k_generic, gemm_q80_generic,
    gemm_f32_generic,   layer_norm_generic,   silu_generic,         glu_generic,      softmax_generic,
    dwconv_bn_silu_generic, dwconv_bias_generic, gemv_f32_generic, NULL,
};
