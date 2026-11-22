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

ORE_AVX2
static void quantize_q8k_avx2(const float * x, size_t xstride, int t0, int t1, ore_q8k * out) {
    const int n = out->n, nb = out->nb;
    for (int t = t0; t < t1; ++t) {
        const float * row = x + (size_t) t * xstride;
        int8_t *      q   = out->q + (size_t) t * n;
        for (int b = 0; b < nb; ++b) {
            const float * p  = row + b * 256;
            int8_t *      qb = q + b * 256;
            __m256        mx = _mm256_loadu_ps(p), mn = mx;
            for (int j = 8; j < 256; j += 8) {
                const __m256 v = _mm256_loadu_ps(p + j);
                mx             = _mm256_max_ps(mx, v);
                mn             = _mm256_min_ps(mn, v);
            }
            const float vmax = hmax256(mx), vmin = hmin256(mn);
            const float m    = (-vmin > vmax) ? vmin : vmax;
            int16_t *   gs   = out->gs + ((size_t) b * out->rows_pad + t) * 8;
            float *     d    = out->d + (size_t) b * out->rows_pad + t;
            if (m == 0.0f) {
                memset(qb, 0, 256);
                memset(gs, 0, 8 * sizeof(int16_t));
                *d = 0.0f;
                continue;
            }
            const float  iscale = -127.f / m;
            const __m256 vs     = _mm256_set1_ps(iscale);
            for (int g = 0; g < 8; ++g) {
                const __m256i qv = round32(p + g * 32, vs);
                _mm256_storeu_si256((__m256i *) (qb + g * 32), qv);
                // sum of 32 int8
                const __m256i p16 = _mm256_maddubs_epi16(_mm256_set1_epi8(1), qv);
                const __m256i p32 = _mm256_madd_epi16(p16, _mm256_set1_epi16(1));
                __m128i       s   = _mm_add_epi32(_mm256_castsi256_si128(p32), _mm256_extracti128_si256(p32, 1));
                s                 = _mm_add_epi32(s, _mm_shuffle_epi32(s, 0x4e));
                s                 = _mm_add_epi32(s, _mm_shuffle_epi32(s, 0xb1));
                gs[g]             = (int16_t) _mm_cvtsi128_si32(s);
            }
            *d = 1.0f / iscale;
        }
    }
}

ORE_AVX2
static void quantize_q80_avx2(const float * x, size_t xstride, int t0, int t1, ore_q80 * out) {
    const int    n = out->n, nb = out->nb;
    const __m256 absmask = _mm256_castsi256_ps(_mm256_set1_epi32(0x7fffffff));
    for (int t = t0; t < t1; ++t) {
        const float * row = x + (size_t) t * xstride;
        int8_t *      q   = out->q + (size_t) t * n;
        float *       d   = out->d + (size_t) t * nb;
        for (int b = 0; b < nb; ++b) {
            const float * p  = row + b * 32;
            __m256        am = _mm256_and_ps(_mm256_loadu_ps(p), absmask);
            am               = _mm256_max_ps(am, _mm256_and_ps(_mm256_loadu_ps(p + 8), absmask));
            am               = _mm256_max_ps(am, _mm256_and_ps(_mm256_loadu_ps(p + 16), absmask));
            am               = _mm256_max_ps(am, _mm256_and_ps(_mm256_loadu_ps(p + 24), absmask));
            const float amax = hmax256(am);
            const float dd   = amax / 127.0f;
            const float id   = dd != 0.0f ? 1.0f / dd : 0.0f;
            d[b] = _mm_cvtss_f32(_mm_cvtph_ps(_mm_cvtps_ph(_mm_set_ss(dd), _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC)));
            _mm256_storeu_si256((__m256i *) (q + b * 32), round32(p, _mm256_set1_ps(id)));
        }
    }
}

// ---- Q4_K product -----------------------------------------------------------

// Two weight rows against four frames. A group of 32 four-bit weights is one
// register; `maddubs` multiplies it with a frame's 32 values and `madd` applies
// the group scale while widening, so a group costs three instructions per
// (row, frame) pair.
ORE_AVX2
static void gemm_q4k_avx2(const uint8_t * w, int n_in, int r0, int r1, const ore_q8k * x, float * y, size_t ystride) {
    const int     nb = n_in / 256;
    const size_t  rb = (size_t) nb * ORE_Q4K_BYTES;
    const int     T  = x->rows;
    const int     n  = x->n;
    const size_t  tp = (size_t) x->rows_pad;
    const __m256i m4 = _mm256_set1_epi8(0x0f);

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
            __m128         sum0 = _mm_setzero_ps(), sum1 = _mm_setzero_ps();
            for (int b = 0; b < nb; ++b) {
                const uint8_t * q0 = w0 + (size_t) b * ORE_Q4K_BYTES + 16;
                const uint8_t * q1 = w1 + (size_t) b * ORE_Q4K_BYTES + 16;
                const int8_t *  p0 = a0 + b * 256;
                const int8_t *  p1 = a1 + b * 256;
                const int8_t *  p2 = a2 + b * 256;
                const int8_t *  p3 = a3 + b * 256;
                __m256i         t00 = _mm256_setzero_si256(), t01 = t00, t02 = t00, t03 = t00;
                __m256i         t10 = t00, t11 = t00, t12 = t00, t13 = t00;
                for (int grp = 0; grp < 8; ++grp) {
                    const int g = grp >> 1;
                    __m256i   v0 = _mm256_loadu_si256((const __m256i *) (q0 + 32 * g));
                    __m256i   v1 = _mm256_loadu_si256((const __m256i *) (q1 + 32 * g));
                    if (grp & 1) {
                        v0 = _mm256_srli_epi16(v0, 4);
                        v1 = _mm256_srli_epi16(v1, 4);
                    }
                    v0 = _mm256_and_si256(v0, m4);
                    v1 = _mm256_and_si256(v1, m4);
                    const __m256i s0  = _mm256_set1_epi16((short) h0[b].sc[grp]);
                    const __m256i s1  = _mm256_set1_epi16((short) h1[b].sc[grp]);
                    const int     off = grp * 32;
                    __m256i       ya;
                    ya  = _mm256_loadu_si256((const __m256i *) (p0 + off));
                    t00 = _mm256_add_epi32(t00, _mm256_madd_epi16(_mm256_maddubs_epi16(v0, ya), s0));
                    t10 = _mm256_add_epi32(t10, _mm256_madd_epi16(_mm256_maddubs_epi16(v1, ya), s1));
                    ya  = _mm256_loadu_si256((const __m256i *) (p1 + off));
                    t01 = _mm256_add_epi32(t01, _mm256_madd_epi16(_mm256_maddubs_epi16(v0, ya), s0));
                    t11 = _mm256_add_epi32(t11, _mm256_madd_epi16(_mm256_maddubs_epi16(v1, ya), s1));
                    ya  = _mm256_loadu_si256((const __m256i *) (p2 + off));
                    t02 = _mm256_add_epi32(t02, _mm256_madd_epi16(_mm256_maddubs_epi16(v0, ya), s0));
                    t12 = _mm256_add_epi32(t12, _mm256_madd_epi16(_mm256_maddubs_epi16(v1, ya), s1));
                    ya  = _mm256_loadu_si256((const __m256i *) (p3 + off));
                    t03 = _mm256_add_epi32(t03, _mm256_madd_epi16(_mm256_maddubs_epi16(v0, ya), s0));
                    t13 = _mm256_add_epi32(t13, _mm256_madd_epi16(_mm256_maddubs_epi16(v1, ya), s1));
                }
                // Eight lanes each -> one int per frame.
                __m256i r0s = _mm256_hadd_epi32(_mm256_hadd_epi32(t00, t01), _mm256_hadd_epi32(t02, t03));
                __m256i r1s = _mm256_hadd_epi32(_mm256_hadd_epi32(t10, t11), _mm256_hadd_epi32(t12, t13));
                const __m128i S0 = _mm_add_epi32(_mm256_castsi256_si128(r0s), _mm256_extracti128_si256(r0s, 1));
                const __m128i S1 = _mm_add_epi32(_mm256_castsi256_si128(r1s), _mm256_extracti128_si256(r1s, 1));
                // Mins against the frames' group sums.
                const int16_t * gs  = x->gs + ((size_t) b * tp + t) * 8;
                const __m128i   g0  = _mm_loadu_si128((const __m128i *) gs);
                const __m128i   g1  = _mm_loadu_si128((const __m128i *) (gs + 8));
                const __m128i   g2  = _mm_loadu_si128((const __m128i *) (gs + 16));
                const __m128i   g3  = _mm_loadu_si128((const __m128i *) (gs + 24));
                const __m128i   m0v = _mm_loadu_si128((const __m128i *) h0[b].mn);
                const __m128i   m1v = _mm_loadu_si128((const __m128i *) h1[b].mn);
                const __m128i   M0  = _mm_hadd_epi32(_mm_hadd_epi32(_mm_madd_epi16(g0, m0v), _mm_madd_epi16(g1, m0v)),
                                                     _mm_hadd_epi32(_mm_madd_epi16(g2, m0v), _mm_madd_epi16(g3, m0v)));
                const __m128i   M1  = _mm_hadd_epi32(_mm_hadd_epi32(_mm_madd_epi16(g0, m1v), _mm_madd_epi16(g1, m1v)),
                                                     _mm_hadd_epi32(_mm_madd_epi16(g2, m1v), _mm_madd_epi16(g3, m1v)));
                const __m128    dx  = _mm_loadu_ps(x->d + (size_t) b * tp + t);
                sum0 = _mm_fnmadd_ps(_mm_mul_ps(dx, _mm_set1_ps(h0[b].dmin)), _mm_cvtepi32_ps(M0), sum0);
                sum0 = _mm_fmadd_ps(_mm_mul_ps(dx, _mm_set1_ps(h0[b].d)), _mm_cvtepi32_ps(S0), sum0);
                sum1 = _mm_fnmadd_ps(_mm_mul_ps(dx, _mm_set1_ps(h1[b].dmin)), _mm_cvtepi32_ps(M1), sum1);
                sum1 = _mm_fmadd_ps(_mm_mul_ps(dx, _mm_set1_ps(h1[b].d)), _mm_cvtepi32_ps(S1), sum1);
            }
            float s0[4], s1[4];
            _mm_storeu_ps(s0, sum0);
            _mm_storeu_ps(s1, sum1);
            const int tn = ORE_MIN(4, T - t);
            for (int c = 0; c < tn; ++c) {
                y[(size_t) (t + c) * ystride + r] = s0[c];
                if (pair) y[(size_t) (t + c) * ystride + r + 1] = s1[c];
            }
        }
    }
}

// ---- Q8_0 product -----------------------------------------------------------

// int8 * int8 over 32 columns -> the four lanes a 128-bit dot product gives.
ORE_AVX2 ORE_INLINE __m128 q80_lanes(__m256i wabs, __m256i wv, __m256i yv) {
    const __m256i p16 = _mm256_maddubs_epi16(wabs, _mm256_sign_epi8(yv, wv));
    const __m256i p32 = _mm256_madd_epi16(p16, _mm256_set1_epi16(1));
    return _mm_cvtepi32_ps(_mm_add_epi32(_mm256_castsi256_si128(p32), _mm256_extracti128_si256(p32, 1)));
}
ORE_AVX2 ORE_INLINE float q80_hsum(__m128 v) {
    const __m128 h = _mm_hadd_ps(v, v);  // [l0+l1, l2+l3, ...]
    return _mm_cvtss_f32(_mm_add_ss(h, _mm_shuffle_ps(h, h, 1)));
}

ORE_AVX2
static void gemm_q80_avx2(const uint8_t * w, int n_in, int r0, int r1, const ore_q80 * x, float * y, size_t ystride) {
    const int    nb = n_in / 32;
    const size_t rb = (size_t) nb * ORE_Q80_BYTES;
    const int    T  = x->rows;
    for (int r = r0; r < r1; r += 2) {
        const int       pair = r + 1 < r1;
        const uint8_t * w0   = w + (size_t) r * rb;
        const uint8_t * w1   = pair ? w0 + rb : w0;
        for (int t = 0; t < T; t += 2) {
            const int      two = t + 1 < T;
            const int8_t * a0  = x->q + (size_t) t * x->n;
            const int8_t * a1  = a0 + x->n;
            const float *  d0  = x->d + (size_t) t * nb;
            const float *  d1  = d0 + nb;
            __m128         c00 = _mm_setzero_ps(), c01 = c00, c10 = c00, c11 = c00;
            for (int b = 0; b < nb; ++b) {
                const uint8_t * k0  = w0 + (size_t) b * ORE_Q80_BYTES;
                const uint8_t * k1  = w1 + (size_t) b * ORE_Q80_BYTES;
                const float     dw0 = ore_f16_to_f32(ore_rd16(k0));
                const float     dw1 = ore_f16_to_f32(ore_rd16(k1));
                const __m256i   wv0 = _mm256_loadu_si256((const __m256i *) (k0 + 2));
                const __m256i   wv1 = _mm256_loadu_si256((const __m256i *) (k1 + 2));
                const __m256i   wa0 = _mm256_abs_epi8(wv0);
                const __m256i   wa1 = _mm256_abs_epi8(wv1);
                const __m256i   y0  = _mm256_loadu_si256((const __m256i *) (a0 + b * 32));
                const __m256i   y1  = _mm256_loadu_si256((const __m256i *) (a1 + b * 32));
                c00 = _mm_fmadd_ps(q80_lanes(wa0, wv0, y0), _mm_set1_ps(dw0 * d0[b]), c00);
                c01 = _mm_fmadd_ps(q80_lanes(wa0, wv0, y1), _mm_set1_ps(dw0 * d1[b]), c01);
                c10 = _mm_fmadd_ps(q80_lanes(wa1, wv1, y0), _mm_set1_ps(dw1 * d0[b]), c10);
                c11 = _mm_fmadd_ps(q80_lanes(wa1, wv1, y1), _mm_set1_ps(dw1 * d1[b]), c11);
            }
            y[(size_t) t * ystride + r] = q80_hsum(c00);
            if (two) y[(size_t) (t + 1) * ystride + r] = q80_hsum(c01);
            if (pair) {
                y[(size_t) t * ystride + r + 1] = q80_hsum(c10);
                if (two) y[(size_t) (t + 1) * ystride + r + 1] = q80_hsum(c11);
            }
        }
    }
}

// ---- float product ----------------------------------------------------------

// Four weight rows against 16 frames (two vectors of eight): each weight is
// broadcast and multiplied into the frame vectors, so every output accumulates
// in order of k.
ORE_AVX2
static void gemm_f32_avx2(const void * w, int w_is_f16, size_t wstride, int n_in, int r0, int r1, const float * xt,
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
        for (int t = 0; t < rows; t += 16) {
            const float * xp  = xt + t;
            __m256        c00 = _mm256_setzero_ps(), c01 = c00, c10 = c00, c11 = c00;
            __m256        c20 = c00, c21 = c00, c30 = c00, c31 = c00;
            for (int k = 0; k < n_in; ++k) {
                const float * xk = xp + (size_t) k * xt_stride;
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
            const int tn = ORE_MIN(16, rows - t);
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
                for (int j = 0; j < tn; ++j) y[(size_t) (t + j) * ystride + r + i] = out[i][j];
            }
        }
    }
}

const ore_kernels ore_kernels_avx2 = {
    "avx2", quantize_q8k_avx2, quantize_q80_avx2, gemm_q4k_avx2, gemm_q80_avx2, gemm_f32_avx2,
};

#endif  // ORE_X86
