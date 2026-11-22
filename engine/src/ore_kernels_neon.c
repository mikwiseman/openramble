// ore_kernels_neon.c - arm64 kernels (NEON with the dot-product extension,
// which every arm64 core since 2018 has).
#include "ore_kernels.h"

#if ORE_ARM64

#include <arm_neon.h>

#if defined(_MSC_VER)
#define ORE_DOTPROD
#elif defined(__clang__)
#define ORE_DOTPROD __attribute__((target("dotprod")))
#else
#define ORE_DOTPROD __attribute__((target("+dotprod")))
#endif

// ---- quantize ---------------------------------------------------------------

static void quantize_q8k_neon(const float * x, size_t xstride, int t0, int t1, ore_q8k * out) {
    const int n = out->n, nb = out->nb;
    for (int t = t0; t < t1; ++t) {
        const float * row = x + (size_t) t * xstride;
        int8_t *      q   = out->q + (size_t) t * n;
        for (int b = 0; b < nb; ++b) {
            const float * p  = row + b * 256;
            int8_t *      qb = q + b * 256;
            float32x4_t   mx0 = vld1q_f32(p), mx1 = vld1q_f32(p + 4);
            float32x4_t   mn0 = mx0, mn1 = mx1;
            for (int j = 8; j < 256; j += 8) {
                const float32x4_t a = vld1q_f32(p + j), c = vld1q_f32(p + j + 4);
                mx0 = vmaxq_f32(mx0, a);
                mn0 = vminq_f32(mn0, a);
                mx1 = vmaxq_f32(mx1, c);
                mn1 = vminq_f32(mn1, c);
            }
            const float vmax = vmaxvq_f32(vmaxq_f32(mx0, mx1));
            const float vmin = vminvq_f32(vminq_f32(mn0, mn1));
            const float mx   = (-vmin > vmax) ? vmin : vmax;
            int16_t *   gs   = out->gs + ((size_t) b * out->rows_pad + t) * 8;
            float *     d    = out->d + (size_t) b * out->rows_pad + t;
            if (mx == 0.0f) {
                memset(qb, 0, 256);
                memset(gs, 0, 8 * sizeof(int16_t));
                *d = 0.0f;
                continue;
            }
            const float iscale = -127.f / mx;
            for (int g = 0; g < 8; ++g) {
                const float * pg = p + g * 32;
                int8x16_t     qv[2];
                for (int h = 0; h < 2; ++h) {
                    const int32x4_t i0 = vcvtnq_s32_f32(vmulq_n_f32(vld1q_f32(pg + h * 16), iscale));
                    const int32x4_t i1 = vcvtnq_s32_f32(vmulq_n_f32(vld1q_f32(pg + h * 16 + 4), iscale));
                    const int32x4_t i2 = vcvtnq_s32_f32(vmulq_n_f32(vld1q_f32(pg + h * 16 + 8), iscale));
                    const int32x4_t i3 = vcvtnq_s32_f32(vmulq_n_f32(vld1q_f32(pg + h * 16 + 12), iscale));
                    const int16x8_t s0 = vcombine_s16(vqmovn_s32(i0), vqmovn_s32(i1));
                    const int16x8_t s1 = vcombine_s16(vqmovn_s32(i2), vqmovn_s32(i3));
                    qv[h]              = vcombine_s8(vqmovn_s16(s0), vqmovn_s16(s1));
                    vst1q_s8(qb + g * 32 + h * 16, qv[h]);
                }
                gs[g] = vaddvq_s16(vaddq_s16(vpaddlq_s8(qv[0]), vpaddlq_s8(qv[1])));
            }
            *d = 1.0f / iscale;
        }
    }
}

static void quantize_q80_neon(const float * x, size_t xstride, int t0, int t1, ore_q80 * out) {
    const int n = out->n, nb = out->nb;
    for (int t = t0; t < t1; ++t) {
        const float * row = x + (size_t) t * xstride;
        int8_t *      q   = out->q + (size_t) t * n;
        float *       d   = out->d + (size_t) t * nb;
        for (int b = 0; b < nb; ++b) {
            const float * p = row + b * 32;
            float32x4_t   v[8];
            float32x4_t   am = vdupq_n_f32(0.0f);
            for (int j = 0; j < 8; ++j) {
                v[j] = vld1q_f32(p + 4 * j);
                am   = vmaxq_f32(am, vabsq_f32(v[j]));
            }
            const float amax = vmaxvq_f32(am);
            const float dd   = amax / 127.0f;
            const float id   = dd != 0.0f ? 1.0f / dd : 0.0f;
            d[b]             = vgetq_lane_f32(vcvt_f32_f16(vcvt_f16_f32(vdupq_n_f32(dd))), 0);
            for (int h = 0; h < 2; ++h) {
                const int32x4_t i0 = vcvtnq_s32_f32(vmulq_n_f32(v[h * 4 + 0], id));
                const int32x4_t i1 = vcvtnq_s32_f32(vmulq_n_f32(v[h * 4 + 1], id));
                const int32x4_t i2 = vcvtnq_s32_f32(vmulq_n_f32(v[h * 4 + 2], id));
                const int32x4_t i3 = vcvtnq_s32_f32(vmulq_n_f32(v[h * 4 + 3], id));
                const int16x8_t s0 = vcombine_s16(vqmovn_s32(i0), vqmovn_s32(i1));
                const int16x8_t s1 = vcombine_s16(vqmovn_s32(i2), vqmovn_s32(i3));
                vst1q_s8(q + b * 32 + h * 16, vcombine_s8(vqmovn_s16(s0), vqmovn_s16(s1)));
            }
        }
    }
}

// ---- Q4_K product -----------------------------------------------------------

// Two weight rows against four frames at a time. Each weight group of 32 is
// unpacked once and used for all four frames.
ORE_DOTPROD
static void gemm_q4k_neon(const uint8_t * w, int n_in, int r0, int r1, const ore_q8k * x, float * y, size_t ystride) {
    const int        nb = n_in / 256;
    const size_t     rb = (size_t) nb * ORE_Q4K_BYTES;
    const int        T  = x->rows;
    const int        n  = x->n;
    const size_t     tp = (size_t) x->rows_pad;
    const uint8x16_t m4 = vdupq_n_u8(0x0f);
    const int32x4_t  z  = vdupq_n_s32(0);

    for (int r = r0; r < r1; r += 2) {
        const int       pair = r + 1 < r1;
        const uint8_t * w0   = w + (size_t) r * rb;
        const uint8_t * w1   = pair ? w0 + rb : w0;
        ore_q4k_hdr     h0[ORE_Q4K_MAX_BLOCKS], h1[ORE_Q4K_MAX_BLOCKS];
        ore_q4k_decode_row(w0, nb, h0);
        ore_q4k_decode_row(w1, nb, h1);
        for (int t = 0; t < T; t += 4) {
            const int8_t * a0   = x->q + (size_t) t * n;
            const int8_t * a1   = a0 + n;
            const int8_t * a2   = a1 + n;
            const int8_t * a3   = a2 + n;
            float32x4_t    sum0 = vdupq_n_f32(0.0f), sum1 = vdupq_n_f32(0.0f);
            for (int b = 0; b < nb; ++b) {
                const uint8_t * q0 = w0 + (size_t) b * ORE_Q4K_BYTES + 16;
                const uint8_t * q1 = w1 + (size_t) b * ORE_Q4K_BYTES + 16;
                const int8_t *  p0 = a0 + b * 256;
                const int8_t *  p1 = a1 + b * 256;
                const int8_t *  p2 = a2 + b * 256;
                const int8_t *  p3 = a3 + b * 256;
                int32x4_t       S0 = z, S1 = z;  // one lane per frame
                for (int g = 0; g < 4; ++g) {
                    const uint8x16_t x0a = vld1q_u8(q0 + 32 * g), x0b = vld1q_u8(q0 + 32 * g + 16);
                    const uint8x16_t x1a = vld1q_u8(q1 + 32 * g), x1b = vld1q_u8(q1 + 32 * g + 16);
                    for (int hi = 0; hi < 2; ++hi) {
                        int8x16_t wa0, wb0, wa1, wb1;
                        if (hi == 0) {
                            wa0 = vreinterpretq_s8_u8(vandq_u8(x0a, m4));
                            wb0 = vreinterpretq_s8_u8(vandq_u8(x0b, m4));
                            wa1 = vreinterpretq_s8_u8(vandq_u8(x1a, m4));
                            wb1 = vreinterpretq_s8_u8(vandq_u8(x1b, m4));
                        } else {
                            wa0 = vreinterpretq_s8_u8(vshrq_n_u8(x0a, 4));
                            wb0 = vreinterpretq_s8_u8(vshrq_n_u8(x0b, 4));
                            wa1 = vreinterpretq_s8_u8(vshrq_n_u8(x1a, 4));
                            wb1 = vreinterpretq_s8_u8(vshrq_n_u8(x1b, 4));
                        }
                        const int       grp = 2 * g + hi;
                        const int       off = grp * 32;
                        // One dot product per (row, frame): four lanes each.
                        // Adding lanes pairwise gives one int per frame, and
                        // the group scale then costs one multiply per row
                        // instead of one per frame.
                        const int8x16_t ya0 = vld1q_s8(p0 + off), yb0 = vld1q_s8(p0 + off + 16);
                        const int8x16_t ya1 = vld1q_s8(p1 + off), yb1 = vld1q_s8(p1 + off + 16);
                        const int8x16_t ya2 = vld1q_s8(p2 + off), yb2 = vld1q_s8(p2 + off + 16);
                        const int8x16_t ya3 = vld1q_s8(p3 + off), yb3 = vld1q_s8(p3 + off + 16);
                        const int32x4_t d00 = vdotq_s32(vdotq_s32(z, wa0, ya0), wb0, yb0);
                        const int32x4_t d01 = vdotq_s32(vdotq_s32(z, wa0, ya1), wb0, yb1);
                        const int32x4_t d02 = vdotq_s32(vdotq_s32(z, wa0, ya2), wb0, yb2);
                        const int32x4_t d03 = vdotq_s32(vdotq_s32(z, wa0, ya3), wb0, yb3);
                        const int32x4_t d10 = vdotq_s32(vdotq_s32(z, wa1, ya0), wb1, yb0);
                        const int32x4_t d11 = vdotq_s32(vdotq_s32(z, wa1, ya1), wb1, yb1);
                        const int32x4_t d12 = vdotq_s32(vdotq_s32(z, wa1, ya2), wb1, yb2);
                        const int32x4_t d13 = vdotq_s32(vdotq_s32(z, wa1, ya3), wb1, yb3);
                        S0 = vmlaq_s32(S0, vpaddq_s32(vpaddq_s32(d00, d01), vpaddq_s32(d02, d03)),
                                       vld1q_dup_s32(&h0[b].sc[grp]));
                        S1 = vmlaq_s32(S1, vpaddq_s32(vpaddq_s32(d10, d11), vpaddq_s32(d12, d13)),
                                       vld1q_dup_s32(&h1[b].sc[grp]));
                    }
                }
                // Mins against the frames' group sums.
                const int16_t * gs  = x->gs + ((size_t) b * tp + t) * 8;
                const int16x8_t g0  = vld1q_s16(gs), g1 = vld1q_s16(gs + 8);
                const int16x8_t g2  = vld1q_s16(gs + 16), g3 = vld1q_s16(gs + 24);
                const int16x8_t m0v = vld1q_s16(h0[b].mn);
                const int16x8_t m1v = vld1q_s16(h1[b].mn);
#define ORE_MINDOT(gv, mv) vmlal_high_s16(vmull_s16(vget_low_s16(gv), vget_low_s16(mv)), gv, mv)
                const int32x4_t M0 = vpaddq_s32(vpaddq_s32(ORE_MINDOT(g0, m0v), ORE_MINDOT(g1, m0v)),
                                                vpaddq_s32(ORE_MINDOT(g2, m0v), ORE_MINDOT(g3, m0v)));
                const int32x4_t M1 = vpaddq_s32(vpaddq_s32(ORE_MINDOT(g0, m1v), ORE_MINDOT(g1, m1v)),
                                                vpaddq_s32(ORE_MINDOT(g2, m1v), ORE_MINDOT(g3, m1v)));
#undef ORE_MINDOT
                const float32x4_t dx = vld1q_f32(x->d + (size_t) b * tp + t);
                sum0 = vfmsq_f32(sum0, vmulq_n_f32(dx, h0[b].dmin), vcvtq_f32_s32(M0));
                sum0 = vfmaq_f32(sum0, vmulq_n_f32(dx, h0[b].d), vcvtq_f32_s32(S0));
                sum1 = vfmsq_f32(sum1, vmulq_n_f32(dx, h1[b].dmin), vcvtq_f32_s32(M1));
                sum1 = vfmaq_f32(sum1, vmulq_n_f32(dx, h1[b].d), vcvtq_f32_s32(S1));
            }
            float s0[4], s1[4];
            vst1q_f32(s0, sum0);
            vst1q_f32(s1, sum1);
            const int tn = ORE_MIN(4, T - t);
            for (int c = 0; c < tn; ++c) {
                y[(size_t) (t + c) * ystride + r] = s0[c];
                if (pair) y[(size_t) (t + c) * ystride + r + 1] = s1[c];
            }
        }
    }
}

// ---- Q8_0 product -----------------------------------------------------------

ORE_DOTPROD
static void gemm_q80_neon(const uint8_t * w, int n_in, int r0, int r1, const ore_q80 * x, float * y, size_t ystride) {
    const int       nb = n_in / 32;
    const size_t    rb = (size_t) nb * ORE_Q80_BYTES;
    const int       T  = x->rows;
    const int32x4_t z  = vdupq_n_s32(0);
    for (int r = r0; r < r1; r += 2) {
        const int       pair = r + 1 < r1;
        const uint8_t * w0   = w + (size_t) r * rb;
        const uint8_t * w1   = pair ? w0 + rb : w0;
        for (int t = 0; t < T; t += 2) {
            const int      two = t + 1 < T;
            const int8_t * a0  = x->q + (size_t) t * x->n;
            const int8_t * a1  = a0 + x->n;  // a padding row when !two
            const float *  d0  = x->d + (size_t) t * nb;
            const float *  d1  = d0 + nb;
            float32x4_t    c00 = vdupq_n_f32(0), c01 = c00, c10 = c00, c11 = c00;
            for (int b = 0; b < nb; ++b) {
                const uint8_t * k0  = w0 + (size_t) b * ORE_Q80_BYTES;
                const uint8_t * k1  = w1 + (size_t) b * ORE_Q80_BYTES;
                const float     dw0 = ore_f16_to_f32(ore_rd16(k0));
                const float     dw1 = ore_f16_to_f32(ore_rd16(k1));
                const int8x16_t wa0 = vld1q_s8((const int8_t *) k0 + 2), wb0 = vld1q_s8((const int8_t *) k0 + 18);
                const int8x16_t wa1 = vld1q_s8((const int8_t *) k1 + 2), wb1 = vld1q_s8((const int8_t *) k1 + 18);
                const int8x16_t ya0 = vld1q_s8(a0 + b * 32), yb0 = vld1q_s8(a0 + b * 32 + 16);
                const int8x16_t ya1 = vld1q_s8(a1 + b * 32), yb1 = vld1q_s8(a1 + b * 32 + 16);
                c00 = vfmaq_n_f32(c00, vcvtq_f32_s32(vdotq_s32(vdotq_s32(z, wa0, ya0), wb0, yb0)), dw0 * d0[b]);
                c01 = vfmaq_n_f32(c01, vcvtq_f32_s32(vdotq_s32(vdotq_s32(z, wa0, ya1), wb0, yb1)), dw0 * d1[b]);
                c10 = vfmaq_n_f32(c10, vcvtq_f32_s32(vdotq_s32(vdotq_s32(z, wa1, ya0), wb1, yb0)), dw1 * d0[b]);
                c11 = vfmaq_n_f32(c11, vcvtq_f32_s32(vdotq_s32(vdotq_s32(z, wa1, ya1), wb1, yb1)), dw1 * d1[b]);
            }
            y[(size_t) t * ystride + r] = vaddvq_f32(c00);
            if (two) y[(size_t) (t + 1) * ystride + r] = vaddvq_f32(c01);
            if (pair) {
                y[(size_t) t * ystride + r + 1] = vaddvq_f32(c10);
                if (two) y[(size_t) (t + 1) * ystride + r + 1] = vaddvq_f32(c11);
            }
        }
    }
}

// ---- float product ----------------------------------------------------------

// Four weight rows against sixteen frames: each weight is broadcast and
// multiplied into four vectors of frames, so every output accumulates in order
// of k.
static void gemm_f32_neon(const void * w, int w_is_f16, size_t wstride, int n_in, int r0, int r1, const float * xt,
                          size_t xt_stride, int rows, float * y, size_t ystride, float * scratch) {
    for (int r = r0; r < r1; r += 4) {
        const int     nr = ORE_MIN(4, r1 - r);
        const float * wr[4];
        for (int i = 0; i < 4; ++i) {
            const int ri = r + ORE_MIN(i, nr - 1);
            if (w_is_f16) {
                const uint16_t * h   = (const uint16_t *) w + (size_t) ri * wstride;
                float *          dst = scratch + (size_t) i * n_in;
                int              k   = 0;
                for (; k + 4 <= n_in; k += 4) {
                    vst1q_f32(dst + k, vcvt_f32_f16(vreinterpret_f16_u16(vld1_u16(h + k))));
                }
                for (; k < n_in; ++k) dst[k] = ore_f16_to_f32(h[k]);
                wr[i] = dst;
            } else {
                wr[i] = (const float *) w + (size_t) ri * wstride;
            }
        }
        for (int t = 0; t < rows; t += 16) {
            float32x4_t   c[4][4];
            const float * xp = xt + t;
            for (int i = 0; i < 4; ++i) {
                for (int j = 0; j < 4; ++j) c[i][j] = vdupq_n_f32(0.0f);
            }
            for (int k = 0; k < n_in; ++k) {
                const float *     xk = xp + (size_t) k * xt_stride;
                const float32x4_t x0 = vld1q_f32(xk), x1 = vld1q_f32(xk + 4);
                const float32x4_t x2 = vld1q_f32(xk + 8), x3 = vld1q_f32(xk + 12);
                for (int i = 0; i < 4; ++i) {
                    const float32x4_t wv = vld1q_dup_f32(wr[i] + k);
                    c[i][0]              = vfmaq_f32(c[i][0], wv, x0);
                    c[i][1]              = vfmaq_f32(c[i][1], wv, x1);
                    c[i][2]              = vfmaq_f32(c[i][2], wv, x2);
                    c[i][3]              = vfmaq_f32(c[i][3], wv, x3);
                }
            }
            const int tn = ORE_MIN(16, rows - t);
            for (int i = 0; i < nr; ++i) {
                float out[16];
                vst1q_f32(out, c[i][0]);
                vst1q_f32(out + 4, c[i][1]);
                vst1q_f32(out + 8, c[i][2]);
                vst1q_f32(out + 12, c[i][3]);
                for (int j = 0; j < tn; ++j) y[(size_t) (t + j) * ystride + r + i] = out[j];
            }
        }
    }
}

const ore_kernels ore_kernels_neon = {
    "neon", quantize_q8k_neon, quantize_q80_neon, gemm_q4k_neon, gemm_q80_neon, gemm_f32_neon,
};

#endif  // ORE_ARM64
