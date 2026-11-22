// ore_kernels_sse.c - x86-64 kernels for processors without AVX2: SSSE3 and
// SSE4.1, which Intel has had since 2008 and AMD since 2011. These are the
// oldest and slowest computers the engine runs on at a useful speed.
//
// The integer arithmetic is the same as everywhere else. These processors
// have no fused multiply-add, so floats are multiplied and then added, and a
// result can differ from the other kernel sets in its last bits. Within this
// set a clip always gives the same result.
#include "ore_kernels.h"

#if ORE_X86

#include <smmintrin.h>
#include <tmmintrin.h>

#if defined(_MSC_VER)
#define ORE_SSE
#else
#define ORE_SSE __attribute__((target("ssse3,sse4.1")))
#endif

// Frame f of block tb, columns [4 * k4, 4 * k4 + 4).
ORE_INLINE int8_t * qcell(const ore_qact * a, int tb, int k4, int f) {
    return a->q + (((size_t) tb * (size_t) (a->n / 4) + (size_t) k4) * ORE_FB + (size_t) f) * 4;
}

ORE_SSE ORE_INLINE float hmax128(__m128 m) {
    m = _mm_max_ps(m, _mm_movehl_ps(m, m));
    m = _mm_max_ss(m, _mm_shuffle_ps(m, m, 1));
    return _mm_cvtss_f32(m);
}
ORE_SSE ORE_INLINE float hmin128(__m128 m) {
    m = _mm_min_ps(m, _mm_movehl_ps(m, m));
    m = _mm_min_ss(m, _mm_shuffle_ps(m, m, 1));
    return _mm_cvtss_f32(m);
}

// 16 floats * scale -> 16 int8, rounded to nearest even, in order.
ORE_SSE ORE_INLINE __m128i round16(const float * p, __m128 vs) {
    const __m128i i0 = _mm_cvtps_epi32(_mm_mul_ps(_mm_loadu_ps(p), vs));
    const __m128i i1 = _mm_cvtps_epi32(_mm_mul_ps(_mm_loadu_ps(p + 4), vs));
    const __m128i i2 = _mm_cvtps_epi32(_mm_mul_ps(_mm_loadu_ps(p + 8), vs));
    const __m128i i3 = _mm_cvtps_epi32(_mm_mul_ps(_mm_loadu_ps(p + 12), vs));
    return _mm_packs_epi16(_mm_packs_epi32(i0, i1), _mm_packs_epi32(i2, i3));
}

// Four half-precision values, each in the low half of a 32-bit lane, to single.
ORE_SSE ORE_INLINE __m128 half4(__m128i h) {
    const __m128i sign = _mm_slli_epi32(_mm_and_si128(h, _mm_set1_epi32(0x8000)), 16);
    const __m128i ex   = _mm_and_si128(_mm_srli_epi32(h, 10), _mm_set1_epi32(0x1f));
    const __m128i man  = _mm_and_si128(h, _mm_set1_epi32(0x3ff));
    const __m128i norm =
        _mm_or_si128(_mm_slli_epi32(_mm_add_epi32(ex, _mm_set1_epi32(112)), 23), _mm_slli_epi32(man, 13));
    const __m128i infn = _mm_or_si128(_mm_set1_epi32(0x7f800000), _mm_slli_epi32(man, 13));
    // exponent 0: zero or subnormal, mantissa * 2^-24 exactly
    const __m128i sub = _mm_castps_si128(_mm_mul_ps(_mm_cvtepi32_ps(man), _mm_set1_ps(5.9604644775390625e-08f)));
    const __m128i is0 = _mm_cmpeq_epi32(ex, _mm_setzero_si128());
    const __m128i is1 = _mm_cmpeq_epi32(ex, _mm_set1_epi32(31));
    __m128i       v   = _mm_or_si128(_mm_and_si128(is0, sub), _mm_andnot_si128(is0, norm));
    v                 = _mm_or_si128(_mm_and_si128(is1, infn), _mm_andnot_si128(is1, v));
    return _mm_castsi128_ps(_mm_or_si128(v, sign));
}

// ---- quantize ---------------------------------------------------------------

ORE_SSE
static void quantize_q8k_sse(const float * x, size_t xstride, int tb0, int tb1, ore_qact * out) {
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
                    __m128        mx = _mm_loadu_ps(p), mn = mx;
                    for (int j = 4; j < 256; j += 4) {
                        const __m128 v = _mm_loadu_ps(p + j);
                        mx             = _mm_max_ps(mx, v);
                        mn             = _mm_min_ps(mn, v);
                    }
                    const float vmax = hmax128(mx), vmin = hmin128(mn);
                    m                = (-vmin > vmax) ? vmin : vmax;
                }
                if (m != 0.0f) {
                    const float * p      = row + b * 256;
                    const float   iscale = -127.f / m;
                    const __m128  vs     = _mm_set1_ps(iscale);
                    for (int g = 0; g < 8; ++g) {
                        __m128i s = _mm_setzero_si128();
                        for (int h = 0; h < 2; ++h) {
                            const __m128i qv = round16(p + g * 32 + h * 16, vs);
                            _mm_storeu_si128((__m128i *) (tmp + g * 32 + h * 16), qv);
                            const __m128i p16 = _mm_maddubs_epi16(_mm_set1_epi8(1), qv);
                            s                 = _mm_add_epi32(s, _mm_madd_epi16(p16, _mm_set1_epi16(1)));
                        }
                        s       = _mm_add_epi32(s, _mm_shuffle_epi32(s, 0x4e));
                        s       = _mm_add_epi32(s, _mm_shuffle_epi32(s, 0xb1));
                        sums[g] = _mm_cvtsi128_si32(s);
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

ORE_SSE
static void quantize_q80_sse(const float * x, size_t xstride, int tb0, int tb1, ore_qact * out) {
    const int    nb      = out->nb;
    const __m128 absmask = _mm_castsi128_ps(_mm_set1_epi32(0x7fffffff));
    for (int tb = tb0; tb < tb1; ++tb) {
        for (int f = 0; f < ORE_FB; ++f) {
            const int     t   = tb * ORE_FB + f;
            const float * row = x + (size_t) t * xstride;
            for (int b = 0; b < nb; ++b) {
                int8_t tmp[32];
                float  d = 0.0f;
                if (t < out->rows) {
                    const float * p  = row + b * 32;
                    __m128        am = _mm_and_ps(_mm_loadu_ps(p), absmask);
                    for (int j = 4; j < 32; j += 4) am = _mm_max_ps(am, _mm_and_ps(_mm_loadu_ps(p + j), absmask));
                    const float amax = hmax128(am);
                    const float dd   = amax / 127.0f;
                    const float id   = dd != 0.0f ? 1.0f / dd : 0.0f;
                    d                = ore_f16_to_f32(ore_f32_to_f16(dd));
                    const __m128 vs  = _mm_set1_ps(id);
                    _mm_storeu_si128((__m128i *) tmp, round16(p, vs));
                    _mm_storeu_si128((__m128i *) (tmp + 16), round16(p + 16, vs));
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
// The AVX2 kernel at half the width.
ORE_SSE ORE_INLINE void q4k_block_sse(const uint32_t * u0, const uint32_t * u1, const ore_q4k_hdr * h0,
                                      const ore_q4k_hdr * h1, int nb, const int8_t * A, const int32_t * G,
                                      const float * D, float * o0, float * o1, const int nv) {
    __m128 s0[4], s1[4];
    for (int v = 0; v < 4; ++v) s0[v] = s1[v] = _mm_setzero_ps();
    for (int b = 0; b < nb; ++b) {
        __m128i S0[4], S1[4], M0[4], M1[4];
        for (int v = 0; v < 4; ++v) S0[v] = S1[v] = M0[v] = M1[v] = _mm_setzero_si128();
        for (int g = 0; g < 8; ++g) {
            __m128i a0[4], a1[4];
            for (int v = 0; v < 4; ++v) a0[v] = a1[v] = _mm_setzero_si128();
            const uint32_t * p0 = u0 + b * 64 + g * 8;
            const uint32_t * p1 = u1 + b * 64 + g * 8;
            const int8_t *   Ag = A + ((size_t) b * 64 + (size_t) g * 8) * 64;
            for (int c = 0; c < 8; ++c) {
                const __m128i wb0 = _mm_set1_epi32((int) p0[c]);
                const __m128i wb1 = _mm_set1_epi32((int) p1[c]);
                for (int v = 0; v < nv; ++v) {
                    const __m128i xv = _mm_loadu_si128((const __m128i *) (Ag + c * 64 + v * 16));
                    a0[v]            = _mm_add_epi16(a0[v], _mm_maddubs_epi16(wb0, xv));
                    a1[v]            = _mm_add_epi16(a1[v], _mm_maddubs_epi16(wb1, xv));
                }
            }
            const __m128i sc0 = _mm_set1_epi32(h0[b].sc2[g]), sc1 = _mm_set1_epi32(h1[b].sc2[g]);
            const __m128i m0 = _mm_set1_epi32(h0[b].mn[g]), m1 = _mm_set1_epi32(h1[b].mn[g]);
            for (int v = 0; v < nv; ++v) {
                S0[v] = _mm_add_epi32(S0[v], _mm_madd_epi16(a0[v], sc0));
                S1[v] = _mm_add_epi32(S1[v], _mm_madd_epi16(a1[v], sc1));
                const __m128i gv = _mm_loadu_si128((const __m128i *) (G + ((size_t) b * 8 + g) * ORE_FB + v * 4));
                M0[v]            = _mm_add_epi32(M0[v], _mm_madd_epi16(gv, m0));
                M1[v]            = _mm_add_epi32(M1[v], _mm_madd_epi16(gv, m1));
            }
        }
        for (int v = 0; v < nv; ++v) {
            const __m128 dx = _mm_loadu_ps(D + (size_t) b * ORE_FB + v * 4);
            s0[v] = _mm_sub_ps(s0[v], _mm_mul_ps(_mm_mul_ps(dx, _mm_set1_ps(h0[b].dmin)), _mm_cvtepi32_ps(M0[v])));
            s0[v] = _mm_add_ps(s0[v], _mm_mul_ps(_mm_mul_ps(dx, _mm_set1_ps(h0[b].d)), _mm_cvtepi32_ps(S0[v])));
            s1[v] = _mm_sub_ps(s1[v], _mm_mul_ps(_mm_mul_ps(dx, _mm_set1_ps(h1[b].dmin)), _mm_cvtepi32_ps(M1[v])));
            s1[v] = _mm_add_ps(s1[v], _mm_mul_ps(_mm_mul_ps(dx, _mm_set1_ps(h1[b].d)), _mm_cvtepi32_ps(S1[v])));
        }
    }
    for (int v = 0; v < nv; ++v) {
        _mm_storeu_ps(o0 + v * 4, s0[v]);
        _mm_storeu_ps(o1 + v * 4, s1[v]);
    }
}

ORE_SSE
static void gemm_q4k_sse(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y, size_t ystride) {
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
                case 1: q4k_block_sse(u0, u1, h0, h1, nb, A, G, D, o0, o1, 1); break;
                case 2: q4k_block_sse(u0, u1, h0, h1, nb, A, G, D, o0, o1, 2); break;
                case 3: q4k_block_sse(u0, u1, h0, h1, nb, A, G, D, o0, o1, 3); break;
                default: q4k_block_sse(u0, u1, h0, h1, nb, A, G, D, o0, o1, 4); break;
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

ORE_SSE
static void gemm_q80_sse(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y, size_t ystride) {
    const int     nb   = n_in / 32;
    const size_t  rb   = (size_t) nb * ORE_Q80_BYTES;
    const size_t  n4   = (size_t) n_in / 4;
    const __m128i ones = _mm_set1_epi16(1);
    for (int r = r0; r < r1; ++r) {
        const uint8_t * w0 = w + (size_t) r * rb;
        uint32_t        u0[ORE_Q4K_MAX_COLS / 4];
        float           dw0[ORE_Q4K_MAX_COLS / 32];
        for (int b = 0; b < nb; ++b) {
            memcpy((uint8_t *) u0 + b * 32, w0 + (size_t) b * ORE_Q80_BYTES + 2, 32);
            dw0[b] = ore_f16_to_f32(ore_rd16(w0 + (size_t) b * ORE_Q80_BYTES));
        }
        for (int tb = 0; tb < x->ntb; ++tb) {
            const int      valid = ORE_MIN(ORE_FB, x->rows - tb * ORE_FB);
            const int8_t * A     = x->q + (size_t) tb * n4 * 64;
            const float *  D     = x->d + (size_t) tb * nb * ORE_FB;
            __m128         s[4];
            for (int v = 0; v < 4; ++v) s[v] = _mm_setzero_ps();
            for (int b = 0; b < nb; ++b) {
                __m128i a[4];
                for (int v = 0; v < 4; ++v) a[v] = _mm_setzero_si128();
                for (int c = 0; c < 8; ++c) {
                    const __m128i  wb = _mm_set1_epi32((int) u0[b * 8 + c]);
                    const __m128i  wa = _mm_abs_epi8(wb);
                    const int8_t * Ac = A + ((size_t) b * 8 + c) * 64;
                    for (int v = 0; v < 4; ++v) {
                        const __m128i xv = _mm_loadu_si128((const __m128i *) (Ac + v * 16));
                        a[v] = _mm_add_epi32(a[v], _mm_madd_epi16(_mm_maddubs_epi16(wa, _mm_sign_epi8(xv, wb)), ones));
                    }
                }
                for (int v = 0; v < 4; ++v) {
                    const __m128 dx = _mm_loadu_ps(D + (size_t) b * ORE_FB + v * 4);
                    s[v] = _mm_add_ps(s[v], _mm_mul_ps(_mm_cvtepi32_ps(a[v]), _mm_mul_ps(dx, _mm_set1_ps(dw0[b]))));
                }
            }
            float o[16];
            for (int v = 0; v < 4; ++v) _mm_storeu_ps(o + v * 4, s[v]);
            float * yr = y + (size_t) tb * ORE_FB * ystride + r;
            for (int f = 0; f < valid; ++f) yr[(size_t) f * ystride] = o[f];
        }
    }
}

// ---- float product ----------------------------------------------------------

// Three weight rows against a block of 16 frames, multiply then add.
#define ORE_SSE_ROWS 3
ORE_SSE
static void gemm_f32_sse(const void * w, int w_is_f16, size_t wstride, int n_in, int r0, int r1, const float * xp,
                         int rows, float * y, size_t ystride, float * scratch) {
    const int ntb = ore_frame_blocks(rows);
    for (int r = r0; r < r1; r += ORE_SSE_ROWS) {
        const int     nr = ORE_MIN(ORE_SSE_ROWS, r1 - r);
        const float * wr[ORE_SSE_ROWS];
        for (int i = 0; i < ORE_SSE_ROWS; ++i) {
            const int ri = r + ORE_MIN(i, nr - 1);
            if (w_is_f16) {
                const uint16_t * h   = (const uint16_t *) w + (size_t) ri * wstride;
                float *          dst = scratch + (size_t) i * n_in;
                int              k   = 0;
                for (; k + 4 <= n_in; k += 4) {
                    const __m128i h4 =
                        _mm_unpacklo_epi16(_mm_loadl_epi64((const __m128i *) (h + k)), _mm_setzero_si128());
                    _mm_storeu_ps(dst + k, half4(h4));
                }
                for (; k < n_in; ++k) dst[k] = ore_f16_to_f32(h[k]);
                wr[i] = dst;
            } else {
                wr[i] = (const float *) w + (size_t) ri * wstride;
            }
        }
        for (int tb = 0; tb < ntb; ++tb) {
            const float * xb = xp + (size_t) tb * n_in * ORE_FB;
            __m128        c[ORE_SSE_ROWS][4];
            for (int i = 0; i < ORE_SSE_ROWS; ++i) {
                for (int j = 0; j < 4; ++j) c[i][j] = _mm_setzero_ps();
            }
            for (int k = 0; k < n_in; ++k) {
                const float * xk = xb + (size_t) k * ORE_FB;
                const __m128  x0 = _mm_loadu_ps(xk), x1 = _mm_loadu_ps(xk + 4);
                const __m128  x2 = _mm_loadu_ps(xk + 8), x3 = _mm_loadu_ps(xk + 12);
                for (int i = 0; i < ORE_SSE_ROWS; ++i) {
                    const __m128 wv = _mm_set1_ps(wr[i][k]);
                    c[i][0]         = _mm_add_ps(c[i][0], _mm_mul_ps(wv, x0));
                    c[i][1]         = _mm_add_ps(c[i][1], _mm_mul_ps(wv, x1));
                    c[i][2]         = _mm_add_ps(c[i][2], _mm_mul_ps(wv, x2));
                    c[i][3]         = _mm_add_ps(c[i][3], _mm_mul_ps(wv, x3));
                }
            }
            const int valid = ORE_MIN(ORE_FB, rows - tb * ORE_FB);
            for (int i = 0; i < nr; ++i) {
                float out[16];
                for (int j = 0; j < 4; ++j) _mm_storeu_ps(out + j * 4, c[i][j]);
                float * yr = y + (size_t) tb * ORE_FB * ystride + r + i;
                for (int f = 0; f < valid; ++f) yr[(size_t) f * ystride] = out[f];
            }
        }
    }
}

// ---- element-wise steps -------------------------------------------------------

// exp without fused multiply-add: the same polynomial, each product rounded.
ORE_SSE ORE_INLINE __m128 vexp(__m128 x) {
    const __m128  r  = _mm_set1_ps(0x1.8p23f);
    const __m128  z  = _mm_add_ps(_mm_mul_ps(x, _mm_set1_ps(0x1.715476p+0f)), r);
    const __m128  n  = _mm_sub_ps(z, r);
    const __m128  b  = _mm_sub_ps(_mm_sub_ps(x, _mm_mul_ps(n, _mm_set1_ps(0x1.62e4p-1f))),
                                  _mm_mul_ps(n, _mm_set1_ps(0x1.7f7d1cp-20f)));
    const __m128i e  = _mm_slli_epi32(_mm_castps_si128(z), 23);
    const __m128  k  = _mm_castsi128_ps(_mm_add_epi32(e, _mm_castps_si128(_mm_set1_ps(1))));
    const __m128  an = _mm_andnot_ps(_mm_set1_ps(-0.f), n);
    const __m128  c  = _mm_cmpgt_ps(an, _mm_set1_ps(126));
    const __m128  u  = _mm_mul_ps(b, b);
    const __m128  p1 = _mm_add_ps(_mm_mul_ps(_mm_set1_ps(0x1.0e4020p-7f), b), _mm_set1_ps(0x1.573e2ep-5f));
    const __m128  p0 = _mm_add_ps(_mm_mul_ps(_mm_set1_ps(0x1.555e66p-3f), b), _mm_set1_ps(0x1.fffdb6p-2f));
    const __m128  j  = _mm_add_ps(_mm_mul_ps(_mm_add_ps(_mm_mul_ps(p1, u), p0), u),
                                  _mm_mul_ps(_mm_set1_ps(0x1.ffffecp-1f), b));
    const __m128  ok = _mm_add_ps(_mm_mul_ps(j, k), k);
    if (!_mm_movemask_ps(c)) return ok;
    const __m128i g  = _mm_and_si128(_mm_castps_si128(_mm_cmple_ps(n, _mm_setzero_ps())), _mm_set1_epi32((int) 0x82000000u));
    const __m128  s1 = _mm_castsi128_ps(_mm_add_epi32(g, _mm_set1_epi32(0x7f000000)));
    const __m128  s2 = _mm_castsi128_ps(_mm_sub_epi32(e, g));
    const __m128  d  = _mm_cmpgt_ps(an, _mm_set1_ps(192));
    const __m128  mid = _mm_mul_ps(_mm_add_ps(_mm_mul_ps(s2, j), s2), s1);
    return _mm_blendv_ps(_mm_blendv_ps(ok, mid, c), _mm_mul_ps(s1, s1), d);
}

ORE_SSE ORE_INLINE float exp1(float x) { return _mm_cvtss_f32(vexp(_mm_set1_ps(x))); }

ORE_SSE ORE_INLINE __m128 vsilu(__m128 x) {
    return _mm_div_ps(x, _mm_add_ps(_mm_set1_ps(1.0f), vexp(_mm_sub_ps(_mm_setzero_ps(), x))));
}

// Lanes 0-3, 4-7, 8-11, 12-15 -> the pairwise sum every kernel set uses.
ORE_SSE ORE_INLINE float sum16v(__m128 a, __m128 b, __m128 c, __m128 d) {
    const __m128 t4 = _mm_add_ps(_mm_add_ps(a, c), _mm_add_ps(b, d));
    const __m128 t2 = _mm_add_ps(t4, _mm_movehl_ps(t4, t4));
    return _mm_cvtss_f32(_mm_add_ss(t2, _mm_shuffle_ps(t2, t2, 1)));
}

ORE_SSE
static void layer_norm_sse(const float * x, float * y, int n, const float * gamma, const float * beta, float eps) {
    __m128 s[4], v[4];
    for (int j = 0; j < 4; ++j) s[j] = v[j] = _mm_setzero_ps();
    int i = 0;
    for (; i + 16 <= n; i += 16) {
        for (int j = 0; j < 4; ++j) s[j] = _mm_add_ps(s[j], _mm_loadu_ps(x + i + 4 * j));
    }
    float tail[16] = { 0 };
    for (int j = 0; i + j < n; ++j) tail[j] = x[i + j];
    for (int j = 0; j < 4; ++j) s[j] = _mm_add_ps(s[j], _mm_loadu_ps(tail + 4 * j));
    const float  mean = sum16v(s[0], s[1], s[2], s[3]) / (float) n;
    const __m128 vm   = _mm_set1_ps(mean);
    for (i = 0; i + 16 <= n; i += 16) {
        for (int j = 0; j < 4; ++j) {
            const __m128 d = _mm_sub_ps(_mm_loadu_ps(x + i + 4 * j), vm);
            v[j]           = _mm_add_ps(v[j], _mm_mul_ps(d, d));
        }
    }
    float vt[16] = { 0 };
    for (int j = 0; i + j < n; ++j) vt[j] = x[i + j] - mean;
    for (int j = 0; j < 4; ++j) {
        const __m128 d = _mm_loadu_ps(vt + 4 * j);
        v[j]           = _mm_add_ps(v[j], _mm_mul_ps(d, d));
    }
    const float  var   = sum16v(v[0], v[1], v[2], v[3]) / (float) n;
    const float  scale = 1.0f / sqrtf(var + eps);
    const __m128 vs    = _mm_set1_ps(scale);
    for (i = 0; i + 4 <= n; i += 4) {
        const __m128 d = _mm_sub_ps(_mm_loadu_ps(x + i), vm);
        _mm_storeu_ps(y + i, _mm_add_ps(_mm_mul_ps(_mm_mul_ps(d, vs), _mm_loadu_ps(gamma + i)), _mm_loadu_ps(beta + i)));
    }
    for (; i < n; ++i) {
        const float d = x[i] - mean;
        const float t = (d * scale) * gamma[i];
        y[i]          = t + beta[i];
    }
}

ORE_SSE
static void silu_sse(float * x, size_t n) {
    size_t i = 0;
    for (; i + 4 <= n; i += 4) _mm_storeu_ps(x + i, vsilu(_mm_loadu_ps(x + i)));
    for (; i < n; ++i) x[i] = x[i] / (1.0f + exp1(0.0f - x[i]));
}

ORE_SSE
static void glu_sse(const float * a, const float * b, float * out, size_t n) {
    size_t       i   = 0;
    const __m128 one = _mm_set1_ps(1.0f);
    for (; i + 4 <= n; i += 4) {
        const __m128 e = vexp(_mm_sub_ps(_mm_setzero_ps(), _mm_loadu_ps(b + i)));
        _mm_storeu_ps(out + i, _mm_mul_ps(_mm_loadu_ps(a + i), _mm_div_ps(one, _mm_add_ps(one, e))));
    }
    for (; i < n; ++i) out[i] = a[i] * (1.0f / (1.0f + exp1(0.0f - b[i])));
}

ORE_SSE
static void softmax_sse(float * s, int n) {
    float mx = s[0];
    for (int i = 1; i < n; ++i) {
        if (s[i] > mx) mx = s[i];
    }
    const __m128 vmx = _mm_set1_ps(mx);
    __m128       a[4];
    for (int j = 0; j < 4; ++j) a[j] = _mm_setzero_ps();
    int i = 0;
    for (; i + 16 <= n; i += 16) {
        for (int j = 0; j < 4; ++j) {
            const __m128 e = vexp(_mm_sub_ps(_mm_loadu_ps(s + i + 4 * j), vmx));
            _mm_storeu_ps(s + i + 4 * j, e);
            a[j] = _mm_add_ps(a[j], e);
        }
    }
    float tail[16] = { 0 };
    for (int j = 0; i + j < n; ++j) {
        s[i + j] = exp1(s[i + j] - mx);
        tail[j]  = s[i + j];
    }
    for (int j = 0; j < 4; ++j) a[j] = _mm_add_ps(a[j], _mm_loadu_ps(tail + 4 * j));
    const float  inv  = 1.0f / sum16v(a[0], a[1], a[2], a[3]);
    const __m128 vinv = _mm_set1_ps(inv);
    for (i = 0; i + 4 <= n; i += 4) _mm_storeu_ps(s + i, _mm_mul_ps(_mm_loadu_ps(s + i), vinv));
    for (; i < n; ++i) s[i] = s[i] * inv;
}

ORE_SSE ORE_INLINE __m128 taps_sum(const float * const * taps, const float * w, int k, int n, int c) {
    __m128 acc = _mm_setzero_ps();
    for (int j = 0; j < k; ++j) {
        if (taps[j]) acc = _mm_add_ps(acc, _mm_mul_ps(_mm_loadu_ps(w + (size_t) j * n + c), _mm_loadu_ps(taps[j] + c)));
    }
    return acc;
}

ORE_SSE
static void dwconv_bn_silu_sse(const float * const * taps, const float * w, int k, int n, const float * scale,
                               const float * bias, float * out) {
    int c = 0;
    for (; c + 4 <= n; c += 4) {
        const __m128 acc = taps_sum(taps, w, k, n, c);
        _mm_storeu_ps(out + c, vsilu(_mm_add_ps(_mm_mul_ps(acc, _mm_loadu_ps(scale + c)), _mm_loadu_ps(bias + c))));
    }
    for (; c < n; ++c) {
        float acc = 0.0f;
        for (int j = 0; j < k; ++j) {
            if (taps[j]) acc = acc + w[(size_t) j * n + c] * taps[j][c];
        }
        const float t = acc * scale[c];
        const float u = t + bias[c];
        out[c]        = u / (1.0f + exp1(0.0f - u));
    }
}

ORE_SSE
static void dwconv_bias_sse(const float * const * taps, const float * w, int k, int n, const float * bias,
                            float * out) {
    int c = 0;
    for (; c + 4 <= n; c += 4) _mm_storeu_ps(out + c, _mm_add_ps(taps_sum(taps, w, k, n, c), _mm_loadu_ps(bias + c)));
    for (; c < n; ++c) {
        float acc = 0.0f;
        for (int j = 0; j < k; ++j) {
            if (taps[j]) acc = acc + w[(size_t) j * n + c] * taps[j][c];
        }
        out[c] = acc + bias[c];
    }
}

ORE_SSE
static void gemv_f32_sse(const float * w, int rows, int cols, const float * x, float * y) {
    for (int r = 0; r < rows; ++r) {
        const float * wr = w + (size_t) r * cols;
        __m128        a[4];
        for (int j = 0; j < 4; ++j) a[j] = _mm_setzero_ps();
        int k = 0;
        for (; k + 16 <= cols; k += 16) {
            for (int j = 0; j < 4; ++j) {
                a[j] = _mm_add_ps(a[j], _mm_mul_ps(_mm_loadu_ps(wr + k + 4 * j), _mm_loadu_ps(x + k + 4 * j)));
            }
        }
        if (k < cols) {
            float tw[16] = { 0 }, tx[16] = { 0 };
            for (int j = 0; k + j < cols; ++j) {
                tw[j] = wr[k + j];
                tx[j] = x[k + j];
            }
            for (int j = 0; j < 4; ++j) a[j] = _mm_add_ps(a[j], _mm_mul_ps(_mm_loadu_ps(tw + 4 * j), _mm_loadu_ps(tx + 4 * j)));
        }
        y[r] = sum16v(a[0], a[1], a[2], a[3]);
    }
}

const ore_kernels ore_kernels_sse = {
    "sse",          quantize_q8k_sse, quantize_q80_sse, gemm_q4k_sse, gemm_q80_sse,       gemm_f32_sse,
    layer_norm_sse, silu_sse,         glu_sse,          softmax_sse,  dwconv_bn_silu_sse, dwconv_bias_sse,
    gemv_f32_sse,
};

#endif  // ORE_X86
