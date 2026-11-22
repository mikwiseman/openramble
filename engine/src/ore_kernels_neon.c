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

// Frame f of block tb, columns [4 * k4, 4 * k4 + 4).
ORE_INLINE int8_t * qcell(const ore_qact * a, int tb, int k4, int f) {
    return a->q + (((size_t) tb * (size_t) (a->n / 4) + (size_t) k4) * ORE_FB + (size_t) f) * 4;
}

// ---- quantize ---------------------------------------------------------------

static void quantize_q8k_neon(const float * x, size_t xstride, int tb0, int tb1, ore_qact * out) {
    const int nb = out->nb;
    for (int tb = tb0; tb < tb1; ++tb) {
        for (int f = 0; f < ORE_FB; ++f) {
            const int     t   = tb * ORE_FB + f;
            const float * row = x + (size_t) t * xstride;
            for (int b = 0; b < nb; ++b) {
                int8_t  tmp[256];
                int32_t sums[8] = { 0 };
                float   d       = 0.0f;
                float   mx      = 0.0f;
                if (t < out->rows) {
                    const float * p   = row + b * 256;
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
                    mx               = (-vmin > vmax) ? vmin : vmax;
                }
                if (mx != 0.0f) {
                    const float * p      = row + b * 256;
                    const float   iscale = -127.f / mx;
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
                            vst1q_s8(tmp + g * 32 + h * 16, qv[h]);
                        }
                        sums[g] = vaddvq_s16(vaddq_s16(vpaddlq_s8(qv[0]), vpaddlq_s8(qv[1])));
                    }
                    d = 1.0f / iscale;
                } else {
                    memset(tmp, 0, sizeof tmp);
                }
                int8_t * dst = qcell(out, tb, b * 64, f);
                for (int c = 0; c < 64; ++c) memcpy(dst + (size_t) c * 64, tmp + 4 * c, 4);
                out->d[((size_t) tb * nb + b) * ORE_FB + f] = d;
                for (int g = 0; g < 8; ++g) out->gs[(((size_t) tb * nb + b) * 8 + g) * ORE_FB + f] = sums[g];
            }
        }
    }
}

static void quantize_q80_neon(const float * x, size_t xstride, int tb0, int tb1, ore_qact * out) {
    const int nb = out->nb;
    for (int tb = tb0; tb < tb1; ++tb) {
        for (int f = 0; f < ORE_FB; ++f) {
            const int     t   = tb * ORE_FB + f;
            const float * row = x + (size_t) t * xstride;
            for (int b = 0; b < nb; ++b) {
                int8_t tmp[32];
                float  d = 0.0f;
                if (t < out->rows) {
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
                    d                = vgetq_lane_f32(vcvt_f32_f16(vcvt_f16_f32(vdupq_n_f32(dd))), 0);
                    for (int h = 0; h < 2; ++h) {
                        const int32x4_t i0 = vcvtnq_s32_f32(vmulq_n_f32(v[h * 4 + 0], id));
                        const int32x4_t i1 = vcvtnq_s32_f32(vmulq_n_f32(v[h * 4 + 1], id));
                        const int32x4_t i2 = vcvtnq_s32_f32(vmulq_n_f32(v[h * 4 + 2], id));
                        const int32x4_t i3 = vcvtnq_s32_f32(vmulq_n_f32(v[h * 4 + 3], id));
                        const int16x8_t s0 = vcombine_s16(vqmovn_s32(i0), vqmovn_s32(i1));
                        const int16x8_t s1 = vcombine_s16(vqmovn_s32(i2), vqmovn_s32(i3));
                        vst1q_s8(tmp + h * 16, vcombine_s8(vqmovn_s16(s0), vqmovn_s16(s1)));
                    }
                } else {
                    memset(tmp, 0, sizeof tmp);
                }
                int8_t * dst = qcell(out, tb, b * 8, f);
                for (int c = 0; c < 8; ++c) memcpy(dst + (size_t) c * 64, tmp + 4 * c, 4);
                out->d[((size_t) tb * nb + b) * ORE_FB + f] = d;
            }
        }
    }
}

// ---- Q4_K product -----------------------------------------------------------

// One 16-frame block against two weight rows, `nv` vectors of four frames.
// Four weights are broadcast and dotted with four columns of every frame, so
// each lane of the accumulator is one frame's sum; the group scale is applied
// once per group, and nothing is ever added across a register.
ORE_DOTPROD ORE_INLINE void q4k_block_neon(const uint32_t * u0, const uint32_t * u1, const ore_q4k_hdr * h0,
                                           const ore_q4k_hdr * h1, int nb, const int8_t * A, const int32_t * G,
                                           const float * D, float * o0, float * o1, const int nv) {
    float32x4_t s0[4], s1[4];
    for (int v = 0; v < 4; ++v) s0[v] = s1[v] = vdupq_n_f32(0.0f);
    for (int b = 0; b < nb; ++b) {
        int32x4_t S0[4], S1[4], M0[4], M1[4];
        for (int v = 0; v < 4; ++v) S0[v] = S1[v] = M0[v] = M1[v] = vdupq_n_s32(0);
        for (int g = 0; g < 8; ++g) {
            int32x4_t a0[4], a1[4];
            for (int v = 0; v < 4; ++v) a0[v] = a1[v] = vdupq_n_s32(0);
            const uint32_t * p0 = u0 + b * 64 + g * 8;
            const uint32_t * p1 = u1 + b * 64 + g * 8;
            const int8_t *   Ag = A + ((size_t) b * 64 + (size_t) g * 8) * 64;
            for (int c = 0; c < 8; ++c) {
                const int8x16_t wb0 = vreinterpretq_s8_u32(vld1q_dup_u32(p0 + c));
                const int8x16_t wb1 = vreinterpretq_s8_u32(vld1q_dup_u32(p1 + c));
                for (int v = 0; v < nv; ++v) {
                    const int8x16_t xv = vld1q_s8(Ag + c * 64 + v * 16);
                    a0[v]              = vdotq_s32(a0[v], wb0, xv);
                    a1[v]              = vdotq_s32(a1[v], wb1, xv);
                }
            }
            const int32x4_t sc0 = vld1q_dup_s32(&h0[b].sc[g]), sc1 = vld1q_dup_s32(&h1[b].sc[g]);
            const int32x4_t m0 = vld1q_dup_s32(&h0[b].mn[g]), m1 = vld1q_dup_s32(&h1[b].mn[g]);
            for (int v = 0; v < nv; ++v) {
                S0[v] = vmlaq_s32(S0[v], a0[v], sc0);
                S1[v] = vmlaq_s32(S1[v], a1[v], sc1);
                const int32x4_t gv = vld1q_s32(G + ((size_t) b * 8 + g) * ORE_FB + v * 4);
                M0[v]              = vmlaq_s32(M0[v], gv, m0);
                M1[v]              = vmlaq_s32(M1[v], gv, m1);
            }
        }
        for (int v = 0; v < nv; ++v) {
            const float32x4_t dx = vld1q_f32(D + (size_t) b * ORE_FB + v * 4);
            s0[v] = vfmsq_f32(s0[v], vmulq_n_f32(dx, h0[b].dmin), vcvtq_f32_s32(M0[v]));
            s0[v] = vfmaq_f32(s0[v], vmulq_n_f32(dx, h0[b].d), vcvtq_f32_s32(S0[v]));
            s1[v] = vfmsq_f32(s1[v], vmulq_n_f32(dx, h1[b].dmin), vcvtq_f32_s32(M1[v]));
            s1[v] = vfmaq_f32(s1[v], vmulq_n_f32(dx, h1[b].d), vcvtq_f32_s32(S1[v]));
        }
    }
    for (int v = 0; v < nv; ++v) {
        vst1q_f32(o0 + v * 4, s0[v]);
        vst1q_f32(o1 + v * 4, s1[v]);
    }
}

ORE_DOTPROD
static void gemm_q4k_neon(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y, size_t ystride) {
    const int    nb = n_in / 256;
    const size_t rb = (size_t) nb * ORE_Q4K_BYTES;
    const size_t n4 = (size_t) n_in / 4;
    for (int r = r0; r < r1; r += 2) {
        const int       pair = r + 1 < r1;
        const uint8_t * w0   = w + (size_t) r * rb;
        const uint8_t * w1   = pair ? w0 + rb : w0;
        ore_q4k_hdr     h0[ORE_Q4K_MAX_BLOCKS], h1[ORE_Q4K_MAX_BLOCKS];
        uint32_t        u0[ORE_Q4K_MAX_COLS / 4], u1[ORE_Q4K_MAX_COLS / 4];
        ore_q4k_decode_row(w0, nb, h0);
        ore_q4k_decode_row(w1, nb, h1);
        ore_q4k_unpack_row(w0, nb, (uint8_t *) u0);
        ore_q4k_unpack_row(w1, nb, (uint8_t *) u1);
        for (int tb = 0; tb < x->ntb; ++tb) {
            const int       valid = ORE_MIN(ORE_FB, x->rows - tb * ORE_FB);
            const int8_t *  A     = x->q + (size_t) tb * n4 * 64;
            const int32_t * G     = x->gs + (size_t) tb * nb * 8 * ORE_FB;
            const float *   D     = x->d + (size_t) tb * nb * ORE_FB;
            float           o0[16], o1[16];
            switch ((valid + 3) / 4) {
                case 1: q4k_block_neon(u0, u1, h0, h1, nb, A, G, D, o0, o1, 1); break;
                case 2: q4k_block_neon(u0, u1, h0, h1, nb, A, G, D, o0, o1, 2); break;
                case 3: q4k_block_neon(u0, u1, h0, h1, nb, A, G, D, o0, o1, 3); break;
                default: q4k_block_neon(u0, u1, h0, h1, nb, A, G, D, o0, o1, 4); break;
            }
            float * yr = y + (size_t) tb * ORE_FB * ystride + r;
            for (int f = 0; f < valid; ++f) {
                yr[(size_t) f * ystride] = o0[f];
                if (pair) yr[(size_t) f * ystride + 1] = o1[f];
            }
        }
    }
}

// ---- Q8_0 product -----------------------------------------------------------

ORE_DOTPROD
static void gemm_q80_neon(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y, size_t ystride) {
    const int    nb = n_in / 32;
    const size_t rb = (size_t) nb * ORE_Q80_BYTES;
    const size_t n4 = (size_t) n_in / 4;
    for (int r = r0; r < r1; r += 2) {
        const int       pair = r + 1 < r1;
        const uint8_t * w0   = w + (size_t) r * rb;
        const uint8_t * w1   = pair ? w0 + rb : w0;
        // The rows' values and scales, pulled out of their 34-byte blocks.
        uint32_t u0[ORE_Q4K_MAX_COLS / 4], u1[ORE_Q4K_MAX_COLS / 4];
        float    dw0[ORE_Q4K_MAX_COLS / 32], dw1[ORE_Q4K_MAX_COLS / 32];
        for (int b = 0; b < nb; ++b) {
            memcpy((uint8_t *) u0 + b * 32, w0 + (size_t) b * ORE_Q80_BYTES + 2, 32);
            memcpy((uint8_t *) u1 + b * 32, w1 + (size_t) b * ORE_Q80_BYTES + 2, 32);
            dw0[b] = ore_f16_to_f32(ore_rd16(w0 + (size_t) b * ORE_Q80_BYTES));
            dw1[b] = ore_f16_to_f32(ore_rd16(w1 + (size_t) b * ORE_Q80_BYTES));
        }
        for (int tb = 0; tb < x->ntb; ++tb) {
            const int      valid = ORE_MIN(ORE_FB, x->rows - tb * ORE_FB);
            const int8_t * A     = x->q + (size_t) tb * n4 * 64;
            const float *  D     = x->d + (size_t) tb * nb * ORE_FB;
            float32x4_t    s0[4], s1[4];
            for (int v = 0; v < 4; ++v) s0[v] = s1[v] = vdupq_n_f32(0.0f);
            for (int b = 0; b < nb; ++b) {
                int32x4_t a0[4], a1[4];
                for (int v = 0; v < 4; ++v) a0[v] = a1[v] = vdupq_n_s32(0);
                for (int c = 0; c < 8; ++c) {
                    const int8x16_t wb0 = vreinterpretq_s8_u32(vld1q_dup_u32(u0 + b * 8 + c));
                    const int8x16_t wb1 = vreinterpretq_s8_u32(vld1q_dup_u32(u1 + b * 8 + c));
                    const int8_t *  Ac  = A + ((size_t) b * 8 + c) * 64;
                    for (int v = 0; v < 4; ++v) {
                        const int8x16_t xv = vld1q_s8(Ac + v * 16);
                        a0[v]              = vdotq_s32(a0[v], wb0, xv);
                        a1[v]              = vdotq_s32(a1[v], wb1, xv);
                    }
                }
                for (int v = 0; v < 4; ++v) {
                    const float32x4_t dx = vld1q_f32(D + (size_t) b * ORE_FB + v * 4);
                    s0[v]                = vfmaq_f32(s0[v], vcvtq_f32_s32(a0[v]), vmulq_n_f32(dx, dw0[b]));
                    s1[v]                = vfmaq_f32(s1[v], vcvtq_f32_s32(a1[v]), vmulq_n_f32(dx, dw1[b]));
                }
            }
            float o0[16], o1[16];
            for (int v = 0; v < 4; ++v) {
                vst1q_f32(o0 + v * 4, s0[v]);
                vst1q_f32(o1 + v * 4, s1[v]);
            }
            float * yr = y + (size_t) tb * ORE_FB * ystride + r;
            for (int f = 0; f < valid; ++f) {
                yr[(size_t) f * ystride] = o0[f];
                if (pair) yr[(size_t) f * ystride + 1] = o1[f];
            }
        }
    }
}

// ---- float product ----------------------------------------------------------

// Four weight rows against a block of sixteen frames: each weight is broadcast
// and multiplied into four vectors of frames, so every output accumulates in
// order of k.
static void gemm_f32_neon(const void * w, int w_is_f16, size_t wstride, int n_in, int r0, int r1, const float * xp,
                          int rows, float * y, size_t ystride, float * scratch) {
    const int ntb = ore_frame_blocks(rows);
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
        for (int tb = 0; tb < ntb; ++tb) {
            const float * xb = xp + (size_t) tb * n_in * ORE_FB;
            float32x4_t   c[4][4];
            for (int i = 0; i < 4; ++i) {
                for (int j = 0; j < 4; ++j) c[i][j] = vdupq_n_f32(0.0f);
            }
            for (int k = 0; k < n_in; ++k) {
                const float *     xk = xb + (size_t) k * ORE_FB;
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
            const int valid = ORE_MIN(ORE_FB, rows - tb * ORE_FB);
            for (int i = 0; i < nr; ++i) {
                float out[16];
                vst1q_f32(out, c[i][0]);
                vst1q_f32(out + 4, c[i][1]);
                vst1q_f32(out + 8, c[i][2]);
                vst1q_f32(out + 12, c[i][3]);
                float * yr = y + (size_t) tb * ORE_FB * ystride + r + i;
                for (int f = 0; f < valid; ++f) yr[(size_t) f * ystride] = out[f];
            }
        }
    }
}

const ore_kernels ore_kernels_neon = {
    "neon", quantize_q8k_neon, quantize_q80_neon, gemm_q4k_neon, gemm_q80_neon, gemm_f32_neon,
};

#endif  // ORE_ARM64
