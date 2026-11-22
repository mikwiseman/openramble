// ore_kernels_avx2.c - x86-64 kernels for AVX2 + FMA + F16C (Intel from
// Haswell, 2013; AMD from Excavator and Zen). Compiled for those instruction
// sets by a function attribute, so the rest of the library stays runnable on
// any x86-64; this table is only picked when the processor reports them.
#include "ore_kernels.h"

#if ORE_X86

#include <immintrin.h>

#if defined(_MSC_VER)
#define ORE_AVX2
#else
#define ORE_AVX2 __attribute__((target("avx2,fma,f16c")))
#endif

// Frame f of block tb, columns [4 * k4, 4 * k4 + 4).
ORE_INLINE int8_t * qcell(const ore_qact * a, int tb, int k4, int f) {
    return a->q + (((size_t) tb * (size_t) (a->n / 4) + (size_t) k4) * ORE_FB + (size_t) f) * 4;
}

ORE_AVX2 ORE_INLINE float hmax256(__m256 v) {
    __m128 m = _mm_max_ps(_mm256_castps256_ps128(v), _mm256_extractf128_ps(v, 1));
    m        = _mm_max_ps(m, _mm_movehl_ps(m, m));
    m        = _mm_max_ss(m, _mm_shuffle_ps(m, m, 1));
    return _mm_cvtss_f32(m);
}
ORE_AVX2 ORE_INLINE float hmin256(__m256 v) {
    __m128 m = _mm_min_ps(_mm256_castps256_ps128(v), _mm256_extractf128_ps(v, 1));
    m        = _mm_min_ps(m, _mm_movehl_ps(m, m));
    m        = _mm_min_ss(m, _mm_shuffle_ps(m, m, 1));
    return _mm_cvtss_f32(m);
}

// 32 floats * scale -> 32 int8, rounded to nearest even, in order.
ORE_AVX2 ORE_INLINE __m256i round32(const float * p, __m256 vs) {
    const __m256i i0  = _mm256_cvtps_epi32(_mm256_mul_ps(_mm256_loadu_ps(p), vs));
    const __m256i i1  = _mm256_cvtps_epi32(_mm256_mul_ps(_mm256_loadu_ps(p + 8), vs));
    const __m256i i2  = _mm256_cvtps_epi32(_mm256_mul_ps(_mm256_loadu_ps(p + 16), vs));
    const __m256i i3  = _mm256_cvtps_epi32(_mm256_mul_ps(_mm256_loadu_ps(p + 24), vs));
    const __m256i s01 = _mm256_packs_epi32(i0, i1);
    const __m256i s23 = _mm256_packs_epi32(i2, i3);
    const __m256i b   = _mm256_packs_epi16(s01, s23);
    return _mm256_permutevar8x32_epi32(b, _mm256_setr_epi32(0, 4, 1, 5, 2, 6, 3, 7));
}

// ---- quantize ---------------------------------------------------------------

ORE_AVX2
static void quantize_q8k_avx2(const float * x, size_t xstride, int tb0, int tb1, ore_qact * out) {
    const int nb = out->nb;
    for (int tb = tb0; tb < tb1; ++tb) {
        for (int f = 0; f < ORE_FB; ++f) {
            const int     t   = tb * ORE_FB + f;
            const float * row = x + (size_t) t * xstride;
            for (int b = 0; b < nb; ++b) {
                int8_t  tmp[256];
                int32_t sums[8] = { 0 };
                float   d       = 0.0f;
                float   m       = 0.0f;
                if (t < out->rows) {
                    const float * p  = row + b * 256;
                    __m256        mx = _mm256_loadu_ps(p), mn = mx;
                    for (int j = 8; j < 256; j += 8) {
                        const __m256 v = _mm256_loadu_ps(p + j);
                        mx             = _mm256_max_ps(mx, v);
                        mn             = _mm256_min_ps(mn, v);
                    }
                    const float vmax = hmax256(mx), vmin = hmin256(mn);
                    m                = (-vmin > vmax) ? vmin : vmax;
                }
                if (m != 0.0f) {
                    const float * p      = row + b * 256;
                    const float   iscale = -127.f / m;
                    const __m256  vs     = _mm256_set1_ps(iscale);
                    for (int g = 0; g < 8; ++g) {
                        const __m256i qv = round32(p + g * 32, vs);
                        _mm256_storeu_si256((__m256i *) (tmp + g * 32), qv);
                        const __m256i p16 = _mm256_maddubs_epi16(_mm256_set1_epi8(1), qv);
                        const __m256i p32 = _mm256_madd_epi16(p16, _mm256_set1_epi16(1));
                        __m128i s = _mm_add_epi32(_mm256_castsi256_si128(p32), _mm256_extracti128_si256(p32, 1));
                        s         = _mm_add_epi32(s, _mm_shuffle_epi32(s, 0x4e));
                        s         = _mm_add_epi32(s, _mm_shuffle_epi32(s, 0xb1));
                        sums[g]   = _mm_cvtsi128_si32(s);
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

ORE_AVX2
static void quantize_q80_avx2(const float * x, size_t xstride, int tb0, int tb1, ore_qact * out) {
    const int    nb      = out->nb;
    const __m256 absmask = _mm256_castsi256_ps(_mm256_set1_epi32(0x7fffffff));
    for (int tb = tb0; tb < tb1; ++tb) {
        for (int f = 0; f < ORE_FB; ++f) {
            const int     t   = tb * ORE_FB + f;
            const float * row = x + (size_t) t * xstride;
            for (int b = 0; b < nb; ++b) {
                int8_t tmp[32];
                float  d = 0.0f;
                if (t < out->rows) {
                    const float * p  = row + b * 32;
                    __m256        am = _mm256_and_ps(_mm256_loadu_ps(p), absmask);
                    am               = _mm256_max_ps(am, _mm256_and_ps(_mm256_loadu_ps(p + 8), absmask));
                    am               = _mm256_max_ps(am, _mm256_and_ps(_mm256_loadu_ps(p + 16), absmask));
                    am               = _mm256_max_ps(am, _mm256_and_ps(_mm256_loadu_ps(p + 24), absmask));
                    const float amax = hmax256(am);
                    const float dd   = amax / 127.0f;
                    const float id   = dd != 0.0f ? 1.0f / dd : 0.0f;
                    d = _mm_cvtss_f32(_mm_cvtph_ps(_mm_cvtps_ph(_mm_set_ss(dd), _MM_FROUND_TO_NEAREST_INT)));
                    _mm256_storeu_si256((__m256i *) tmp, round32(p, _mm256_set1_ps(id)));
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

// One 16-frame block against two weight rows, `nv` vectors of eight frames.
// Four weights are broadcast and multiplied with four columns of every frame.
// The 16-bit pair sums of a whole group of 32 columns fit in 16 bits
// (8 * 2 * 15 * 127 < 32768), so a group costs one 8-bit multiply per four
// columns and a single 16-bit multiply at its end, which applies the group
// scale and widens to one 32-bit sum per frame.
ORE_AVX2 ORE_INLINE void q4k_block_avx2(const uint32_t * u0, const uint32_t * u1, const ore_q4k_hdr * h0,
                                        const ore_q4k_hdr * h1, int nb, const int8_t * A, const int32_t * G,
                                        const float * D, float * o0, float * o1, const int nv) {
    __m256 s0[2], s1[2];
    s0[0] = s0[1] = s1[0] = s1[1] = _mm256_setzero_ps();
    for (int b = 0; b < nb; ++b) {
        __m256i S0[2], S1[2], M0[2], M1[2];
        for (int v = 0; v < 2; ++v) S0[v] = S1[v] = M0[v] = M1[v] = _mm256_setzero_si256();
        for (int g = 0; g < 8; ++g) {
            __m256i a0[2], a1[2];
            a0[0] = a0[1] = a1[0] = a1[1] = _mm256_setzero_si256();
            const uint32_t * p0 = u0 + b * 64 + g * 8;
            const uint32_t * p1 = u1 + b * 64 + g * 8;
            const int8_t *   Ag = A + ((size_t) b * 64 + (size_t) g * 8) * 64;
            for (int c = 0; c < 8; ++c) {
                const __m256i wb0 = _mm256_set1_epi32((int) p0[c]);
                const __m256i wb1 = _mm256_set1_epi32((int) p1[c]);
                for (int v = 0; v < nv; ++v) {
                    const __m256i xv = _mm256_loadu_si256((const __m256i *) (Ag + c * 64 + v * 32));
                    a0[v]            = _mm256_add_epi16(a0[v], _mm256_maddubs_epi16(wb0, xv));
                    a1[v]            = _mm256_add_epi16(a1[v], _mm256_maddubs_epi16(wb1, xv));
                }
            }
            const __m256i sc0 = _mm256_set1_epi32(h0[b].sc2[g]), sc1 = _mm256_set1_epi32(h1[b].sc2[g]);
            const __m256i m0 = _mm256_set1_epi32(h0[b].mn[g]), m1 = _mm256_set1_epi32(h1[b].mn[g]);
            for (int v = 0; v < nv; ++v) {
                S0[v] = _mm256_add_epi32(S0[v], _mm256_madd_epi16(a0[v], sc0));
                S1[v] = _mm256_add_epi32(S1[v], _mm256_madd_epi16(a1[v], sc1));
                // A group sum fits in 16 bits, so the same multiply-add works
                // on it: the min sits in the low half of each lane.
                const __m256i gv =
                    _mm256_loadu_si256((const __m256i *) (G + ((size_t) b * 8 + g) * ORE_FB + v * 8));
                M0[v] = _mm256_add_epi32(M0[v], _mm256_madd_epi16(gv, m0));
                M1[v] = _mm256_add_epi32(M1[v], _mm256_madd_epi16(gv, m1));
            }
        }
        for (int v = 0; v < nv; ++v) {
            const __m256 dx = _mm256_loadu_ps(D + (size_t) b * ORE_FB + v * 8);
            s0[v] = _mm256_fnmadd_ps(_mm256_mul_ps(dx, _mm256_set1_ps(h0[b].dmin)), _mm256_cvtepi32_ps(M0[v]), s0[v]);
            s0[v] = _mm256_fmadd_ps(_mm256_mul_ps(dx, _mm256_set1_ps(h0[b].d)), _mm256_cvtepi32_ps(S0[v]), s0[v]);
            s1[v] = _mm256_fnmadd_ps(_mm256_mul_ps(dx, _mm256_set1_ps(h1[b].dmin)), _mm256_cvtepi32_ps(M1[v]), s1[v]);
            s1[v] = _mm256_fmadd_ps(_mm256_mul_ps(dx, _mm256_set1_ps(h1[b].d)), _mm256_cvtepi32_ps(S1[v]), s1[v]);
        }
    }
    for (int v = 0; v < nv; ++v) {
        _mm256_storeu_ps(o0 + v * 8, s0[v]);
        _mm256_storeu_ps(o1 + v * 8, s1[v]);
    }
}

ORE_AVX2
static void gemm_q4k_avx2(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y, size_t ystride) {
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
            if (valid > 8) {
                q4k_block_avx2(u0, u1, h0, h1, nb, A, G, D, o0, o1, 2);
            } else {
                q4k_block_avx2(u0, u1, h0, h1, nb, A, G, D, o0, o1, 1);
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

ORE_AVX2
static void gemm_q80_avx2(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y, size_t ystride) {
    const int     nb   = n_in / 32;
    const size_t  rb   = (size_t) nb * ORE_Q80_BYTES;
    const size_t  n4   = (size_t) n_in / 4;
    const __m256i ones = _mm256_set1_epi16(1);
    for (int r = r0; r < r1; r += 2) {
        const int       pair = r + 1 < r1;
        const uint8_t * w0   = w + (size_t) r * rb;
        const uint8_t * w1   = pair ? w0 + rb : w0;
        uint32_t        u0[ORE_Q4K_MAX_COLS / 4], u1[ORE_Q4K_MAX_COLS / 4];
        float           dw0[ORE_Q4K_MAX_COLS / 32], dw1[ORE_Q4K_MAX_COLS / 32];
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
            __m256         s00 = _mm256_setzero_ps(), s01 = s00, s10 = s00, s11 = s00;
            for (int b = 0; b < nb; ++b) {
                __m256i a00 = _mm256_setzero_si256(), a01 = a00, a10 = a00, a11 = a00;
                for (int c = 0; c < 8; ++c) {
                    // signed * signed through the unsigned * signed multiply:
                    // |w| * (x with w's sign)
                    const __m256i wb0 = _mm256_set1_epi32((int) u0[b * 8 + c]);
                    const __m256i wb1 = _mm256_set1_epi32((int) u1[b * 8 + c]);
                    const __m256i wa0 = _mm256_abs_epi8(wb0), wa1 = _mm256_abs_epi8(wb1);
                    const int8_t * Ac = A + ((size_t) b * 8 + c) * 64;
                    const __m256i  x0 = _mm256_loadu_si256((const __m256i *) Ac);
                    const __m256i  x1 = _mm256_loadu_si256((const __m256i *) (Ac + 32));
#define ORE_Q80_STEP(acc, wa, wb, xv) \
    acc = _mm256_add_epi32(acc, _mm256_madd_epi16(_mm256_maddubs_epi16(wa, _mm256_sign_epi8(xv, wb)), ones))
                    ORE_Q80_STEP(a00, wa0, wb0, x0);
                    ORE_Q80_STEP(a01, wa0, wb0, x1);
                    ORE_Q80_STEP(a10, wa1, wb1, x0);
                    ORE_Q80_STEP(a11, wa1, wb1, x1);
#undef ORE_Q80_STEP
                }
                const __m256 dx0 = _mm256_loadu_ps(D + (size_t) b * ORE_FB);
                const __m256 dx1 = _mm256_loadu_ps(D + (size_t) b * ORE_FB + 8);
                const __m256 vd0 = _mm256_set1_ps(dw0[b]), vd1 = _mm256_set1_ps(dw1[b]);
                s00 = _mm256_fmadd_ps(_mm256_cvtepi32_ps(a00), _mm256_mul_ps(dx0, vd0), s00);
                s01 = _mm256_fmadd_ps(_mm256_cvtepi32_ps(a01), _mm256_mul_ps(dx1, vd0), s01);
                s10 = _mm256_fmadd_ps(_mm256_cvtepi32_ps(a10), _mm256_mul_ps(dx0, vd1), s10);
                s11 = _mm256_fmadd_ps(_mm256_cvtepi32_ps(a11), _mm256_mul_ps(dx1, vd1), s11);
            }
            float o0[16], o1[16];
            _mm256_storeu_ps(o0, s00);
            _mm256_storeu_ps(o0 + 8, s01);
            _mm256_storeu_ps(o1, s10);
            _mm256_storeu_ps(o1 + 8, s11);
            float * yr = y + (size_t) tb * ORE_FB * ystride + r;
            for (int f = 0; f < valid; ++f) {
                yr[(size_t) f * ystride] = o0[f];
                if (pair) yr[(size_t) f * ystride + 1] = o1[f];
            }
        }
    }
}

// ---- float product ----------------------------------------------------------

// Four weight rows against a block of 16 frames (two vectors of eight): each
// weight is broadcast and multiplied into the frame vectors, so every output
// accumulates in order of k.
ORE_AVX2
static void gemm_f32_avx2(const void * w, int w_is_f16, size_t wstride, int n_in, int r0, int r1, const float * xp,
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
                for (; k + 8 <= n_in; k += 8) {
                    _mm256_storeu_ps(dst + k, _mm256_cvtph_ps(_mm_loadu_si128((const __m128i *) (h + k))));
                }
                for (; k < n_in; ++k) dst[k] = ore_f16_to_f32(h[k]);
                wr[i] = dst;
            } else {
                wr[i] = (const float *) w + (size_t) ri * wstride;
            }
        }
        const float * w0 = wr[0], *w1 = wr[1], *w2 = wr[2], *w3 = wr[3];
        for (int tb = 0; tb < ntb; ++tb) {
            const float * xb  = xp + (size_t) tb * n_in * ORE_FB;
            __m256        c00 = _mm256_setzero_ps(), c01 = c00, c10 = c00, c11 = c00;
            __m256        c20 = c00, c21 = c00, c30 = c00, c31 = c00;
            for (int k = 0; k < n_in; ++k) {
                const float * xk = xb + (size_t) k * ORE_FB;
                const __m256  x0 = _mm256_loadu_ps(xk), x1 = _mm256_loadu_ps(xk + 8);
                __m256        wv;
                wv  = _mm256_broadcast_ss(w0 + k);
                c00 = _mm256_fmadd_ps(wv, x0, c00);
                c01 = _mm256_fmadd_ps(wv, x1, c01);
                wv  = _mm256_broadcast_ss(w1 + k);
                c10 = _mm256_fmadd_ps(wv, x0, c10);
                c11 = _mm256_fmadd_ps(wv, x1, c11);
                wv  = _mm256_broadcast_ss(w2 + k);
                c20 = _mm256_fmadd_ps(wv, x0, c20);
                c21 = _mm256_fmadd_ps(wv, x1, c21);
                wv  = _mm256_broadcast_ss(w3 + k);
                c30 = _mm256_fmadd_ps(wv, x0, c30);
                c31 = _mm256_fmadd_ps(wv, x1, c31);
            }
            const int valid = ORE_MIN(ORE_FB, rows - tb * ORE_FB);
            float     out[4][16];
            _mm256_storeu_ps(out[0], c00);
            _mm256_storeu_ps(out[0] + 8, c01);
            _mm256_storeu_ps(out[1], c10);
            _mm256_storeu_ps(out[1] + 8, c11);
            _mm256_storeu_ps(out[2], c20);
            _mm256_storeu_ps(out[2] + 8, c21);
            _mm256_storeu_ps(out[3], c30);
            _mm256_storeu_ps(out[3] + 8, c31);
            for (int i = 0; i < nr; ++i) {
                float * yr = y + (size_t) tb * ORE_FB * ystride + r + i;
                for (int f = 0; f < valid; ++f) yr[(size_t) f * ystride] = out[i][f];
            }
        }
    }
}

// ---- element-wise steps -------------------------------------------------------

// exp, eight at a time: ore_expf's operations (see ore_base.h).
ORE_AVX2 ORE_INLINE __m256 vexp(__m256 x) {
    const __m256  r = _mm256_set1_ps(0x1.8p23f);
    const __m256  z = _mm256_fmadd_ps(x, _mm256_set1_ps(0x1.715476p+0f), r);
    const __m256  n = _mm256_sub_ps(z, r);
    const __m256  b = _mm256_fnmadd_ps(n, _mm256_set1_ps(0x1.7f7d1cp-20f),
                                       _mm256_fnmadd_ps(n, _mm256_set1_ps(0x1.62e4p-1f), x));
    const __m256i e = _mm256_slli_epi32(_mm256_castps_si256(z), 23);
    const __m256  k = _mm256_castsi256_ps(_mm256_add_epi32(e, _mm256_castps_si256(_mm256_set1_ps(1))));
    const __m256  an = _mm256_andnot_ps(_mm256_set1_ps(-0.f), n);
    const __m256  c  = _mm256_cmp_ps(an, _mm256_set1_ps(126), _CMP_GT_OQ);
    const __m256  u  = _mm256_mul_ps(b, b);
    const __m256  j  = _mm256_fmadd_ps(
        _mm256_fmadd_ps(_mm256_fmadd_ps(_mm256_set1_ps(0x1.0e4020p-7f), b, _mm256_set1_ps(0x1.573e2ep-5f)), u,
                        _mm256_fmadd_ps(_mm256_set1_ps(0x1.555e66p-3f), b, _mm256_set1_ps(0x1.fffdb6p-2f))),
        u, _mm256_mul_ps(_mm256_set1_ps(0x1.ffffecp-1f), b));
    if (!_mm256_movemask_ps(c)) return _mm256_fmadd_ps(j, k, k);
    const __m256i g  = _mm256_and_si256(_mm256_castps_si256(_mm256_cmp_ps(n, _mm256_setzero_ps(), _CMP_LE_OQ)),
                                        _mm256_set1_epi32((int) 0x82000000u));
    const __m256  s1 = _mm256_castsi256_ps(_mm256_add_epi32(g, _mm256_set1_epi32(0x7f000000)));
    const __m256  s2 = _mm256_castsi256_ps(_mm256_sub_epi32(e, g));
    const __m256  d  = _mm256_cmp_ps(an, _mm256_set1_ps(192), _CMP_GT_OQ);
    return _mm256_blendv_ps(
        _mm256_blendv_ps(_mm256_fmadd_ps(j, k, k), _mm256_mul_ps(_mm256_fmadd_ps(s2, j, s2), s1), c),
        _mm256_mul_ps(s1, s1), d);
}

ORE_AVX2 ORE_INLINE __m256 vsilu(__m256 x) {
    return _mm256_div_ps(x, _mm256_add_ps(_mm256_set1_ps(1.0f), vexp(_mm256_sub_ps(_mm256_setzero_ps(), x))));
}

// Lanes 0-7 and 8-15 -> the pairwise sum the reference defines.
ORE_AVX2 ORE_INLINE float sum16v(__m256 a, __m256 b) {
    const __m256 t8 = _mm256_add_ps(a, b);                                                  // l + l+8
    const __m128 t4 = _mm_add_ps(_mm256_castps256_ps128(t8), _mm256_extractf128_ps(t8, 1));  // l + l+4
    const __m128 t2 = _mm_add_ps(t4, _mm_movehl_ps(t4, t4));                                 // l + l+2
    return _mm_cvtss_f32(_mm_add_ss(t2, _mm_shuffle_ps(t2, t2, 1)));
}

ORE_AVX2
static void layer_norm_avx2(const float * x, float * y, int n, const float * gamma, const float * beta, float eps) {
    __m256 s0 = _mm256_setzero_ps(), s1 = s0;
    int    i = 0;
    for (; i + 16 <= n; i += 16) {
        s0 = _mm256_add_ps(s0, _mm256_loadu_ps(x + i));
        s1 = _mm256_add_ps(s1, _mm256_loadu_ps(x + i + 8));
    }
    float tail[16] = { 0 };
    for (int j = 0; i + j < n; ++j) tail[j] = x[i + j];
    s0 = _mm256_add_ps(s0, _mm256_loadu_ps(tail));
    s1 = _mm256_add_ps(s1, _mm256_loadu_ps(tail + 8));
    const float  mean = sum16v(s0, s1) / (float) n;
    const __m256 vm   = _mm256_set1_ps(mean);
    __m256       v0 = _mm256_setzero_ps(), v1 = v0;
    for (i = 0; i + 16 <= n; i += 16) {
        const __m256 d0 = _mm256_sub_ps(_mm256_loadu_ps(x + i), vm);
        const __m256 d1 = _mm256_sub_ps(_mm256_loadu_ps(x + i + 8), vm);
        v0              = _mm256_fmadd_ps(d0, d0, v0);
        v1              = _mm256_fmadd_ps(d1, d1, v1);
    }
    float vt[16] = { 0 };
    for (int j = 0; i + j < n; ++j) vt[j] = x[i + j] - mean;
    {
        const __m256 d0 = _mm256_loadu_ps(vt), d1 = _mm256_loadu_ps(vt + 8);
        v0              = _mm256_fmadd_ps(d0, d0, v0);
        v1              = _mm256_fmadd_ps(d1, d1, v1);
    }
    const float  var   = sum16v(v0, v1) / (float) n;
    const float  scale = 1.0f / sqrtf(var + eps);
    const __m256 vs    = _mm256_set1_ps(scale);
    for (i = 0; i + 8 <= n; i += 8) {
        const __m256 d = _mm256_sub_ps(_mm256_loadu_ps(x + i), vm);
        _mm256_storeu_ps(
            y + i, _mm256_add_ps(_mm256_mul_ps(_mm256_mul_ps(d, vs), _mm256_loadu_ps(gamma + i)), _mm256_loadu_ps(beta + i)));
    }
    for (; i < n; ++i) {
        const float d = x[i] - mean;
        const float t = (d * scale) * gamma[i];
        y[i]          = t + beta[i];
    }
}

ORE_AVX2
static void silu_avx2(float * x, size_t n) {
    size_t i = 0;
    for (; i + 8 <= n; i += 8) _mm256_storeu_ps(x + i, vsilu(_mm256_loadu_ps(x + i)));
    for (; i < n; ++i) x[i] = x[i] / (1.0f + ore_expf(0.0f - x[i]));
}

ORE_AVX2
static void glu_avx2(const float * a, const float * b, float * out, size_t n) {
    size_t       i   = 0;
    const __m256 one = _mm256_set1_ps(1.0f);
    for (; i + 8 <= n; i += 8) {
        const __m256 e = vexp(_mm256_sub_ps(_mm256_setzero_ps(), _mm256_loadu_ps(b + i)));
        _mm256_storeu_ps(out + i, _mm256_mul_ps(_mm256_loadu_ps(a + i), _mm256_div_ps(one, _mm256_add_ps(one, e))));
    }
    for (; i < n; ++i) out[i] = a[i] * (1.0f / (1.0f + ore_expf(0.0f - b[i])));
}

ORE_AVX2
static void softmax_avx2(float * s, int n) {
    float mx = s[0];
    int   i  = 0;
    if (n >= 8) {
        __m256 m = _mm256_loadu_ps(s);
        for (i = 8; i + 8 <= n; i += 8) m = _mm256_max_ps(m, _mm256_loadu_ps(s + i));
        mx = hmax256(m);
    }
    for (; i < n; ++i) {
        if (s[i] > mx) mx = s[i];
    }
    const __m256 vmx = _mm256_set1_ps(mx);
    __m256       a0 = _mm256_setzero_ps(), a1 = a0;
    for (i = 0; i + 16 <= n; i += 16) {
        const __m256 e0 = vexp(_mm256_sub_ps(_mm256_loadu_ps(s + i), vmx));
        const __m256 e1 = vexp(_mm256_sub_ps(_mm256_loadu_ps(s + i + 8), vmx));
        _mm256_storeu_ps(s + i, e0);
        _mm256_storeu_ps(s + i + 8, e1);
        a0 = _mm256_add_ps(a0, e0);
        a1 = _mm256_add_ps(a1, e1);
    }
    float tail[16] = { 0 };
    for (int j = 0; i + j < n; ++j) {
        s[i + j] = ore_expf(s[i + j] - mx);
        tail[j]  = s[i + j];
    }
    a0 = _mm256_add_ps(a0, _mm256_loadu_ps(tail));
    a1 = _mm256_add_ps(a1, _mm256_loadu_ps(tail + 8));
    const float  inv  = 1.0f / sum16v(a0, a1);
    const __m256 vinv = _mm256_set1_ps(inv);
    for (i = 0; i + 8 <= n; i += 8) _mm256_storeu_ps(s + i, _mm256_mul_ps(_mm256_loadu_ps(s + i), vinv));
    for (; i < n; ++i) s[i] = s[i] * inv;
}

ORE_AVX2
static void dwconv_bn_silu_avx2(const float * const * taps, const float * w, int k, int n, const float * scale,
                                const float * bias, float * out) {
    int c = 0;
    for (; c + 8 <= n; c += 8) {
        __m256 acc = _mm256_setzero_ps();
        for (int j = 0; j < k; ++j) {
            if (taps[j]) acc = _mm256_fmadd_ps(_mm256_loadu_ps(w + (size_t) j * n + c), _mm256_loadu_ps(taps[j] + c), acc);
        }
        const __m256 u = _mm256_add_ps(_mm256_mul_ps(acc, _mm256_loadu_ps(scale + c)), _mm256_loadu_ps(bias + c));
        _mm256_storeu_ps(out + c, vsilu(u));
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

ORE_AVX2
static void dwconv_bias_avx2(const float * const * taps, const float * w, int k, int n, const float * bias,
                             float * out) {
    int c = 0;
    for (; c + 8 <= n; c += 8) {
        __m256 acc = _mm256_setzero_ps();
        for (int j = 0; j < k; ++j) {
            if (taps[j]) acc = _mm256_fmadd_ps(_mm256_loadu_ps(w + (size_t) j * n + c), _mm256_loadu_ps(taps[j] + c), acc);
        }
        _mm256_storeu_ps(out + c, _mm256_add_ps(acc, _mm256_loadu_ps(bias + c)));
    }
    for (; c < n; ++c) {
        float acc = 0.0f;
        for (int j = 0; j < k; ++j) {
            if (taps[j]) acc = fmaf(w[(size_t) j * n + c], taps[j][c], acc);
        }
        out[c] = acc + bias[c];
    }
}

ORE_AVX2
static void gemv_f32_avx2(const float * w, int rows, int cols, const float * x, float * y) {
    for (int r = 0; r < rows; ++r) {
        const float * wr = w + (size_t) r * cols;
        __m256        a0 = _mm256_setzero_ps(), a1 = a0;
        int           k  = 0;
        for (; k + 16 <= cols; k += 16) {
            a0 = _mm256_fmadd_ps(_mm256_loadu_ps(wr + k), _mm256_loadu_ps(x + k), a0);
            a1 = _mm256_fmadd_ps(_mm256_loadu_ps(wr + k + 8), _mm256_loadu_ps(x + k + 8), a1);
        }
        if (k < cols) {
            float tw[16] = { 0 }, tx[16] = { 0 };
            for (int j = 0; k + j < cols; ++j) {
                tw[j] = wr[k + j];
                tx[j] = x[k + j];
            }
            a0 = _mm256_fmadd_ps(_mm256_loadu_ps(tw), _mm256_loadu_ps(tx), a0);
            a1 = _mm256_fmadd_ps(_mm256_loadu_ps(tw + 8), _mm256_loadu_ps(tx + 8), a1);
        }
        y[r] = sum16v(a0, a1);
    }
}

const ore_kernels ore_kernels_avx2 = {
    "avx2",          quantize_q8k_avx2, quantize_q80_avx2, gemm_q4k_avx2, gemm_q80_avx2, gemm_f32_avx2,
    layer_norm_avx2, silu_avx2,         glu_avx2,          softmax_avx2,  dwconv_bn_silu_avx2, dwconv_bias_avx2,
    gemv_f32_avx2,
};

#endif  // ORE_X86
