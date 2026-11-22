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

int ore_q8k_reserve(ore_q8k * a, int rows, int n) {
    const int    rows_pad = (rows + 7) & ~7;
    const int    nb       = n / ORE_Q4K_BLOCK;
    const size_t q_bytes  = ((size_t) rows_pad * (size_t) n + 63) & ~(size_t) 63;
    const size_t d_bytes  = ((size_t) nb * (size_t) rows_pad * sizeof(float) + 63) & ~(size_t) 63;
    const size_t g_bytes  = (size_t) nb * (size_t) rows_pad * 8 * sizeof(int16_t);
    const size_t need     = q_bytes + d_bytes + g_bytes;
    if (need > a->cap) {
        ore_free(a->mem);
        a->mem = ore_alloc(need);
        a->cap = a->mem ? need : 0;
        if (!a->mem) return 0;
    }
    a->rows     = rows;
    a->rows_pad = rows_pad;
    a->n        = n;
    a->nb       = nb;
    a->q        = (int8_t *) a->mem;
    a->d        = (float *) ((uint8_t *) a->mem + q_bytes);
    a->gs       = (int16_t *) ((uint8_t *) a->mem + q_bytes + d_bytes);
    // Padding rows must read as zero whatever was here before.
    if (rows_pad > rows) {
        memset(a->q + (size_t) rows * n, 0, (size_t) (rows_pad - rows) * n);
        for (int b = 0; b < nb; ++b) {
            memset(a->d + (size_t) b * rows_pad + rows, 0, (size_t) (rows_pad - rows) * sizeof(float));
            memset(a->gs + ((size_t) b * rows_pad + rows) * 8, 0, (size_t) (rows_pad - rows) * 8 * sizeof(int16_t));
        }
    }
    return 1;
}

void ore_q8k_free(ore_q8k * a) {
    ore_free(a->mem);
    memset(a, 0, sizeof(*a));
}

int ore_q80_reserve(ore_q80 * a, int rows, int n) {
    const int    rows_pad = (rows + 7) & ~7;
    const int    nb       = n / ORE_Q80_BLOCK;
    const size_t q_bytes  = ((size_t) rows_pad * (size_t) n + 63) & ~(size_t) 63;
    const size_t d_bytes  = (size_t) nb * (size_t) rows_pad * sizeof(float);
    const size_t need     = q_bytes + d_bytes;
    if (need > a->cap) {
        ore_free(a->mem);
        a->mem = ore_alloc(need);
        a->cap = a->mem ? need : 0;
        if (!a->mem) return 0;
    }
    a->rows     = rows;
    a->rows_pad = rows_pad;
    a->n        = n;
    a->nb       = nb;
    a->q        = (int8_t *) a->mem;
    a->d        = (float *) ((uint8_t *) a->mem + q_bytes);
    if (rows_pad > rows) {
        memset(a->q + (size_t) rows * n, 0, (size_t) (rows_pad - rows) * n);
        memset(a->d + (size_t) rows * nb, 0, (size_t) (rows_pad - rows) * nb * sizeof(float));
    }
    return 1;
}

void ore_q80_free(ore_q80 * a) {
    ore_free(a->mem);
    memset(a, 0, sizeof(*a));
}

// Round to nearest, ties to even, for |v| < 2^22 (the trick ggml uses).
ORE_INLINE int nearest_even(float v) {
    float   s = v + 12582912.f;
    int32_t i;
    memcpy(&i, &s, 4);
    return (i & 0x007fffff) - 0x00400000;
}

// ---- quantize ---------------------------------------------------------------

// ggml's Q8_K: per 256 values, the value of largest magnitude maps to -127.
static void quantize_q8k_generic(const float * x, size_t xstride, int t0, int t1, ore_q8k * out) {
    const int n = out->n, nb = out->nb;
    for (int t = t0; t < t1; ++t) {
        const float * row = x + (size_t) t * xstride;
        int8_t *      q   = out->q + (size_t) t * n;
        for (int b = 0; b < nb; ++b) {
            const float * p    = row + b * 256;
            int8_t *      qb   = q + b * 256;
            float         vmax = p[0], vmin = p[0];
            for (int j = 1; j < 256; ++j) {
                if (p[j] > vmax) vmax = p[j];
                if (p[j] < vmin) vmin = p[j];
            }
            const float mx  = (-vmin > vmax) ? vmin : vmax;
            int16_t *   gs  = out->gs + ((size_t) b * out->rows_pad + t) * 8;
            float *     d   = out->d + (size_t) b * out->rows_pad + t;
            if (mx == 0.0f) {
                memset(qb, 0, 256);
                memset(gs, 0, 8 * sizeof(int16_t));
                *d = 0.0f;
                continue;
            }
            const float iscale = -127.f / mx;
            for (int g = 0; g < 8; ++g) {
                int sum = 0;
                for (int j = 0; j < 32; ++j) {
                    int v = nearest_even(iscale * p[g * 32 + j]);
                    if (v > 127) v = 127;
                    qb[g * 32 + j] = (int8_t) v;
                    sum += v;
                }
                gs[g] = (int16_t) sum;
            }
            *d = 1.0f / iscale;
        }
    }
}

// ggml's Q8_0: per 32 values, scale = max|x| / 127 kept in half precision.
static void quantize_q80_generic(const float * x, size_t xstride, int t0, int t1, ore_q80 * out) {
    const int n = out->n, nb = out->nb;
    for (int t = t0; t < t1; ++t) {
        const float * row = x + (size_t) t * xstride;
        int8_t *      q   = out->q + (size_t) t * n;
        float *       d   = out->d + (size_t) t * nb;
        for (int b = 0; b < nb; ++b) {
            const float * p    = row + b * 32;
            float         amax = 0.0f;
            for (int j = 0; j < 32; ++j) {
                const float a = fabsf(p[j]);
                if (a > amax) amax = a;
            }
            const float dd = amax / 127.0f;
            const float id = dd != 0.0f ? 1.0f / dd : 0.0f;
            d[b]           = ore_f16_to_f32(ore_f32_to_f16(dd));
            for (int j = 0; j < 32; ++j) {
                q[b * 32 + j] = (int8_t) nearest_even(p[j] * id);
            }
        }
    }
}

// ---- Q4_K product -----------------------------------------------------------

// For each weight row and each frame, block by block:
//   M = sum_g mins[g] * (sum of the frame's values in group g)
//   S = sum_g scales[g] * sum_i q4[g][i] * q8[g][i]
//   sum = fma(-(dx * dmin), M, sum);  sum = fma(dx * d, S, sum)
// which is the order ggml's arm64 kernel uses.
static void gemm_q4k_generic(const uint8_t * w, int n_in, int r0, int r1, const ore_q8k * x, float * y,
                             size_t ystride) {
    const int    nb = n_in / 256;
    const size_t rb = (size_t) nb * ORE_Q4K_BYTES;
    for (int r = r0; r < r1; ++r) {
        const uint8_t * wr = w + (size_t) r * rb;
        for (int t = 0; t < x->rows; ++t) {
            const int8_t * a   = x->q + (size_t) t * x->n;
            float          sum = 0.0f;
            for (int b = 0; b < nb; ++b) {
                const uint8_t * blk  = wr + (size_t) b * ORE_Q4K_BYTES;
                const float     dw   = ore_f16_to_f32(ore_rd16(blk));
                const float     dmin = ore_f16_to_f32(ore_rd16(blk + 2));
                uint8_t         sc[8], mn[8];
                ore_q4k_scales(blk, sc, mn);
                const uint8_t * qs = blk + 16;
                const int8_t *  ab = a + b * 256;
                const int16_t * gs = x->gs + ((size_t) b * x->rows_pad + t) * 8;
                int32_t         M = 0, S = 0;
                for (int g = 0; g < 8; ++g) {
                    M += (int32_t) mn[g] * gs[g];
                    const uint8_t * qg    = qs + (g / 2) * 32;
                    const int       shift = (g & 1) * 4;
                    int32_t         dot   = 0;
                    for (int i = 0; i < 32; ++i) {
                        dot += (int32_t) ((qg[i] >> shift) & 0x0f) * ab[g * 32 + i];
                    }
                    S += (int32_t) sc[g] * dot;
                }
                const float dx = x->d[(size_t) b * x->rows_pad + t];
                sum            = fmaf(-(dx * dmin), (float) M, sum);
                sum            = fmaf(dx * dw, (float) S, sum);
            }
            y[(size_t) t * ystride + r] = sum;
        }
    }
}

// ---- Q8_0 product -----------------------------------------------------------

// Per 32 columns: four int sums (columns 0-3, 4-7, ... of each 16 added
// across the two halves), each converted and multiplied by the two scales,
// accumulated in four float lanes that are added at the end as
// (l0 + l1) + (l2 + l3). The lane structure is what a 128-bit dot-product
// instruction produces, so every table reproduces it.
static void gemm_q80_generic(const uint8_t * w, int n_in, int r0, int r1, const ore_q80 * x, float * y,
                             size_t ystride) {
    const int    nb = n_in / 32;
    const size_t rb = (size_t) nb * ORE_Q80_BYTES;
    for (int r = r0; r < r1; ++r) {
        const uint8_t * wr = w + (size_t) r * rb;
        for (int t = 0; t < x->rows; ++t) {
            const int8_t * a  = x->q + (size_t) t * x->n;
            const float *  dx = x->d + (size_t) t * nb;
            float          lane[4] = { 0, 0, 0, 0 };
            for (int b = 0; b < nb; ++b) {
                const uint8_t * blk = wr + (size_t) b * ORE_Q80_BYTES;
                const float     s   = ore_f16_to_f32(ore_rd16(blk)) * dx[b];
                const int8_t *  qw  = (const int8_t *) blk + 2;
                const int8_t *  qa  = a + b * 32;
                for (int l = 0; l < 4; ++l) {
                    int32_t dot = 0;
                    for (int h = 0; h < 2; ++h) {
                        for (int i = 0; i < 4; ++i) {
                            dot += (int32_t) qw[h * 16 + l * 4 + i] * qa[h * 16 + l * 4 + i];
                        }
                    }
                    lane[l] = fmaf((float) dot, s, lane[l]);
                }
            }
            y[(size_t) t * ystride + r] = (lane[0] + lane[1]) + (lane[2] + lane[3]);
        }
    }
}

// ---- float product ----------------------------------------------------------

void ore_transpose_pad(const float * x, size_t xstride, int rows, int n, float * xt, size_t xt_stride) {
    // 64 columns at a time keeps both sides inside the cache.
    for (int k0 = 0; k0 < n; k0 += 64) {
        const int k1 = ORE_MIN(k0 + 64, n);
        for (int t = 0; t < rows; ++t) {
            const float * xr = x + (size_t) t * xstride;
            for (int k = k0; k < k1; ++k) xt[(size_t) k * xt_stride + t] = xr[k];
        }
    }
    if ((size_t) rows < xt_stride) {
        for (int k = 0; k < n; ++k) {
            memset(xt + (size_t) k * xt_stride + rows, 0, (xt_stride - (size_t) rows) * sizeof(float));
        }
    }
}

static void gemm_f32_generic(const void * w, int w_is_f16, size_t wstride, int n_in, int r0, int r1,
                             const float * xt, size_t xt_stride, int rows, float * y, size_t ystride,
                             float * scratch) {
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
            float sum = 0.0f;
            for (int k = 0; k < n_in; ++k) sum = fmaf(wr[k], xt[(size_t) k * xt_stride + t], sum);
            y[(size_t) t * ystride + r] = sum;
        }
    }
}

const ore_kernels ore_kernels_generic = {
    "generic", quantize_q8k_generic, quantize_q80_generic, gemm_q4k_generic, gemm_q80_generic, gemm_f32_generic,
};
