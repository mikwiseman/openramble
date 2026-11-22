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

// One 16-frame block against two weight rows, in vectors of four frames (one
// function per number of vectors, so the last block of a clip does no more
// than it must). Four 4-bit weights are read straight from the model file,
// widened to bytes in a general register, broadcast, and dotted with four
// columns of every frame, so each lane of the accumulator is one frame's sum;
// the group scale is applied once per group, and nothing is ever added across
// a register. Every register has its own named variable, because GCC keeps
// small arrays of vectors in memory.
ORE_DOTPROD
static void q4k_block_neon_1(const uint8_t * w0, const uint8_t * w1, const ore_q4k_hdr * h0,
        const ore_q4k_hdr * h1, int nb, const int8_t * A, const int32_t * G, const float * D, float * o0,
        float * o1) {
    float32x4_t s00 = vdupq_n_f32(0.0f);
    float32x4_t s10 = vdupq_n_f32(0.0f);
    for (int b = 0; b < nb; ++b) {
        const uint8_t * q0 = w0 + (size_t) b * ORE_Q4K_BYTES + 16;
        const uint8_t * q1 = w1 + (size_t) b * ORE_Q4K_BYTES + 16;
        int32x4_t S00 = vdupq_n_s32(0);
        int32x4_t S10 = vdupq_n_s32(0);
        int32x4_t M00 = vdupq_n_s32(0);
        int32x4_t M10 = vdupq_n_s32(0);
        for (int g = 0; g < 8; ++g) {
            int32x4_t a00 = vdupq_n_s32(0);
            int32x4_t a10 = vdupq_n_s32(0);
            // Groups 2j and 2j + 1 are the low and high halves of the same 32 bytes.
            const uint8_t * p0 = q0 + (g >> 1) * 32;
            const uint8_t * p1 = q1 + (g >> 1) * 32;
            const int       sh = (g & 1) * 4;
            const int8_t *  Ag = A + ((size_t) b * 64 + (size_t) g * 8) * 64;
            for (int c = 0; c < 8; ++c) {
                uint32_t v0, v1;
                memcpy(&v0, p0 + 4 * c, 4);
                memcpy(&v1, p1 + 4 * c, 4);
                const int8x16_t wb0 = vreinterpretq_s8_u32(vdupq_n_u32(((v0 >> sh) & 0x0f0f0f0fu)));
                const int8x16_t wb1 = vreinterpretq_s8_u32(vdupq_n_u32(((v1 >> sh) & 0x0f0f0f0fu)));
                const int8x16_t x0 = vld1q_s8(Ag + c * 64);
                a00 = vdotq_s32(a00, wb0, x0);
                a10 = vdotq_s32(a10, wb1, x0);
            }
            const int32x4_t sc0 = vdupq_n_s32((int32_t) h0[b].sm[g]);
            const int32x4_t mn0 = vdupq_n_s32((int32_t) h0[b].sm[8 + g]);
            const int32x4_t sc1 = vdupq_n_s32((int32_t) h1[b].sm[g]);
            const int32x4_t mn1 = vdupq_n_s32((int32_t) h1[b].sm[8 + g]);
            const int32_t * Gg = G + ((size_t) b * 8 + g) * ORE_FB;
            const int32x4_t g0 = vld1q_s32(Gg);
            S00 = vmlaq_s32(S00, a00, sc0);
            M00 = vmlaq_s32(M00, g0, mn0);
            S10 = vmlaq_s32(S10, a10, sc1);
            M10 = vmlaq_s32(M10, g0, mn1);
        }
        const float * Db = D + (size_t) b * ORE_FB;
        const float32x4_t dx0 = vld1q_f32(Db);
        s00 = vfmsq_f32(s00, vmulq_n_f32(dx0, h0[b].dmin), vcvtq_f32_s32(M00));
        s00 = vfmaq_f32(s00, vmulq_n_f32(dx0, h0[b].d), vcvtq_f32_s32(S00));
        s10 = vfmsq_f32(s10, vmulq_n_f32(dx0, h1[b].dmin), vcvtq_f32_s32(M10));
        s10 = vfmaq_f32(s10, vmulq_n_f32(dx0, h1[b].d), vcvtq_f32_s32(S10));
    }
    vst1q_f32(o0, s00);
    vst1q_f32(o1, s10);
}

ORE_DOTPROD
static void q4k_block_neon_2(const uint8_t * w0, const uint8_t * w1, const ore_q4k_hdr * h0,
        const ore_q4k_hdr * h1, int nb, const int8_t * A, const int32_t * G, const float * D, float * o0,
        float * o1) {
    float32x4_t s00 = vdupq_n_f32(0.0f), s01 = vdupq_n_f32(0.0f);
    float32x4_t s10 = vdupq_n_f32(0.0f), s11 = vdupq_n_f32(0.0f);
    for (int b = 0; b < nb; ++b) {
        const uint8_t * q0 = w0 + (size_t) b * ORE_Q4K_BYTES + 16;
        const uint8_t * q1 = w1 + (size_t) b * ORE_Q4K_BYTES + 16;
        int32x4_t S00 = vdupq_n_s32(0), S01 = vdupq_n_s32(0);
        int32x4_t S10 = vdupq_n_s32(0), S11 = vdupq_n_s32(0);
        int32x4_t M00 = vdupq_n_s32(0), M01 = vdupq_n_s32(0);
        int32x4_t M10 = vdupq_n_s32(0), M11 = vdupq_n_s32(0);
        for (int g = 0; g < 8; ++g) {
            int32x4_t a00 = vdupq_n_s32(0), a01 = vdupq_n_s32(0);
            int32x4_t a10 = vdupq_n_s32(0), a11 = vdupq_n_s32(0);
            // Groups 2j and 2j + 1 are the low and high halves of the same 32 bytes.
            const uint8_t * p0 = q0 + (g >> 1) * 32;
            const uint8_t * p1 = q1 + (g >> 1) * 32;
            const int       sh = (g & 1) * 4;
            const int8_t *  Ag = A + ((size_t) b * 64 + (size_t) g * 8) * 64;
            for (int c = 0; c < 8; ++c) {
                uint32_t v0, v1;
                memcpy(&v0, p0 + 4 * c, 4);
                memcpy(&v1, p1 + 4 * c, 4);
                const int8x16_t wb0 = vreinterpretq_s8_u32(vdupq_n_u32(((v0 >> sh) & 0x0f0f0f0fu)));
                const int8x16_t wb1 = vreinterpretq_s8_u32(vdupq_n_u32(((v1 >> sh) & 0x0f0f0f0fu)));
                const int8x16_t x0 = vld1q_s8(Ag + c * 64);
                a00 = vdotq_s32(a00, wb0, x0);
                a10 = vdotq_s32(a10, wb1, x0);
                const int8x16_t x1 = vld1q_s8(Ag + c * 64 + 16);
                a01 = vdotq_s32(a01, wb0, x1);
                a11 = vdotq_s32(a11, wb1, x1);
            }
            const int32x4_t sc0 = vdupq_n_s32((int32_t) h0[b].sm[g]);
            const int32x4_t mn0 = vdupq_n_s32((int32_t) h0[b].sm[8 + g]);
            const int32x4_t sc1 = vdupq_n_s32((int32_t) h1[b].sm[g]);
            const int32x4_t mn1 = vdupq_n_s32((int32_t) h1[b].sm[8 + g]);
            const int32_t * Gg = G + ((size_t) b * 8 + g) * ORE_FB;
            const int32x4_t g0 = vld1q_s32(Gg);
            S00 = vmlaq_s32(S00, a00, sc0);
            M00 = vmlaq_s32(M00, g0, mn0);
            S10 = vmlaq_s32(S10, a10, sc1);
            M10 = vmlaq_s32(M10, g0, mn1);
            const int32x4_t g1 = vld1q_s32(Gg + 4);
            S01 = vmlaq_s32(S01, a01, sc0);
            M01 = vmlaq_s32(M01, g1, mn0);
            S11 = vmlaq_s32(S11, a11, sc1);
            M11 = vmlaq_s32(M11, g1, mn1);
        }
        const float * Db = D + (size_t) b * ORE_FB;
        const float32x4_t dx0 = vld1q_f32(Db);
        s00 = vfmsq_f32(s00, vmulq_n_f32(dx0, h0[b].dmin), vcvtq_f32_s32(M00));
        s00 = vfmaq_f32(s00, vmulq_n_f32(dx0, h0[b].d), vcvtq_f32_s32(S00));
        s10 = vfmsq_f32(s10, vmulq_n_f32(dx0, h1[b].dmin), vcvtq_f32_s32(M10));
        s10 = vfmaq_f32(s10, vmulq_n_f32(dx0, h1[b].d), vcvtq_f32_s32(S10));
        const float32x4_t dx1 = vld1q_f32(Db + 4);
        s01 = vfmsq_f32(s01, vmulq_n_f32(dx1, h0[b].dmin), vcvtq_f32_s32(M01));
        s01 = vfmaq_f32(s01, vmulq_n_f32(dx1, h0[b].d), vcvtq_f32_s32(S01));
        s11 = vfmsq_f32(s11, vmulq_n_f32(dx1, h1[b].dmin), vcvtq_f32_s32(M11));
        s11 = vfmaq_f32(s11, vmulq_n_f32(dx1, h1[b].d), vcvtq_f32_s32(S11));
    }
    vst1q_f32(o0, s00);
    vst1q_f32(o1, s10);
    vst1q_f32(o0 + 4, s01);
    vst1q_f32(o1 + 4, s11);
}

ORE_DOTPROD
static void q4k_block_neon_3(const uint8_t * w0, const uint8_t * w1, const ore_q4k_hdr * h0,
        const ore_q4k_hdr * h1, int nb, const int8_t * A, const int32_t * G, const float * D, float * o0,
        float * o1) {
    float32x4_t s00 = vdupq_n_f32(0.0f), s01 = vdupq_n_f32(0.0f), s02 = vdupq_n_f32(0.0f);
    float32x4_t s10 = vdupq_n_f32(0.0f), s11 = vdupq_n_f32(0.0f), s12 = vdupq_n_f32(0.0f);
    for (int b = 0; b < nb; ++b) {
        const uint8_t * q0 = w0 + (size_t) b * ORE_Q4K_BYTES + 16;
        const uint8_t * q1 = w1 + (size_t) b * ORE_Q4K_BYTES + 16;
        int32x4_t S00 = vdupq_n_s32(0), S01 = vdupq_n_s32(0), S02 = vdupq_n_s32(0);
        int32x4_t S10 = vdupq_n_s32(0), S11 = vdupq_n_s32(0), S12 = vdupq_n_s32(0);
        int32x4_t M00 = vdupq_n_s32(0), M01 = vdupq_n_s32(0), M02 = vdupq_n_s32(0);
        int32x4_t M10 = vdupq_n_s32(0), M11 = vdupq_n_s32(0), M12 = vdupq_n_s32(0);
        for (int g = 0; g < 8; ++g) {
            int32x4_t a00 = vdupq_n_s32(0), a01 = vdupq_n_s32(0), a02 = vdupq_n_s32(0);
            int32x4_t a10 = vdupq_n_s32(0), a11 = vdupq_n_s32(0), a12 = vdupq_n_s32(0);
            // Groups 2j and 2j + 1 are the low and high halves of the same 32 bytes.
            const uint8_t * p0 = q0 + (g >> 1) * 32;
            const uint8_t * p1 = q1 + (g >> 1) * 32;
            const int       sh = (g & 1) * 4;
            const int8_t *  Ag = A + ((size_t) b * 64 + (size_t) g * 8) * 64;
            for (int c = 0; c < 8; ++c) {
                uint32_t v0, v1;
                memcpy(&v0, p0 + 4 * c, 4);
                memcpy(&v1, p1 + 4 * c, 4);
                const int8x16_t wb0 = vreinterpretq_s8_u32(vdupq_n_u32(((v0 >> sh) & 0x0f0f0f0fu)));
                const int8x16_t wb1 = vreinterpretq_s8_u32(vdupq_n_u32(((v1 >> sh) & 0x0f0f0f0fu)));
                const int8x16_t x0 = vld1q_s8(Ag + c * 64);
                a00 = vdotq_s32(a00, wb0, x0);
                a10 = vdotq_s32(a10, wb1, x0);
                const int8x16_t x1 = vld1q_s8(Ag + c * 64 + 16);
                a01 = vdotq_s32(a01, wb0, x1);
                a11 = vdotq_s32(a11, wb1, x1);
                const int8x16_t x2 = vld1q_s8(Ag + c * 64 + 32);
                a02 = vdotq_s32(a02, wb0, x2);
                a12 = vdotq_s32(a12, wb1, x2);
            }
            const int32x4_t sc0 = vdupq_n_s32((int32_t) h0[b].sm[g]);
            const int32x4_t mn0 = vdupq_n_s32((int32_t) h0[b].sm[8 + g]);
            const int32x4_t sc1 = vdupq_n_s32((int32_t) h1[b].sm[g]);
            const int32x4_t mn1 = vdupq_n_s32((int32_t) h1[b].sm[8 + g]);
            const int32_t * Gg = G + ((size_t) b * 8 + g) * ORE_FB;
            const int32x4_t g0 = vld1q_s32(Gg);
            S00 = vmlaq_s32(S00, a00, sc0);
            M00 = vmlaq_s32(M00, g0, mn0);
            S10 = vmlaq_s32(S10, a10, sc1);
            M10 = vmlaq_s32(M10, g0, mn1);
            const int32x4_t g1 = vld1q_s32(Gg + 4);
            S01 = vmlaq_s32(S01, a01, sc0);
            M01 = vmlaq_s32(M01, g1, mn0);
            S11 = vmlaq_s32(S11, a11, sc1);
            M11 = vmlaq_s32(M11, g1, mn1);
            const int32x4_t g2 = vld1q_s32(Gg + 8);
            S02 = vmlaq_s32(S02, a02, sc0);
            M02 = vmlaq_s32(M02, g2, mn0);
            S12 = vmlaq_s32(S12, a12, sc1);
            M12 = vmlaq_s32(M12, g2, mn1);
        }
        const float * Db = D + (size_t) b * ORE_FB;
        const float32x4_t dx0 = vld1q_f32(Db);
        s00 = vfmsq_f32(s00, vmulq_n_f32(dx0, h0[b].dmin), vcvtq_f32_s32(M00));
        s00 = vfmaq_f32(s00, vmulq_n_f32(dx0, h0[b].d), vcvtq_f32_s32(S00));
        s10 = vfmsq_f32(s10, vmulq_n_f32(dx0, h1[b].dmin), vcvtq_f32_s32(M10));
        s10 = vfmaq_f32(s10, vmulq_n_f32(dx0, h1[b].d), vcvtq_f32_s32(S10));
        const float32x4_t dx1 = vld1q_f32(Db + 4);
        s01 = vfmsq_f32(s01, vmulq_n_f32(dx1, h0[b].dmin), vcvtq_f32_s32(M01));
        s01 = vfmaq_f32(s01, vmulq_n_f32(dx1, h0[b].d), vcvtq_f32_s32(S01));
        s11 = vfmsq_f32(s11, vmulq_n_f32(dx1, h1[b].dmin), vcvtq_f32_s32(M11));
        s11 = vfmaq_f32(s11, vmulq_n_f32(dx1, h1[b].d), vcvtq_f32_s32(S11));
        const float32x4_t dx2 = vld1q_f32(Db + 8);
        s02 = vfmsq_f32(s02, vmulq_n_f32(dx2, h0[b].dmin), vcvtq_f32_s32(M02));
        s02 = vfmaq_f32(s02, vmulq_n_f32(dx2, h0[b].d), vcvtq_f32_s32(S02));
        s12 = vfmsq_f32(s12, vmulq_n_f32(dx2, h1[b].dmin), vcvtq_f32_s32(M12));
        s12 = vfmaq_f32(s12, vmulq_n_f32(dx2, h1[b].d), vcvtq_f32_s32(S12));
    }
    vst1q_f32(o0, s00);
    vst1q_f32(o1, s10);
    vst1q_f32(o0 + 4, s01);
    vst1q_f32(o1 + 4, s11);
    vst1q_f32(o0 + 8, s02);
    vst1q_f32(o1 + 8, s12);
}

ORE_DOTPROD
static void q4k_block_neon_4(const uint8_t * w0, const uint8_t * w1, const ore_q4k_hdr * h0,
        const ore_q4k_hdr * h1, int nb, const int8_t * A, const int32_t * G, const float * D, float * o0,
        float * o1) {
    float32x4_t s00 = vdupq_n_f32(0.0f), s01 = vdupq_n_f32(0.0f), s02 = vdupq_n_f32(0.0f), s03 = vdupq_n_f32(0.0f);
    float32x4_t s10 = vdupq_n_f32(0.0f), s11 = vdupq_n_f32(0.0f), s12 = vdupq_n_f32(0.0f), s13 = vdupq_n_f32(0.0f);
    for (int b = 0; b < nb; ++b) {
        const uint8_t * q0 = w0 + (size_t) b * ORE_Q4K_BYTES + 16;
        const uint8_t * q1 = w1 + (size_t) b * ORE_Q4K_BYTES + 16;
        int32x4_t S00 = vdupq_n_s32(0), S01 = vdupq_n_s32(0), S02 = vdupq_n_s32(0), S03 = vdupq_n_s32(0);
        int32x4_t S10 = vdupq_n_s32(0), S11 = vdupq_n_s32(0), S12 = vdupq_n_s32(0), S13 = vdupq_n_s32(0);
        int32x4_t M00 = vdupq_n_s32(0), M01 = vdupq_n_s32(0), M02 = vdupq_n_s32(0), M03 = vdupq_n_s32(0);
        int32x4_t M10 = vdupq_n_s32(0), M11 = vdupq_n_s32(0), M12 = vdupq_n_s32(0), M13 = vdupq_n_s32(0);
        for (int g = 0; g < 8; ++g) {
            int32x4_t a00 = vdupq_n_s32(0), a01 = vdupq_n_s32(0), a02 = vdupq_n_s32(0), a03 = vdupq_n_s32(0);
            int32x4_t a10 = vdupq_n_s32(0), a11 = vdupq_n_s32(0), a12 = vdupq_n_s32(0), a13 = vdupq_n_s32(0);
            // Groups 2j and 2j + 1 are the low and high halves of the same 32 bytes.
            const uint8_t * p0 = q0 + (g >> 1) * 32;
            const uint8_t * p1 = q1 + (g >> 1) * 32;
            const int       sh = (g & 1) * 4;
            const int8_t *  Ag = A + ((size_t) b * 64 + (size_t) g * 8) * 64;
            for (int c = 0; c < 8; ++c) {
                uint32_t v0, v1;
                memcpy(&v0, p0 + 4 * c, 4);
                memcpy(&v1, p1 + 4 * c, 4);
                const int8x16_t wb0 = vreinterpretq_s8_u32(vdupq_n_u32(((v0 >> sh) & 0x0f0f0f0fu)));
                const int8x16_t wb1 = vreinterpretq_s8_u32(vdupq_n_u32(((v1 >> sh) & 0x0f0f0f0fu)));
                const int8x16_t x0 = vld1q_s8(Ag + c * 64);
                a00 = vdotq_s32(a00, wb0, x0);
                a10 = vdotq_s32(a10, wb1, x0);
                const int8x16_t x1 = vld1q_s8(Ag + c * 64 + 16);
                a01 = vdotq_s32(a01, wb0, x1);
                a11 = vdotq_s32(a11, wb1, x1);
                const int8x16_t x2 = vld1q_s8(Ag + c * 64 + 32);
                a02 = vdotq_s32(a02, wb0, x2);
                a12 = vdotq_s32(a12, wb1, x2);
                const int8x16_t x3 = vld1q_s8(Ag + c * 64 + 48);
                a03 = vdotq_s32(a03, wb0, x3);
                a13 = vdotq_s32(a13, wb1, x3);
            }
            const int32x4_t sc0 = vdupq_n_s32((int32_t) h0[b].sm[g]);
            const int32x4_t mn0 = vdupq_n_s32((int32_t) h0[b].sm[8 + g]);
            const int32x4_t sc1 = vdupq_n_s32((int32_t) h1[b].sm[g]);
            const int32x4_t mn1 = vdupq_n_s32((int32_t) h1[b].sm[8 + g]);
            const int32_t * Gg = G + ((size_t) b * 8 + g) * ORE_FB;
            const int32x4_t g0 = vld1q_s32(Gg);
            S00 = vmlaq_s32(S00, a00, sc0);
            M00 = vmlaq_s32(M00, g0, mn0);
            S10 = vmlaq_s32(S10, a10, sc1);
            M10 = vmlaq_s32(M10, g0, mn1);
            const int32x4_t g1 = vld1q_s32(Gg + 4);
            S01 = vmlaq_s32(S01, a01, sc0);
            M01 = vmlaq_s32(M01, g1, mn0);
            S11 = vmlaq_s32(S11, a11, sc1);
            M11 = vmlaq_s32(M11, g1, mn1);
            const int32x4_t g2 = vld1q_s32(Gg + 8);
            S02 = vmlaq_s32(S02, a02, sc0);
            M02 = vmlaq_s32(M02, g2, mn0);
            S12 = vmlaq_s32(S12, a12, sc1);
            M12 = vmlaq_s32(M12, g2, mn1);
            const int32x4_t g3 = vld1q_s32(Gg + 12);
            S03 = vmlaq_s32(S03, a03, sc0);
            M03 = vmlaq_s32(M03, g3, mn0);
            S13 = vmlaq_s32(S13, a13, sc1);
            M13 = vmlaq_s32(M13, g3, mn1);
        }
        const float * Db = D + (size_t) b * ORE_FB;
        const float32x4_t dx0 = vld1q_f32(Db);
        s00 = vfmsq_f32(s00, vmulq_n_f32(dx0, h0[b].dmin), vcvtq_f32_s32(M00));
        s00 = vfmaq_f32(s00, vmulq_n_f32(dx0, h0[b].d), vcvtq_f32_s32(S00));
        s10 = vfmsq_f32(s10, vmulq_n_f32(dx0, h1[b].dmin), vcvtq_f32_s32(M10));
        s10 = vfmaq_f32(s10, vmulq_n_f32(dx0, h1[b].d), vcvtq_f32_s32(S10));
        const float32x4_t dx1 = vld1q_f32(Db + 4);
        s01 = vfmsq_f32(s01, vmulq_n_f32(dx1, h0[b].dmin), vcvtq_f32_s32(M01));
        s01 = vfmaq_f32(s01, vmulq_n_f32(dx1, h0[b].d), vcvtq_f32_s32(S01));
        s11 = vfmsq_f32(s11, vmulq_n_f32(dx1, h1[b].dmin), vcvtq_f32_s32(M11));
        s11 = vfmaq_f32(s11, vmulq_n_f32(dx1, h1[b].d), vcvtq_f32_s32(S11));
        const float32x4_t dx2 = vld1q_f32(Db + 8);
        s02 = vfmsq_f32(s02, vmulq_n_f32(dx2, h0[b].dmin), vcvtq_f32_s32(M02));
        s02 = vfmaq_f32(s02, vmulq_n_f32(dx2, h0[b].d), vcvtq_f32_s32(S02));
        s12 = vfmsq_f32(s12, vmulq_n_f32(dx2, h1[b].dmin), vcvtq_f32_s32(M12));
        s12 = vfmaq_f32(s12, vmulq_n_f32(dx2, h1[b].d), vcvtq_f32_s32(S12));
        const float32x4_t dx3 = vld1q_f32(Db + 12);
        s03 = vfmsq_f32(s03, vmulq_n_f32(dx3, h0[b].dmin), vcvtq_f32_s32(M03));
        s03 = vfmaq_f32(s03, vmulq_n_f32(dx3, h0[b].d), vcvtq_f32_s32(S03));
        s13 = vfmsq_f32(s13, vmulq_n_f32(dx3, h1[b].dmin), vcvtq_f32_s32(M13));
        s13 = vfmaq_f32(s13, vmulq_n_f32(dx3, h1[b].d), vcvtq_f32_s32(S13));
    }
    vst1q_f32(o0, s00);
    vst1q_f32(o1, s10);
    vst1q_f32(o0 + 4, s01);
    vst1q_f32(o1 + 4, s11);
    vst1q_f32(o0 + 8, s02);
    vst1q_f32(o1 + 8, s12);
    vst1q_f32(o0 + 12, s03);
    vst1q_f32(o1 + 12, s13);
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
        ore_q4k_decode_row(w0, nb, h0);
        ore_q4k_decode_row(w1, nb, h1);
        for (int tb = 0; tb < x->ntb; ++tb) {
            const int       valid = ORE_MIN(ORE_FB, x->rows - tb * ORE_FB);
            const int8_t *  A     = x->q + (size_t) tb * n4 * 64;
            const int32_t * G     = x->gs + (size_t) tb * nb * 8 * ORE_FB;
            const float *   D     = x->d + (size_t) tb * nb * ORE_FB;
            float           o0[16], o1[16];
            switch ((valid + 3) / 4) {
                case 1: q4k_block_neon_1(w0, w1, h0, h1, nb, A, G, D, o0, o1); break;
                case 2: q4k_block_neon_2(w0, w1, h0, h1, nb, A, G, D, o0, o1); break;
                case 3: q4k_block_neon_3(w0, w1, h0, h1, nb, A, G, D, o0, o1); break;
                default: q4k_block_neon_4(w0, w1, h0, h1, nb, A, G, D, o0, o1); break;
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

// Two weight rows against a block of 16 frames. Four 8-bit weights are read
// from the model file and broadcast; each lane of the sum is one frame.
ORE_DOTPROD
static void gemm_q80_neon(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y, size_t ystride) {
    const int    nb = n_in / 32;
    const size_t rb = (size_t) nb * ORE_Q80_BYTES;
    const size_t n4 = (size_t) n_in / 4;
    for (int r = r0; r < r1; r += 2) {
        const int       pair = r + 1 < r1;
        const uint8_t * w0   = w + (size_t) r * rb;
        const uint8_t * w1   = pair ? w0 + rb : w0;
        for (int tb = 0; tb < x->ntb; ++tb) {
            const int      valid = ORE_MIN(ORE_FB, x->rows - tb * ORE_FB);
            const int8_t * A     = x->q + (size_t) tb * n4 * 64;
            const float *  D     = x->d + (size_t) tb * nb * ORE_FB;
            float32x4_t s00 = vdupq_n_f32(0.0f), s01 = vdupq_n_f32(0.0f), s02 = vdupq_n_f32(0.0f), s03 = vdupq_n_f32(0.0f);
            float32x4_t s10 = vdupq_n_f32(0.0f), s11 = vdupq_n_f32(0.0f), s12 = vdupq_n_f32(0.0f), s13 = vdupq_n_f32(0.0f);
            for (int b = 0; b < nb; ++b) {
                const uint8_t * k0 = w0 + (size_t) b * ORE_Q80_BYTES;
                const uint8_t * k1 = w1 + (size_t) b * ORE_Q80_BYTES;
                int32x4_t a00 = vdupq_n_s32(0), a01 = vdupq_n_s32(0), a02 = vdupq_n_s32(0), a03 = vdupq_n_s32(0);
                int32x4_t a10 = vdupq_n_s32(0), a11 = vdupq_n_s32(0), a12 = vdupq_n_s32(0), a13 = vdupq_n_s32(0);
                for (int c = 0; c < 8; ++c) {
                    const int8_t * Ac = A + ((size_t) b * 8 + c) * 64;
                    uint32_t       v0, v1;
                    memcpy(&v0, k0 + 2 + 4 * c, 4);
                    memcpy(&v1, k1 + 2 + 4 * c, 4);
                    const int8x16_t wb0 = vreinterpretq_s8_u32(vdupq_n_u32(v0));
                    const int8x16_t wb1 = vreinterpretq_s8_u32(vdupq_n_u32(v1));
                    const int8x16_t x0 = vld1q_s8(Ac);
                    a00 = vdotq_s32(a00, wb0, x0);
                    a10 = vdotq_s32(a10, wb1, x0);
                    const int8x16_t x1 = vld1q_s8(Ac + 16);
                    a01 = vdotq_s32(a01, wb0, x1);
                    a11 = vdotq_s32(a11, wb1, x1);
                    const int8x16_t x2 = vld1q_s8(Ac + 32);
                    a02 = vdotq_s32(a02, wb0, x2);
                    a12 = vdotq_s32(a12, wb1, x2);
                    const int8x16_t x3 = vld1q_s8(Ac + 48);
                    a03 = vdotq_s32(a03, wb0, x3);
                    a13 = vdotq_s32(a13, wb1, x3);
                }
                const float   dw0 = ore_f16_to_f32(ore_rd16(k0)), dw1 = ore_f16_to_f32(ore_rd16(k1));
                const float * Db  = D + (size_t) b * ORE_FB;
                const float32x4_t dx0 = vld1q_f32(Db);
                s00 = vfmaq_f32(s00, vcvtq_f32_s32(a00), vmulq_n_f32(dx0, dw0));
                s10 = vfmaq_f32(s10, vcvtq_f32_s32(a10), vmulq_n_f32(dx0, dw1));
                const float32x4_t dx1 = vld1q_f32(Db + 4);
                s01 = vfmaq_f32(s01, vcvtq_f32_s32(a01), vmulq_n_f32(dx1, dw0));
                s11 = vfmaq_f32(s11, vcvtq_f32_s32(a11), vmulq_n_f32(dx1, dw1));
                const float32x4_t dx2 = vld1q_f32(Db + 8);
                s02 = vfmaq_f32(s02, vcvtq_f32_s32(a02), vmulq_n_f32(dx2, dw0));
                s12 = vfmaq_f32(s12, vcvtq_f32_s32(a12), vmulq_n_f32(dx2, dw1));
                const float32x4_t dx3 = vld1q_f32(Db + 12);
                s03 = vfmaq_f32(s03, vcvtq_f32_s32(a03), vmulq_n_f32(dx3, dw0));
                s13 = vfmaq_f32(s13, vcvtq_f32_s32(a13), vmulq_n_f32(dx3, dw1));
            }
            float o0[16], o1[16];
            vst1q_f32(o0, s00);
            vst1q_f32(o1, s10);
            vst1q_f32(o0 + 4, s01);
            vst1q_f32(o1 + 4, s11);
            vst1q_f32(o0 + 8, s02);
            vst1q_f32(o1 + 8, s12);
            vst1q_f32(o0 + 12, s03);
            vst1q_f32(o1 + 12, s13);
            float * yr = y + (size_t) tb * ORE_FB * ystride + r;
            for (int f = 0; f < valid; ++f) {
                yr[(size_t) f * ystride] = o0[f];
                if (pair) yr[(size_t) f * ystride + 1] = o1[f];
            }
        }
    }
}

// ---- float product ----------------------------------------------------------

// Six weight rows against a block of sixteen frames: each weight is broadcast
// and multiplied into four vectors of frames, so every output accumulates in
// order of k. Twenty-four independent sums keep all the multiply-add units
// busy.
#define ORE_F32_ROWS 6
static void gemm_f32_neon(const void * w, int w_is_f16, size_t wstride, int n_in, int r0, int r1, const float * xp,
                          int rows, float * y, size_t ystride, float * scratch) {
    const int ntb = ore_frame_blocks(rows);
    for (int r = r0; r < r1; r += ORE_F32_ROWS) {
        const int     nr = ORE_MIN(ORE_F32_ROWS, r1 - r);
        const float * wr[ORE_F32_ROWS];
        for (int i = 0; i < ORE_F32_ROWS; ++i) {
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
        const float * w0 = wr[0], *w1 = wr[1], *w2 = wr[2], *w3 = wr[3], *w4 = wr[4], *w5 = wr[5];
        for (int tb = 0; tb < ntb; ++tb) {
            const float * xb = xp + (size_t) tb * n_in * ORE_FB;
            float32x4_t c00 = vdupq_n_f32(0.0f), c01 = vdupq_n_f32(0.0f), c02 = vdupq_n_f32(0.0f), c03 = vdupq_n_f32(0.0f);
            float32x4_t c10 = vdupq_n_f32(0.0f), c11 = vdupq_n_f32(0.0f), c12 = vdupq_n_f32(0.0f), c13 = vdupq_n_f32(0.0f);
            float32x4_t c20 = vdupq_n_f32(0.0f), c21 = vdupq_n_f32(0.0f), c22 = vdupq_n_f32(0.0f), c23 = vdupq_n_f32(0.0f);
            float32x4_t c30 = vdupq_n_f32(0.0f), c31 = vdupq_n_f32(0.0f), c32 = vdupq_n_f32(0.0f), c33 = vdupq_n_f32(0.0f);
            float32x4_t c40 = vdupq_n_f32(0.0f), c41 = vdupq_n_f32(0.0f), c42 = vdupq_n_f32(0.0f), c43 = vdupq_n_f32(0.0f);
            float32x4_t c50 = vdupq_n_f32(0.0f), c51 = vdupq_n_f32(0.0f), c52 = vdupq_n_f32(0.0f), c53 = vdupq_n_f32(0.0f);
            for (int k = 0; k < n_in; ++k) {
                const float * xk = xb + (size_t) k * ORE_FB;
                const float32x4_t x0 = vld1q_f32(xk);
                const float32x4_t x1 = vld1q_f32(xk + 4);
                const float32x4_t x2 = vld1q_f32(xk + 8);
                const float32x4_t x3 = vld1q_f32(xk + 12);
                const float32x4_t v0 = vld1q_dup_f32(w0 + k);
                c00 = vfmaq_f32(c00, v0, x0);
                c01 = vfmaq_f32(c01, v0, x1);
                c02 = vfmaq_f32(c02, v0, x2);
                c03 = vfmaq_f32(c03, v0, x3);
                const float32x4_t v1 = vld1q_dup_f32(w1 + k);
                c10 = vfmaq_f32(c10, v1, x0);
                c11 = vfmaq_f32(c11, v1, x1);
                c12 = vfmaq_f32(c12, v1, x2);
                c13 = vfmaq_f32(c13, v1, x3);
                const float32x4_t v2 = vld1q_dup_f32(w2 + k);
                c20 = vfmaq_f32(c20, v2, x0);
                c21 = vfmaq_f32(c21, v2, x1);
                c22 = vfmaq_f32(c22, v2, x2);
                c23 = vfmaq_f32(c23, v2, x3);
                const float32x4_t v3 = vld1q_dup_f32(w3 + k);
                c30 = vfmaq_f32(c30, v3, x0);
                c31 = vfmaq_f32(c31, v3, x1);
                c32 = vfmaq_f32(c32, v3, x2);
                c33 = vfmaq_f32(c33, v3, x3);
                const float32x4_t v4 = vld1q_dup_f32(w4 + k);
                c40 = vfmaq_f32(c40, v4, x0);
                c41 = vfmaq_f32(c41, v4, x1);
                c42 = vfmaq_f32(c42, v4, x2);
                c43 = vfmaq_f32(c43, v4, x3);
                const float32x4_t v5 = vld1q_dup_f32(w5 + k);
                c50 = vfmaq_f32(c50, v5, x0);
                c51 = vfmaq_f32(c51, v5, x1);
                c52 = vfmaq_f32(c52, v5, x2);
                c53 = vfmaq_f32(c53, v5, x3);
            }
            const int valid = ORE_MIN(ORE_FB, rows - tb * ORE_FB);
            float     out[6][16];
            vst1q_f32(out[0], c00);
            vst1q_f32(out[0] + 4, c01);
            vst1q_f32(out[0] + 8, c02);
            vst1q_f32(out[0] + 12, c03);
            vst1q_f32(out[1], c10);
            vst1q_f32(out[1] + 4, c11);
            vst1q_f32(out[1] + 8, c12);
            vst1q_f32(out[1] + 12, c13);
            vst1q_f32(out[2], c20);
            vst1q_f32(out[2] + 4, c21);
            vst1q_f32(out[2] + 8, c22);
            vst1q_f32(out[2] + 12, c23);
            vst1q_f32(out[3], c30);
            vst1q_f32(out[3] + 4, c31);
            vst1q_f32(out[3] + 8, c32);
            vst1q_f32(out[3] + 12, c33);
            vst1q_f32(out[4], c40);
            vst1q_f32(out[4] + 4, c41);
            vst1q_f32(out[4] + 8, c42);
            vst1q_f32(out[4] + 12, c43);
            vst1q_f32(out[5], c50);
            vst1q_f32(out[5] + 4, c51);
            vst1q_f32(out[5] + 8, c52);
            vst1q_f32(out[5] + 12, c53);
            for (int i = 0; i < nr; ++i) {
                float * yr = y + (size_t) tb * ORE_FB * ystride + r + i;
                for (int f = 0; f < valid; ++f) yr[(size_t) f * ystride] = out[i][f];
            }
        }
    }
}

// ---- element-wise steps -------------------------------------------------------

// exp, four at a time: ore_expf's operations (see ore_base.h).
ORE_INLINE float32x4_t vexp(float32x4_t x) {
    const float32x4_t r = vdupq_n_f32(0x1.8p23f);
    const float32x4_t z = vfmaq_f32(r, x, vdupq_n_f32(0x1.715476p+0f));
    const float32x4_t n = vsubq_f32(z, r);
    const float32x4_t b =
        vfmsq_f32(vfmsq_f32(x, n, vdupq_n_f32(0x1.62e4p-1f)), n, vdupq_n_f32(0x1.7f7d1cp-20f));
    const uint32x4_t  e = vshlq_n_u32(vreinterpretq_u32_f32(z), 23);
    const float32x4_t k = vreinterpretq_f32_u32(vaddq_u32(e, vreinterpretq_u32_f32(vdupq_n_f32(1))));
    const uint32x4_t  c = vcagtq_f32(n, vdupq_n_f32(126));
    const float32x4_t u = vmulq_f32(b, b);
    const float32x4_t j = vfmaq_f32(vmulq_f32(vdupq_n_f32(0x1.ffffecp-1f), b),
                                    vfmaq_f32(vfmaq_f32(vdupq_n_f32(0x1.fffdb6p-2f), vdupq_n_f32(0x1.555e66p-3f), b),
                                              vfmaq_f32(vdupq_n_f32(0x1.573e2ep-5f), vdupq_n_f32(0x1.0e4020p-7f), b), u),
                                    u);
    if (!vmaxvq_u32(c)) return vfmaq_f32(k, j, k);
    const uint32x4_t  d  = vandq_u32(vclezq_f32(n), vdupq_n_u32(0x82000000));
    const float32x4_t s1 = vreinterpretq_f32_u32(vaddq_u32(d, vdupq_n_u32(0x7f000000)));
    const float32x4_t s2 = vreinterpretq_f32_u32(vsubq_u32(e, d));
    return vbslq_f32(vcagtq_f32(n, vdupq_n_f32(192)), vmulq_f32(s1, s1),
                     vbslq_f32(c, vmulq_f32(vfmaq_f32(s2, s2, j), s1), vfmaq_f32(k, j, k)));
}

ORE_INLINE float32x4_t vsilu(float32x4_t x) {
    return vdivq_f32(x, vaddq_f32(vdupq_n_f32(1.0f), vexp(vsubq_f32(vdupq_n_f32(0.0f), x))));
}

// Lanes 0-3, 4-7, 8-11, 12-15 -> the pairwise sum the reference defines.
ORE_INLINE float sum16v(float32x4_t a, float32x4_t b, float32x4_t c, float32x4_t d) {
    const float32x4_t t4 = vaddq_f32(vaddq_f32(a, c), vaddq_f32(b, d));  // (l + l+8) then (l + l+4)
    const float32x2_t t2 = vadd_f32(vget_low_f32(t4), vget_high_f32(t4));
    return vget_lane_f32(t2, 0) + vget_lane_f32(t2, 1);
}

static void layer_norm_neon(const float * x, float * y, int n, const float * gamma, const float * beta, float eps) {
    float32x4_t s0 = vdupq_n_f32(0), s1 = s0, s2 = s0, s3 = s0;
    int         i = 0;
    for (; i + 16 <= n; i += 16) {
        s0 = vaddq_f32(s0, vld1q_f32(x + i));
        s1 = vaddq_f32(s1, vld1q_f32(x + i + 4));
        s2 = vaddq_f32(s2, vld1q_f32(x + i + 8));
        s3 = vaddq_f32(s3, vld1q_f32(x + i + 12));
    }
    float tail[16] = { 0 };
    for (int j = 0; i + j < n; ++j) tail[j] = x[i + j];
    s0 = vaddq_f32(s0, vld1q_f32(tail));
    s1 = vaddq_f32(s1, vld1q_f32(tail + 4));
    s2 = vaddq_f32(s2, vld1q_f32(tail + 8));
    s3 = vaddq_f32(s3, vld1q_f32(tail + 12));
    const float       mean = sum16v(s0, s1, s2, s3) / (float) n;
    const float32x4_t vm   = vdupq_n_f32(mean);
    float32x4_t       v0 = vdupq_n_f32(0), v1 = v0, v2 = v0, v3 = v0;
    for (i = 0; i + 16 <= n; i += 16) {
        const float32x4_t d0 = vsubq_f32(vld1q_f32(x + i), vm), d1 = vsubq_f32(vld1q_f32(x + i + 4), vm);
        const float32x4_t d2 = vsubq_f32(vld1q_f32(x + i + 8), vm), d3 = vsubq_f32(vld1q_f32(x + i + 12), vm);
        v0 = vfmaq_f32(v0, d0, d0);
        v1 = vfmaq_f32(v1, d1, d1);
        v2 = vfmaq_f32(v2, d2, d2);
        v3 = vfmaq_f32(v3, d3, d3);
    }
    float vt[16] = { 0 };
    for (int j = 0; i + j < n; ++j) {
        const float d = x[i + j] - mean;
        vt[j]         = d;
    }
    {
        // d * d + 0 fused is d * d rounded once, which is what the lanes hold
        const float32x4_t d0 = vld1q_f32(vt), d1 = vld1q_f32(vt + 4), d2 = vld1q_f32(vt + 8), d3 = vld1q_f32(vt + 12);
        v0 = vfmaq_f32(v0, d0, d0);
        v1 = vfmaq_f32(v1, d1, d1);
        v2 = vfmaq_f32(v2, d2, d2);
        v3 = vfmaq_f32(v3, d3, d3);
    }
    const float       var   = sum16v(v0, v1, v2, v3) / (float) n;
    const float       scale = 1.0f / sqrtf(var + eps);
    const float32x4_t vs    = vdupq_n_f32(scale);
    for (i = 0; i + 4 <= n; i += 4) {
        const float32x4_t d = vsubq_f32(vld1q_f32(x + i), vm);
        vst1q_f32(y + i, vaddq_f32(vmulq_f32(vmulq_f32(d, vs), vld1q_f32(gamma + i)), vld1q_f32(beta + i)));
    }
    for (; i < n; ++i) {
        const float d = x[i] - mean;
        const float t = (d * scale) * gamma[i];
        y[i]          = t + beta[i];
    }
}

static void silu_neon(float * x, size_t n) {
    size_t i = 0;
    for (; i + 4 <= n; i += 4) vst1q_f32(x + i, vsilu(vld1q_f32(x + i)));
    for (; i < n; ++i) x[i] = x[i] / (1.0f + ore_expf(0.0f - x[i]));
}

static void glu_neon(const float * a, const float * b, float * out, size_t n) {
    size_t            i    = 0;
    const float32x4_t one  = vdupq_n_f32(1.0f);
    const float32x4_t zero = vdupq_n_f32(0.0f);
    for (; i + 4 <= n; i += 4) {
        const float32x4_t sig = vdivq_f32(one, vaddq_f32(one, vexp(vsubq_f32(zero, vld1q_f32(b + i)))));
        vst1q_f32(out + i, vmulq_f32(vld1q_f32(a + i), sig));
    }
    for (; i < n; ++i) out[i] = a[i] * (1.0f / (1.0f + ore_expf(0.0f - b[i])));
}

static void softmax_neon(float * s, int n) {
    float mx = s[0];
    int   i  = 0;
    if (n >= 4) {
        float32x4_t m = vld1q_f32(s);
        for (i = 4; i + 4 <= n; i += 4) m = vmaxq_f32(m, vld1q_f32(s + i));
        mx = vmaxvq_f32(m);
    }
    for (; i < n; ++i) {
        if (s[i] > mx) mx = s[i];
    }
    const float32x4_t vmx = vdupq_n_f32(mx);
    float32x4_t       a0 = vdupq_n_f32(0), a1 = a0, a2 = a0, a3 = a0;
    for (i = 0; i + 16 <= n; i += 16) {
        const float32x4_t e0 = vexp(vsubq_f32(vld1q_f32(s + i), vmx));
        const float32x4_t e1 = vexp(vsubq_f32(vld1q_f32(s + i + 4), vmx));
        const float32x4_t e2 = vexp(vsubq_f32(vld1q_f32(s + i + 8), vmx));
        const float32x4_t e3 = vexp(vsubq_f32(vld1q_f32(s + i + 12), vmx));
        vst1q_f32(s + i, e0);
        vst1q_f32(s + i + 4, e1);
        vst1q_f32(s + i + 8, e2);
        vst1q_f32(s + i + 12, e3);
        a0 = vaddq_f32(a0, e0);
        a1 = vaddq_f32(a1, e1);
        a2 = vaddq_f32(a2, e2);
        a3 = vaddq_f32(a3, e3);
    }
    float tail[16] = { 0 };
    for (int j = 0; i + j < n; ++j) {
        s[i + j] = ore_expf(s[i + j] - mx);
        tail[j]  = s[i + j];
    }
    a0 = vaddq_f32(a0, vld1q_f32(tail));
    a1 = vaddq_f32(a1, vld1q_f32(tail + 4));
    a2 = vaddq_f32(a2, vld1q_f32(tail + 8));
    a3 = vaddq_f32(a3, vld1q_f32(tail + 12));
    const float       inv  = 1.0f / sum16v(a0, a1, a2, a3);
    const float32x4_t vinv = vdupq_n_f32(inv);
    for (i = 0; i + 4 <= n; i += 4) vst1q_f32(s + i, vmulq_f32(vld1q_f32(s + i), vinv));
    for (; i < n; ++i) s[i] = s[i] * inv;
}

static void dwconv_bn_silu_neon(const float * const * taps, const float * w, int k, int n, const float * scale,
                                const float * bias, float * out) {
    int c = 0;
    for (; c + 4 <= n; c += 4) {
        float32x4_t acc = vdupq_n_f32(0.0f);
        for (int j = 0; j < k; ++j) {
            if (taps[j]) acc = vfmaq_f32(acc, vld1q_f32(w + (size_t) j * n + c), vld1q_f32(taps[j] + c));
        }
        const float32x4_t u = vaddq_f32(vmulq_f32(acc, vld1q_f32(scale + c)), vld1q_f32(bias + c));
        vst1q_f32(out + c, vsilu(u));
    }
    for (; c < n; ++c) {
        float acc = 0.0f;
        for (int j = 0; j < k; ++j) {
            if (taps[j]) acc = fmaf(w[(size_t) j * n + c], taps[j][c], acc);
        }
        const float t = acc * scale[c];
        const float u = t + bias[c];
        out[c]        = u / (1.0f + ore_expf(0.0f - u));
    }
}

static void dwconv_bias_neon(const float * const * taps, const float * w, int k, int n, const float * bias,
                             float * out) {
    int c = 0;
    for (; c + 4 <= n; c += 4) {
        float32x4_t acc = vdupq_n_f32(0.0f);
        for (int j = 0; j < k; ++j) {
            if (taps[j]) acc = vfmaq_f32(acc, vld1q_f32(w + (size_t) j * n + c), vld1q_f32(taps[j] + c));
        }
        vst1q_f32(out + c, vaddq_f32(acc, vld1q_f32(bias + c)));
    }
    for (; c < n; ++c) {
        float acc = 0.0f;
        for (int j = 0; j < k; ++j) {
            if (taps[j]) acc = fmaf(w[(size_t) j * n + c], taps[j][c], acc);
        }
        out[c] = acc + bias[c];
    }
}

// Four rows at a time, so sixteen sums run side by side; each row is summed
// exactly as the reference sums it.
static void gemv_f32_neon(const float * w, int rows, int cols, const float * x, float * y) {
    const int full = cols & ~15;
    float     tx[16] = { 0 };
    for (int j = 0; full + j < cols; ++j) tx[j] = x[full + j];
    for (int r = 0; r < rows; r += 4) {
        const int     nr = ORE_MIN(4, rows - r);
        const float * w0 = w + (size_t) r * cols;
        const float * w1 = w + (size_t) (r + ORE_MIN(1, nr - 1)) * cols;
        const float * w2 = w + (size_t) (r + ORE_MIN(2, nr - 1)) * cols;
        const float * w3 = w + (size_t) (r + ORE_MIN(3, nr - 1)) * cols;
        float32x4_t   a00 = vdupq_n_f32(0), a01 = a00, a02 = a00, a03 = a00;
        float32x4_t   a10 = a00, a11 = a00, a12 = a00, a13 = a00;
        float32x4_t   a20 = a00, a21 = a00, a22 = a00, a23 = a00;
        float32x4_t   a30 = a00, a31 = a00, a32 = a00, a33 = a00;
#define ORE_GEMV_STEP(W0, W1, W2, W3, X)                                                            \
    {                                                                                               \
        const float32x4_t x0 = vld1q_f32(X), x1 = vld1q_f32(X + 4), x2 = vld1q_f32(X + 8), x3 = vld1q_f32(X + 12); \
        a00 = vfmaq_f32(a00, vld1q_f32(W0), x0);                                                    \
        a01 = vfmaq_f32(a01, vld1q_f32(W0 + 4), x1);                                                \
        a02 = vfmaq_f32(a02, vld1q_f32(W0 + 8), x2);                                                \
        a03 = vfmaq_f32(a03, vld1q_f32(W0 + 12), x3);                                               \
        a10 = vfmaq_f32(a10, vld1q_f32(W1), x0);                                                    \
        a11 = vfmaq_f32(a11, vld1q_f32(W1 + 4), x1);                                                \
        a12 = vfmaq_f32(a12, vld1q_f32(W1 + 8), x2);                                                \
        a13 = vfmaq_f32(a13, vld1q_f32(W1 + 12), x3);                                               \
        a20 = vfmaq_f32(a20, vld1q_f32(W2), x0);                                                    \
        a21 = vfmaq_f32(a21, vld1q_f32(W2 + 4), x1);                                                \
        a22 = vfmaq_f32(a22, vld1q_f32(W2 + 8), x2);                                                \
        a23 = vfmaq_f32(a23, vld1q_f32(W2 + 12), x3);                                               \
        a30 = vfmaq_f32(a30, vld1q_f32(W3), x0);                                                    \
        a31 = vfmaq_f32(a31, vld1q_f32(W3 + 4), x1);                                                \
        a32 = vfmaq_f32(a32, vld1q_f32(W3 + 8), x2);                                                \
        a33 = vfmaq_f32(a33, vld1q_f32(W3 + 12), x3);                                               \
    }
        for (int k = 0; k < full; k += 16) ORE_GEMV_STEP(w0 + k, w1 + k, w2 + k, w3 + k, x + k)
        if (full < cols) {
            float t0[16] = { 0 }, t1[16] = { 0 }, t2[16] = { 0 }, t3[16] = { 0 };
            for (int j = 0; full + j < cols; ++j) {
                t0[j] = w0[full + j];
                t1[j] = w1[full + j];
                t2[j] = w2[full + j];
                t3[j] = w3[full + j];
            }
            ORE_GEMV_STEP(t0, t1, t2, t3, tx)
        }
#undef ORE_GEMV_STEP
        y[r] = sum16v(a00, a01, a02, a03);
        if (nr > 1) y[r + 1] = sum16v(a10, a11, a12, a13);
        if (nr > 2) y[r + 2] = sum16v(a20, a21, a22, a23);
        if (nr > 3) y[r + 3] = sum16v(a30, a31, a32, a33);
    }
}

const ore_kernels ore_kernels_neon = {
    "neon",        quantize_q8k_neon, quantize_q80_neon, gemm_q4k_neon, gemm_q80_neon, gemm_f32_neon,
    layer_norm_neon, silu_neon,       glu_neon,          softmax_neon,  dwconv_bn_silu_neon, dwconv_bias_neon,
    gemv_f32_neon,
};

#endif  // ORE_ARM64
