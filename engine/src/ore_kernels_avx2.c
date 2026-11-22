// ore_kernels_avx2.c - x86-64 kernels for AVX2 + FMA + F16C (Intel from
// Haswell, 2013; AMD from Excavator and Zen), and at the end a second table
// for processors that also have AVX-512 with VNNI. Compiled for those
// instruction sets by function attributes, so the rest of the library stays
// runnable on any x86-64; a table is only picked when the processor reports
// what it needs.
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

// One 16-frame block against two weight rows, in vectors of eight frames (one
// function per number of vectors, so the last block of a clip does no more
// than it must). Four 4-bit weights are read straight from the model file,
// widened to bytes in a general register, broadcast, and multiplied with four
// columns of every frame. The 16-bit pair sums of a whole group of 32 columns
// fit in 16 bits (8 * 2 * 15 * 127 < 32768), so a group costs one 8-bit
// multiply per four columns and a single 16-bit multiply at its end, which
// applies the group scale and widens to one 32-bit sum per frame. A group sum
// of activations fits in 16 bits too, so the same multiply applies the mins.
//
// Every register has its own named variable: GCC and MSVC keep small arrays
// of vectors in memory, which made this loop three times slower.
ORE_AVX2
static void q4k_block_avx2_1(const uint8_t * w0, const uint8_t * w1, const ore_q4k_hdr * h0,
        const ore_q4k_hdr * h1, int nb, const int8_t * A, const int32_t * G, const float * D, float * o0,
        float * o1) {
    __m256 s00 = _mm256_setzero_ps();
    __m256 s10 = _mm256_setzero_ps();
    for (int b = 0; b < nb; ++b) {
        const uint8_t * q0 = w0 + (size_t) b * ORE_Q4K_BYTES + 16;
        const uint8_t * q1 = w1 + (size_t) b * ORE_Q4K_BYTES + 16;
        __m256i S00 = _mm256_setzero_si256();
        __m256i S10 = _mm256_setzero_si256();
        __m256i M00 = _mm256_setzero_si256();
        __m256i M10 = _mm256_setzero_si256();
        for (int g = 0; g < 8; ++g) {
            __m256i a00 = _mm256_setzero_si256();
            __m256i a10 = _mm256_setzero_si256();
            // Groups 2j and 2j + 1 are the low and high halves of the same 32 bytes.
            const uint8_t * p0 = q0 + (g >> 1) * 32;
            const uint8_t * p1 = q1 + (g >> 1) * 32;
            const int       sh = (g & 1) * 4;
            const int8_t *  Ag = A + ((size_t) b * 64 + (size_t) g * 8) * 64;
            for (int c = 0; c < 8; ++c) {
                uint32_t v0, v1;
                memcpy(&v0, p0 + 4 * c, 4);
                memcpy(&v1, p1 + 4 * c, 4);
                const __m256i wb0 = _mm256_set1_epi32((int) ((v0 >> sh) & 0x0f0f0f0fu));
                const __m256i wb1 = _mm256_set1_epi32((int) ((v1 >> sh) & 0x0f0f0f0fu));
                const __m256i x0 = _mm256_loadu_si256((const __m256i *) (Ag + c * 64));
                a00 = _mm256_add_epi16(a00, _mm256_maddubs_epi16(wb0, x0));
                a10 = _mm256_add_epi16(a10, _mm256_maddubs_epi16(wb1, x0));
            }
            const __m256i sc0 = _mm256_set1_epi32((int) h0[b].sm[g] * 0x10001);
            const __m256i mn0 = _mm256_set1_epi32((int) h0[b].sm[8 + g]);
            const __m256i sc1 = _mm256_set1_epi32((int) h1[b].sm[g] * 0x10001);
            const __m256i mn1 = _mm256_set1_epi32((int) h1[b].sm[8 + g]);
            const int32_t * Gg = G + ((size_t) b * 8 + g) * ORE_FB;
            const __m256i g0 = _mm256_loadu_si256((const __m256i *) (Gg));
            S00 = _mm256_add_epi32(S00, _mm256_madd_epi16(a00, sc0));
            M00 = _mm256_add_epi32(M00, _mm256_madd_epi16(g0, mn0));
            S10 = _mm256_add_epi32(S10, _mm256_madd_epi16(a10, sc1));
            M10 = _mm256_add_epi32(M10, _mm256_madd_epi16(g0, mn1));
        }
        const float * Db = D + (size_t) b * ORE_FB;
        const __m256 dx0 = _mm256_loadu_ps(Db);
        s00 = _mm256_fnmadd_ps(_mm256_mul_ps(dx0, _mm256_set1_ps(h0[b].dmin)), _mm256_cvtepi32_ps(M00), s00);
        s00 = _mm256_fmadd_ps(_mm256_mul_ps(dx0, _mm256_set1_ps(h0[b].d)), _mm256_cvtepi32_ps(S00), s00);
        s10 = _mm256_fnmadd_ps(_mm256_mul_ps(dx0, _mm256_set1_ps(h1[b].dmin)), _mm256_cvtepi32_ps(M10), s10);
        s10 = _mm256_fmadd_ps(_mm256_mul_ps(dx0, _mm256_set1_ps(h1[b].d)), _mm256_cvtepi32_ps(S10), s10);
    }
    _mm256_storeu_ps(o0, s00);
    _mm256_storeu_ps(o1, s10);
}

ORE_AVX2
static void q4k_block_avx2_2(const uint8_t * w0, const uint8_t * w1, const ore_q4k_hdr * h0,
        const ore_q4k_hdr * h1, int nb, const int8_t * A, const int32_t * G, const float * D, float * o0,
        float * o1) {
    __m256 s00 = _mm256_setzero_ps(), s01 = _mm256_setzero_ps();
    __m256 s10 = _mm256_setzero_ps(), s11 = _mm256_setzero_ps();
    for (int b = 0; b < nb; ++b) {
        const uint8_t * q0 = w0 + (size_t) b * ORE_Q4K_BYTES + 16;
        const uint8_t * q1 = w1 + (size_t) b * ORE_Q4K_BYTES + 16;
        __m256i S00 = _mm256_setzero_si256(), S01 = _mm256_setzero_si256();
        __m256i S10 = _mm256_setzero_si256(), S11 = _mm256_setzero_si256();
        __m256i M00 = _mm256_setzero_si256(), M01 = _mm256_setzero_si256();
        __m256i M10 = _mm256_setzero_si256(), M11 = _mm256_setzero_si256();
        for (int g = 0; g < 8; ++g) {
            __m256i a00 = _mm256_setzero_si256(), a01 = _mm256_setzero_si256();
            __m256i a10 = _mm256_setzero_si256(), a11 = _mm256_setzero_si256();
            // Groups 2j and 2j + 1 are the low and high halves of the same 32 bytes.
            const uint8_t * p0 = q0 + (g >> 1) * 32;
            const uint8_t * p1 = q1 + (g >> 1) * 32;
            const int       sh = (g & 1) * 4;
            const int8_t *  Ag = A + ((size_t) b * 64 + (size_t) g * 8) * 64;
            for (int c = 0; c < 8; ++c) {
                uint32_t v0, v1;
                memcpy(&v0, p0 + 4 * c, 4);
                memcpy(&v1, p1 + 4 * c, 4);
                const __m256i wb0 = _mm256_set1_epi32((int) ((v0 >> sh) & 0x0f0f0f0fu));
                const __m256i wb1 = _mm256_set1_epi32((int) ((v1 >> sh) & 0x0f0f0f0fu));
                const __m256i x0 = _mm256_loadu_si256((const __m256i *) (Ag + c * 64));
                a00 = _mm256_add_epi16(a00, _mm256_maddubs_epi16(wb0, x0));
                a10 = _mm256_add_epi16(a10, _mm256_maddubs_epi16(wb1, x0));
                const __m256i x1 = _mm256_loadu_si256((const __m256i *) (Ag + c * 64 + 32));
                a01 = _mm256_add_epi16(a01, _mm256_maddubs_epi16(wb0, x1));
                a11 = _mm256_add_epi16(a11, _mm256_maddubs_epi16(wb1, x1));
            }
            const __m256i sc0 = _mm256_set1_epi32((int) h0[b].sm[g] * 0x10001);
            const __m256i mn0 = _mm256_set1_epi32((int) h0[b].sm[8 + g]);
            const __m256i sc1 = _mm256_set1_epi32((int) h1[b].sm[g] * 0x10001);
            const __m256i mn1 = _mm256_set1_epi32((int) h1[b].sm[8 + g]);
            const int32_t * Gg = G + ((size_t) b * 8 + g) * ORE_FB;
            const __m256i g0 = _mm256_loadu_si256((const __m256i *) (Gg));
            S00 = _mm256_add_epi32(S00, _mm256_madd_epi16(a00, sc0));
            M00 = _mm256_add_epi32(M00, _mm256_madd_epi16(g0, mn0));
            S10 = _mm256_add_epi32(S10, _mm256_madd_epi16(a10, sc1));
            M10 = _mm256_add_epi32(M10, _mm256_madd_epi16(g0, mn1));
            const __m256i g1 = _mm256_loadu_si256((const __m256i *) (Gg + 8));
            S01 = _mm256_add_epi32(S01, _mm256_madd_epi16(a01, sc0));
            M01 = _mm256_add_epi32(M01, _mm256_madd_epi16(g1, mn0));
            S11 = _mm256_add_epi32(S11, _mm256_madd_epi16(a11, sc1));
            M11 = _mm256_add_epi32(M11, _mm256_madd_epi16(g1, mn1));
        }
        const float * Db = D + (size_t) b * ORE_FB;
        const __m256 dx0 = _mm256_loadu_ps(Db);
        s00 = _mm256_fnmadd_ps(_mm256_mul_ps(dx0, _mm256_set1_ps(h0[b].dmin)), _mm256_cvtepi32_ps(M00), s00);
        s00 = _mm256_fmadd_ps(_mm256_mul_ps(dx0, _mm256_set1_ps(h0[b].d)), _mm256_cvtepi32_ps(S00), s00);
        s10 = _mm256_fnmadd_ps(_mm256_mul_ps(dx0, _mm256_set1_ps(h1[b].dmin)), _mm256_cvtepi32_ps(M10), s10);
        s10 = _mm256_fmadd_ps(_mm256_mul_ps(dx0, _mm256_set1_ps(h1[b].d)), _mm256_cvtepi32_ps(S10), s10);
        const __m256 dx1 = _mm256_loadu_ps(Db + 8);
        s01 = _mm256_fnmadd_ps(_mm256_mul_ps(dx1, _mm256_set1_ps(h0[b].dmin)), _mm256_cvtepi32_ps(M01), s01);
        s01 = _mm256_fmadd_ps(_mm256_mul_ps(dx1, _mm256_set1_ps(h0[b].d)), _mm256_cvtepi32_ps(S01), s01);
        s11 = _mm256_fnmadd_ps(_mm256_mul_ps(dx1, _mm256_set1_ps(h1[b].dmin)), _mm256_cvtepi32_ps(M11), s11);
        s11 = _mm256_fmadd_ps(_mm256_mul_ps(dx1, _mm256_set1_ps(h1[b].d)), _mm256_cvtepi32_ps(S11), s11);
    }
    _mm256_storeu_ps(o0, s00);
    _mm256_storeu_ps(o1, s10);
    _mm256_storeu_ps(o0 + 8, s01);
    _mm256_storeu_ps(o1 + 8, s11);
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
        ore_q4k_decode_row(w0, nb, h0);
        ore_q4k_decode_row(w1, nb, h1);
        for (int tb = 0; tb < x->ntb; ++tb) {
            const int       valid = ORE_MIN(ORE_FB, x->rows - tb * ORE_FB);
            const int8_t *  A     = x->q + (size_t) tb * n4 * 64;
            const int32_t * G     = x->gs + (size_t) tb * nb * 8 * ORE_FB;
            const float *   D     = x->d + (size_t) tb * nb * ORE_FB;
            float           o0[16], o1[16];
            if (valid > 8) {
                q4k_block_avx2_2(w0, w1, h0, h1, nb, A, G, D, o0, o1);
            } else {
                q4k_block_avx2_1(w0, w1, h0, h1, nb, A, G, D, o0, o1);
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
// signed * signed goes through the unsigned * signed multiply: |w| times x
// with w's sign.
ORE_AVX2
static void gemm_q80_avx2(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y, size_t ystride) {
    const int    nb = n_in / 32;
    const size_t rb = (size_t) nb * ORE_Q80_BYTES;
    const size_t n4 = (size_t) n_in / 4;
    const __m256i ones = _mm256_set1_epi16(1);
    for (int r = r0; r < r1; r += 2) {
        const int       pair = r + 1 < r1;
        const uint8_t * w0   = w + (size_t) r * rb;
        const uint8_t * w1   = pair ? w0 + rb : w0;
        for (int tb = 0; tb < x->ntb; ++tb) {
            const int      valid = ORE_MIN(ORE_FB, x->rows - tb * ORE_FB);
            const int8_t * A     = x->q + (size_t) tb * n4 * 64;
            const float *  D     = x->d + (size_t) tb * nb * ORE_FB;
            __m256 s00 = _mm256_setzero_ps(), s01 = _mm256_setzero_ps();
            __m256 s10 = _mm256_setzero_ps(), s11 = _mm256_setzero_ps();
            for (int b = 0; b < nb; ++b) {
                const uint8_t * k0 = w0 + (size_t) b * ORE_Q80_BYTES;
                const uint8_t * k1 = w1 + (size_t) b * ORE_Q80_BYTES;
                __m256i a00 = _mm256_setzero_si256(), a01 = _mm256_setzero_si256();
                __m256i a10 = _mm256_setzero_si256(), a11 = _mm256_setzero_si256();
                for (int c = 0; c < 8; ++c) {
                    const int8_t * Ac = A + ((size_t) b * 8 + c) * 64;
                    uint32_t       v0, v1;
                    memcpy(&v0, k0 + 2 + 4 * c, 4);
                    memcpy(&v1, k1 + 2 + 4 * c, 4);
                    const __m256i wb0 = _mm256_set1_epi32((int) v0);
                    const __m256i wb1 = _mm256_set1_epi32((int) v1);
                    const __m256i wa0 = _mm256_abs_epi8(wb0), wa1 = _mm256_abs_epi8(wb1);
                    const __m256i x0 = _mm256_loadu_si256((const __m256i *) (Ac));
                    a00 = _mm256_add_epi32(a00, _mm256_madd_epi16(_mm256_maddubs_epi16(wa0, _mm256_sign_epi8(x0, wb0)), ones));
                    a10 = _mm256_add_epi32(a10, _mm256_madd_epi16(_mm256_maddubs_epi16(wa1, _mm256_sign_epi8(x0, wb1)), ones));
                    const __m256i x1 = _mm256_loadu_si256((const __m256i *) (Ac + 32));
                    a01 = _mm256_add_epi32(a01, _mm256_madd_epi16(_mm256_maddubs_epi16(wa0, _mm256_sign_epi8(x1, wb0)), ones));
                    a11 = _mm256_add_epi32(a11, _mm256_madd_epi16(_mm256_maddubs_epi16(wa1, _mm256_sign_epi8(x1, wb1)), ones));
                }
                const float   dw0 = ore_f16_to_f32(ore_rd16(k0)), dw1 = ore_f16_to_f32(ore_rd16(k1));
                const float * Db  = D + (size_t) b * ORE_FB;
                const __m256 dx0 = _mm256_loadu_ps(Db);
                s00 = _mm256_fmadd_ps(_mm256_cvtepi32_ps(a00), _mm256_mul_ps(dx0, _mm256_set1_ps(dw0)), s00);
                s10 = _mm256_fmadd_ps(_mm256_cvtepi32_ps(a10), _mm256_mul_ps(dx0, _mm256_set1_ps(dw1)), s10);
                const __m256 dx1 = _mm256_loadu_ps(Db + 8);
                s01 = _mm256_fmadd_ps(_mm256_cvtepi32_ps(a01), _mm256_mul_ps(dx1, _mm256_set1_ps(dw0)), s01);
                s11 = _mm256_fmadd_ps(_mm256_cvtepi32_ps(a11), _mm256_mul_ps(dx1, _mm256_set1_ps(dw1)), s11);
            }
            float o0[16], o1[16];
            _mm256_storeu_ps(o0, s00);
            _mm256_storeu_ps(o1, s10);
            _mm256_storeu_ps(o0 + 8, s01);
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

// Six weight rows against a block of 16 frames (two vectors of eight): each
// weight is broadcast and multiplied into the frame vectors, so every output
// accumulates in order of k. Twelve independent sums keep both multiply-add
// units busy.
#define ORE_F32_ROWS 6
ORE_AVX2
static void gemm_f32_avx2(const void * w, int w_is_f16, size_t wstride, int n_in, int r0, int r1, const float * xp,
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
                for (; k + 8 <= n_in; k += 8) {
                    _mm256_storeu_ps(dst + k, _mm256_cvtph_ps(_mm_loadu_si128((const __m128i *) (h + k))));
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
            __m256 c00 = _mm256_setzero_ps(), c01 = _mm256_setzero_ps();
            __m256 c10 = _mm256_setzero_ps(), c11 = _mm256_setzero_ps();
            __m256 c20 = _mm256_setzero_ps(), c21 = _mm256_setzero_ps();
            __m256 c30 = _mm256_setzero_ps(), c31 = _mm256_setzero_ps();
            __m256 c40 = _mm256_setzero_ps(), c41 = _mm256_setzero_ps();
            __m256 c50 = _mm256_setzero_ps(), c51 = _mm256_setzero_ps();
            for (int k = 0; k < n_in; ++k) {
                const float * xk = xb + (size_t) k * ORE_FB;
                const __m256 x0 = _mm256_loadu_ps(xk);
                const __m256 x1 = _mm256_loadu_ps(xk + 8);
                const __m256 v0 = _mm256_broadcast_ss(w0 + k);
                c00 = _mm256_fmadd_ps(v0, x0, c00);
                c01 = _mm256_fmadd_ps(v0, x1, c01);
                const __m256 v1 = _mm256_broadcast_ss(w1 + k);
                c10 = _mm256_fmadd_ps(v1, x0, c10);
                c11 = _mm256_fmadd_ps(v1, x1, c11);
                const __m256 v2 = _mm256_broadcast_ss(w2 + k);
                c20 = _mm256_fmadd_ps(v2, x0, c20);
                c21 = _mm256_fmadd_ps(v2, x1, c21);
                const __m256 v3 = _mm256_broadcast_ss(w3 + k);
                c30 = _mm256_fmadd_ps(v3, x0, c30);
                c31 = _mm256_fmadd_ps(v3, x1, c31);
                const __m256 v4 = _mm256_broadcast_ss(w4 + k);
                c40 = _mm256_fmadd_ps(v4, x0, c40);
                c41 = _mm256_fmadd_ps(v4, x1, c41);
                const __m256 v5 = _mm256_broadcast_ss(w5 + k);
                c50 = _mm256_fmadd_ps(v5, x0, c50);
                c51 = _mm256_fmadd_ps(v5, x1, c51);
            }
            const int valid = ORE_MIN(ORE_FB, rows - tb * ORE_FB);
            float     out[6][16];
            _mm256_storeu_ps(out[0], c00);
            _mm256_storeu_ps(out[0] + 8, c01);
            _mm256_storeu_ps(out[1], c10);
            _mm256_storeu_ps(out[1] + 8, c11);
            _mm256_storeu_ps(out[2], c20);
            _mm256_storeu_ps(out[2] + 8, c21);
            _mm256_storeu_ps(out[3], c30);
            _mm256_storeu_ps(out[3] + 8, c31);
            _mm256_storeu_ps(out[4], c40);
            _mm256_storeu_ps(out[4] + 8, c41);
            _mm256_storeu_ps(out[5], c50);
            _mm256_storeu_ps(out[5] + 8, c51);
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

// Four rows at a time, so eight sums run side by side; each row is summed
// exactly as the reference sums it.
ORE_AVX2
static void gemv_f32_avx2(const float * w, int rows, int cols, const float * x, float * y) {
    const int full = cols & ~15;
    float     tx[16] = { 0 };
    for (int j = 0; full + j < cols; ++j) tx[j] = x[full + j];
    for (int r = 0; r < rows; r += 4) {
        const int     nr = ORE_MIN(4, rows - r);
        const float * w0 = w + (size_t) r * cols;
        const float * w1 = w + (size_t) (r + ORE_MIN(1, nr - 1)) * cols;
        const float * w2 = w + (size_t) (r + ORE_MIN(2, nr - 1)) * cols;
        const float * w3 = w + (size_t) (r + ORE_MIN(3, nr - 1)) * cols;
        __m256        a00 = _mm256_setzero_ps(), a01 = a00, a10 = a00, a11 = a00;
        __m256        a20 = a00, a21 = a00, a30 = a00, a31 = a00;
#define ORE_GEMV_STEP(W0, W1, W2, W3, X)                                   \
    {                                                                      \
        const __m256 x0 = _mm256_loadu_ps(X), x1 = _mm256_loadu_ps(X + 8); \
        a00 = _mm256_fmadd_ps(_mm256_loadu_ps(W0), x0, a00);               \
        a01 = _mm256_fmadd_ps(_mm256_loadu_ps(W0 + 8), x1, a01);           \
        a10 = _mm256_fmadd_ps(_mm256_loadu_ps(W1), x0, a10);               \
        a11 = _mm256_fmadd_ps(_mm256_loadu_ps(W1 + 8), x1, a11);           \
        a20 = _mm256_fmadd_ps(_mm256_loadu_ps(W2), x0, a20);               \
        a21 = _mm256_fmadd_ps(_mm256_loadu_ps(W2 + 8), x1, a21);           \
        a30 = _mm256_fmadd_ps(_mm256_loadu_ps(W3), x0, a30);               \
        a31 = _mm256_fmadd_ps(_mm256_loadu_ps(W3 + 8), x1, a31);           \
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
        y[r] = sum16v(a00, a01);
        if (nr > 1) y[r + 1] = sum16v(a10, a11);
        if (nr > 2) y[r + 2] = sum16v(a20, a21);
        if (nr > 3) y[r + 3] = sum16v(a30, a31);
    }
}

const ore_kernels ore_kernels_avx2 = {
    "avx2",          quantize_q8k_avx2, quantize_q80_avx2, gemm_q4k_avx2, gemm_q80_avx2, gemm_f32_avx2,
    layer_norm_avx2, silu_avx2,         glu_avx2,          softmax_avx2,  dwconv_bn_silu_avx2, dwconv_bias_avx2,
    gemv_f32_avx2,
};

// ---- AVX-512 with VNNI ------------------------------------------------------
//
// AMD from Zen 4 (2022) and Intel from Ice Lake (2019) where it is present. One
// instruction multiplies four 8-bit weights by four columns of all sixteen
// frames of a block and adds the products into sixteen 32-bit sums. That
// instruction takes four or five cycles to give its result back, so eight
// weight rows are worked on at once to keep the processor busy. The integers
// and the order of the float additions are the same as in every other table.
// The element-wise steps are the AVX2 ones.

#if defined(_MSC_VER)
#define ORE_AVX512
#else
#define ORE_AVX512 __attribute__((target("avx512f,avx512bw,avx512vl,avx512vnni,avx2,fma,f16c")))
#endif

ORE_AVX512
static void gemm_q4k_avx512(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y,
                            size_t ystride) {
    const int    nb = n_in / 256;
    const size_t rb = (size_t) nb * ORE_Q4K_BYTES;
    const size_t n4 = (size_t) n_in / 4;
    for (int r = r0; r < r1; r += 8) {
        const int       nr = ORE_MIN(8, r1 - r);
        const uint8_t * wr[8];
        ore_q4k_hdr     h[8][ORE_Q4K_MAX_BLOCKS];
        for (int i = 0; i < 8; ++i) {
            wr[i] = w + (size_t) (r + ORE_MIN(i, nr - 1)) * rb;  // past the end: the last row again
            ore_q4k_decode_row(wr[i], nb, h[i]);
        }
        for (int tb = 0; tb < x->ntb; ++tb) {
            const int8_t *  A = x->q + (size_t) tb * n4 * 64;
            const int32_t * G = x->gs + (size_t) tb * nb * 8 * ORE_FB;
            const float *   D = x->d + (size_t) tb * nb * ORE_FB;
            __m512          s0 = _mm512_setzero_ps(), s1 = s0, s2 = s0, s3 = s0, s4 = s0, s5 = s0, s6 = s0, s7 = s0;
            for (int b = 0; b < nb; ++b) {
                const size_t qo = (size_t) b * ORE_Q4K_BYTES + 16;
                __m512i      S0 = _mm512_setzero_si512(), S1 = S0, S2 = S0, S3 = S0, S4 = S0, S5 = S0, S6 = S0, S7 = S0;
                for (int g = 0; g < 8; ++g) {
                    // Groups 2j and 2j + 1 are the low and high halves of the same 32 bytes.
                    const size_t    po = qo + (size_t) (g >> 1) * 32;
                    const int       sh = (g & 1) * 4;
                    const int8_t *  Ag = A + ((size_t) b * 64 + (size_t) g * 8) * 64;
                    const uint8_t * p0 = wr[0] + po;
                    const uint8_t * p1 = wr[1] + po;
                    const uint8_t * p2 = wr[2] + po;
                    const uint8_t * p3 = wr[3] + po;
                    const uint8_t * p4 = wr[4] + po;
                    const uint8_t * p5 = wr[5] + po;
                    const uint8_t * p6 = wr[6] + po;
                    const uint8_t * p7 = wr[7] + po;
                    __m512i a0 = _mm512_setzero_si512(), a1 = a0, a2 = a0, a3 = a0, a4 = a0, a5 = a0, a6 = a0, a7 = a0;
                    for (int c = 0; c < 8; ++c) {
                        const __m512i xv = _mm512_loadu_si512((const void *) (Ag + c * 64));
                        uint32_t      v;
                        memcpy(&v, p0 + 4 * c, 4);
                        a0 = _mm512_dpbusd_epi32(a0, _mm512_set1_epi32((int) ((v >> sh) & 0x0f0f0f0fu)), xv);
                        memcpy(&v, p1 + 4 * c, 4);
                        a1 = _mm512_dpbusd_epi32(a1, _mm512_set1_epi32((int) ((v >> sh) & 0x0f0f0f0fu)), xv);
                        memcpy(&v, p2 + 4 * c, 4);
                        a2 = _mm512_dpbusd_epi32(a2, _mm512_set1_epi32((int) ((v >> sh) & 0x0f0f0f0fu)), xv);
                        memcpy(&v, p3 + 4 * c, 4);
                        a3 = _mm512_dpbusd_epi32(a3, _mm512_set1_epi32((int) ((v >> sh) & 0x0f0f0f0fu)), xv);
                        memcpy(&v, p4 + 4 * c, 4);
                        a4 = _mm512_dpbusd_epi32(a4, _mm512_set1_epi32((int) ((v >> sh) & 0x0f0f0f0fu)), xv);
                        memcpy(&v, p5 + 4 * c, 4);
                        a5 = _mm512_dpbusd_epi32(a5, _mm512_set1_epi32((int) ((v >> sh) & 0x0f0f0f0fu)), xv);
                        memcpy(&v, p6 + 4 * c, 4);
                        a6 = _mm512_dpbusd_epi32(a6, _mm512_set1_epi32((int) ((v >> sh) & 0x0f0f0f0fu)), xv);
                        memcpy(&v, p7 + 4 * c, 4);
                        a7 = _mm512_dpbusd_epi32(a7, _mm512_set1_epi32((int) ((v >> sh) & 0x0f0f0f0fu)), xv);
                    }
                    S0 = _mm512_add_epi32(S0, _mm512_mullo_epi32(a0, _mm512_set1_epi32((int) h[0][b].sm[g])));
                    S1 = _mm512_add_epi32(S1, _mm512_mullo_epi32(a1, _mm512_set1_epi32((int) h[1][b].sm[g])));
                    S2 = _mm512_add_epi32(S2, _mm512_mullo_epi32(a2, _mm512_set1_epi32((int) h[2][b].sm[g])));
                    S3 = _mm512_add_epi32(S3, _mm512_mullo_epi32(a3, _mm512_set1_epi32((int) h[3][b].sm[g])));
                    S4 = _mm512_add_epi32(S4, _mm512_mullo_epi32(a4, _mm512_set1_epi32((int) h[4][b].sm[g])));
                    S5 = _mm512_add_epi32(S5, _mm512_mullo_epi32(a5, _mm512_set1_epi32((int) h[5][b].sm[g])));
                    S6 = _mm512_add_epi32(S6, _mm512_mullo_epi32(a6, _mm512_set1_epi32((int) h[6][b].sm[g])));
                    S7 = _mm512_add_epi32(S7, _mm512_mullo_epi32(a7, _mm512_set1_epi32((int) h[7][b].sm[g])));
                }
                __m512i M0 = _mm512_setzero_si512(), M1 = M0, M2 = M0, M3 = M0, M4 = M0, M5 = M0, M6 = M0, M7 = M0;
                for (int g = 0; g < 8; ++g) {
                    const __m512i gv = _mm512_loadu_si512((const void *) (G + ((size_t) b * 8 + g) * ORE_FB));
                    M0 = _mm512_add_epi32(M0, _mm512_mullo_epi32(gv, _mm512_set1_epi32((int) h[0][b].sm[8 + g])));
                    M1 = _mm512_add_epi32(M1, _mm512_mullo_epi32(gv, _mm512_set1_epi32((int) h[1][b].sm[8 + g])));
                    M2 = _mm512_add_epi32(M2, _mm512_mullo_epi32(gv, _mm512_set1_epi32((int) h[2][b].sm[8 + g])));
                    M3 = _mm512_add_epi32(M3, _mm512_mullo_epi32(gv, _mm512_set1_epi32((int) h[3][b].sm[8 + g])));
                    M4 = _mm512_add_epi32(M4, _mm512_mullo_epi32(gv, _mm512_set1_epi32((int) h[4][b].sm[8 + g])));
                    M5 = _mm512_add_epi32(M5, _mm512_mullo_epi32(gv, _mm512_set1_epi32((int) h[5][b].sm[8 + g])));
                    M6 = _mm512_add_epi32(M6, _mm512_mullo_epi32(gv, _mm512_set1_epi32((int) h[6][b].sm[8 + g])));
                    M7 = _mm512_add_epi32(M7, _mm512_mullo_epi32(gv, _mm512_set1_epi32((int) h[7][b].sm[8 + g])));
                }
                const __m512 dx = _mm512_loadu_ps(D + (size_t) b * ORE_FB);
                s0 = _mm512_fnmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[0][b].dmin)), _mm512_cvtepi32_ps(M0), s0);
                s0 = _mm512_fmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[0][b].d)), _mm512_cvtepi32_ps(S0), s0);
                s1 = _mm512_fnmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[1][b].dmin)), _mm512_cvtepi32_ps(M1), s1);
                s1 = _mm512_fmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[1][b].d)), _mm512_cvtepi32_ps(S1), s1);
                s2 = _mm512_fnmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[2][b].dmin)), _mm512_cvtepi32_ps(M2), s2);
                s2 = _mm512_fmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[2][b].d)), _mm512_cvtepi32_ps(S2), s2);
                s3 = _mm512_fnmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[3][b].dmin)), _mm512_cvtepi32_ps(M3), s3);
                s3 = _mm512_fmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[3][b].d)), _mm512_cvtepi32_ps(S3), s3);
                s4 = _mm512_fnmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[4][b].dmin)), _mm512_cvtepi32_ps(M4), s4);
                s4 = _mm512_fmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[4][b].d)), _mm512_cvtepi32_ps(S4), s4);
                s5 = _mm512_fnmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[5][b].dmin)), _mm512_cvtepi32_ps(M5), s5);
                s5 = _mm512_fmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[5][b].d)), _mm512_cvtepi32_ps(S5), s5);
                s6 = _mm512_fnmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[6][b].dmin)), _mm512_cvtepi32_ps(M6), s6);
                s6 = _mm512_fmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[6][b].d)), _mm512_cvtepi32_ps(S6), s6);
                s7 = _mm512_fnmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[7][b].dmin)), _mm512_cvtepi32_ps(M7), s7);
                s7 = _mm512_fmadd_ps(_mm512_mul_ps(dx, _mm512_set1_ps(h[7][b].d)), _mm512_cvtepi32_ps(S7), s7);
            }
            float o[8][16];
            _mm512_storeu_ps(o[0], s0);
            _mm512_storeu_ps(o[1], s1);
            _mm512_storeu_ps(o[2], s2);
            _mm512_storeu_ps(o[3], s3);
            _mm512_storeu_ps(o[4], s4);
            _mm512_storeu_ps(o[5], s5);
            _mm512_storeu_ps(o[6], s6);
            _mm512_storeu_ps(o[7], s7);
            const int valid = ORE_MIN(ORE_FB, x->rows - tb * ORE_FB);
            for (int i = 0; i < nr; ++i) {
                float * yr = y + (size_t) tb * ORE_FB * ystride + r + i;
                for (int f = 0; f < valid; ++f) yr[(size_t) f * ystride] = o[i][f];
            }
        }
    }
}

// signed * signed through the unsigned * signed instruction: |w| times x with
// w's sign.
ORE_AVX512
static void gemm_q80_avx512(const uint8_t * w, int n_in, int r0, int r1, const ore_qact * x, float * y,
                            size_t ystride) {
    const int     nb   = n_in / 32;
    const size_t  rb   = (size_t) nb * ORE_Q80_BYTES;
    const size_t  n4   = (size_t) n_in / 4;
    const __m512i zero = _mm512_setzero_si512();
    for (int r = r0; r < r1; r += 8) {
        const int       nr = ORE_MIN(8, r1 - r);
        const uint8_t * wr[8];
        for (int i = 0; i < 8; ++i) wr[i] = w + (size_t) (r + ORE_MIN(i, nr - 1)) * rb;
        for (int tb = 0; tb < x->ntb; ++tb) {
            const int8_t * A = x->q + (size_t) tb * n4 * 64;
            const float *  D = x->d + (size_t) tb * nb * ORE_FB;
            __m512         s0 = _mm512_setzero_ps(), s1 = s0, s2 = s0, s3 = s0, s4 = s0, s5 = s0, s6 = s0, s7 = s0;
            for (int b = 0; b < nb; ++b) {
                const size_t ko = (size_t) b * ORE_Q80_BYTES;
                const uint8_t * k0 = wr[0] + ko;
                const uint8_t * k1 = wr[1] + ko;
                const uint8_t * k2 = wr[2] + ko;
                const uint8_t * k3 = wr[3] + ko;
                const uint8_t * k4 = wr[4] + ko;
                const uint8_t * k5 = wr[5] + ko;
                const uint8_t * k6 = wr[6] + ko;
                const uint8_t * k7 = wr[7] + ko;
                __m512i a0 = zero, a1 = zero, a2 = zero, a3 = zero, a4 = zero, a5 = zero, a6 = zero, a7 = zero;
                for (int c = 0; c < 8; ++c) {
                    const __m512i xv = _mm512_loadu_si512((const void *) (A + ((size_t) b * 8 + c) * 64));
                    uint32_t      v;
                    __m512i       wb;
                    memcpy(&v, k0 + 2 + 4 * c, 4);
                    wb = _mm512_set1_epi32((int) v);
                    a0 = _mm512_dpbusd_epi32(a0, _mm512_abs_epi8(wb),
                                             _mm512_mask_sub_epi8(xv, _mm512_movepi8_mask(wb), zero, xv));
                    memcpy(&v, k1 + 2 + 4 * c, 4);
                    wb = _mm512_set1_epi32((int) v);
                    a1 = _mm512_dpbusd_epi32(a1, _mm512_abs_epi8(wb),
                                             _mm512_mask_sub_epi8(xv, _mm512_movepi8_mask(wb), zero, xv));
                    memcpy(&v, k2 + 2 + 4 * c, 4);
                    wb = _mm512_set1_epi32((int) v);
                    a2 = _mm512_dpbusd_epi32(a2, _mm512_abs_epi8(wb),
                                             _mm512_mask_sub_epi8(xv, _mm512_movepi8_mask(wb), zero, xv));
                    memcpy(&v, k3 + 2 + 4 * c, 4);
                    wb = _mm512_set1_epi32((int) v);
                    a3 = _mm512_dpbusd_epi32(a3, _mm512_abs_epi8(wb),
                                             _mm512_mask_sub_epi8(xv, _mm512_movepi8_mask(wb), zero, xv));
                    memcpy(&v, k4 + 2 + 4 * c, 4);
                    wb = _mm512_set1_epi32((int) v);
                    a4 = _mm512_dpbusd_epi32(a4, _mm512_abs_epi8(wb),
                                             _mm512_mask_sub_epi8(xv, _mm512_movepi8_mask(wb), zero, xv));
                    memcpy(&v, k5 + 2 + 4 * c, 4);
                    wb = _mm512_set1_epi32((int) v);
                    a5 = _mm512_dpbusd_epi32(a5, _mm512_abs_epi8(wb),
                                             _mm512_mask_sub_epi8(xv, _mm512_movepi8_mask(wb), zero, xv));
                    memcpy(&v, k6 + 2 + 4 * c, 4);
                    wb = _mm512_set1_epi32((int) v);
                    a6 = _mm512_dpbusd_epi32(a6, _mm512_abs_epi8(wb),
                                             _mm512_mask_sub_epi8(xv, _mm512_movepi8_mask(wb), zero, xv));
                    memcpy(&v, k7 + 2 + 4 * c, 4);
                    wb = _mm512_set1_epi32((int) v);
                    a7 = _mm512_dpbusd_epi32(a7, _mm512_abs_epi8(wb),
                                             _mm512_mask_sub_epi8(xv, _mm512_movepi8_mask(wb), zero, xv));
                }
                const __m512 dx = _mm512_loadu_ps(D + (size_t) b * ORE_FB);
                s0 = _mm512_fmadd_ps(_mm512_cvtepi32_ps(a0),
                                     _mm512_mul_ps(dx, _mm512_set1_ps(ore_f16_to_f32(ore_rd16(k0)))), s0);
                s1 = _mm512_fmadd_ps(_mm512_cvtepi32_ps(a1),
                                     _mm512_mul_ps(dx, _mm512_set1_ps(ore_f16_to_f32(ore_rd16(k1)))), s1);
                s2 = _mm512_fmadd_ps(_mm512_cvtepi32_ps(a2),
                                     _mm512_mul_ps(dx, _mm512_set1_ps(ore_f16_to_f32(ore_rd16(k2)))), s2);
                s3 = _mm512_fmadd_ps(_mm512_cvtepi32_ps(a3),
                                     _mm512_mul_ps(dx, _mm512_set1_ps(ore_f16_to_f32(ore_rd16(k3)))), s3);
                s4 = _mm512_fmadd_ps(_mm512_cvtepi32_ps(a4),
                                     _mm512_mul_ps(dx, _mm512_set1_ps(ore_f16_to_f32(ore_rd16(k4)))), s4);
                s5 = _mm512_fmadd_ps(_mm512_cvtepi32_ps(a5),
                                     _mm512_mul_ps(dx, _mm512_set1_ps(ore_f16_to_f32(ore_rd16(k5)))), s5);
                s6 = _mm512_fmadd_ps(_mm512_cvtepi32_ps(a6),
                                     _mm512_mul_ps(dx, _mm512_set1_ps(ore_f16_to_f32(ore_rd16(k6)))), s6);
                s7 = _mm512_fmadd_ps(_mm512_cvtepi32_ps(a7),
                                     _mm512_mul_ps(dx, _mm512_set1_ps(ore_f16_to_f32(ore_rd16(k7)))), s7);
            }
            float o[8][16];
            _mm512_storeu_ps(o[0], s0);
            _mm512_storeu_ps(o[1], s1);
            _mm512_storeu_ps(o[2], s2);
            _mm512_storeu_ps(o[3], s3);
            _mm512_storeu_ps(o[4], s4);
            _mm512_storeu_ps(o[5], s5);
            _mm512_storeu_ps(o[6], s6);
            _mm512_storeu_ps(o[7], s7);
            const int valid = ORE_MIN(ORE_FB, x->rows - tb * ORE_FB);
            for (int i = 0; i < nr; ++i) {
                float * yr = y + (size_t) tb * ORE_FB * ystride + r + i;
                for (int f = 0; f < valid; ++f) yr[(size_t) f * ystride] = o[i][f];
            }
        }
    }
}

// Six weight rows against a block of 16 frames in one register each.
ORE_AVX512
static void gemm_f32_avx512(const void * w, int w_is_f16, size_t wstride, int n_in, int r0, int r1, const float * xp,
                            int rows, float * y, size_t ystride, float * scratch) {
    const int ntb = ore_frame_blocks(rows);
    for (int r = r0; r < r1; r += 6) {
        const int     nr = ORE_MIN(6, r1 - r);
        const float * wr[6];
        for (int i = 0; i < 6; ++i) {
            const int ri = r + ORE_MIN(i, nr - 1);
            if (w_is_f16) {
                const uint16_t * hw  = (const uint16_t *) w + (size_t) ri * wstride;
                float *          dst = scratch + (size_t) i * n_in;
                int              k   = 0;
                for (; k + 8 <= n_in; k += 8) {
                    _mm256_storeu_ps(dst + k, _mm256_cvtph_ps(_mm_loadu_si128((const __m128i *) (hw + k))));
                }
                for (; k < n_in; ++k) dst[k] = ore_f16_to_f32(hw[k]);
                wr[i] = dst;
            } else {
                wr[i] = (const float *) w + (size_t) ri * wstride;
            }
        }
        const float * w0 = wr[0], *w1 = wr[1], *w2 = wr[2], *w3 = wr[3], *w4 = wr[4], *w5 = wr[5];
        for (int tb = 0; tb < ntb; ++tb) {
            const float * xb = xp + (size_t) tb * n_in * ORE_FB;
            __m512        c0 = _mm512_setzero_ps(), c1 = c0, c2 = c0, c3 = c0, c4 = c0, c5 = c0;
            for (int k = 0; k < n_in; ++k) {
                const __m512 xk = _mm512_loadu_ps(xb + (size_t) k * ORE_FB);
                c0 = _mm512_fmadd_ps(_mm512_set1_ps(w0[k]), xk, c0);
                c1 = _mm512_fmadd_ps(_mm512_set1_ps(w1[k]), xk, c1);
                c2 = _mm512_fmadd_ps(_mm512_set1_ps(w2[k]), xk, c2);
                c3 = _mm512_fmadd_ps(_mm512_set1_ps(w3[k]), xk, c3);
                c4 = _mm512_fmadd_ps(_mm512_set1_ps(w4[k]), xk, c4);
                c5 = _mm512_fmadd_ps(_mm512_set1_ps(w5[k]), xk, c5);
            }
            float o[6][16];
            _mm512_storeu_ps(o[0], c0);
            _mm512_storeu_ps(o[1], c1);
            _mm512_storeu_ps(o[2], c2);
            _mm512_storeu_ps(o[3], c3);
            _mm512_storeu_ps(o[4], c4);
            _mm512_storeu_ps(o[5], c5);
            const int valid = ORE_MIN(ORE_FB, rows - tb * ORE_FB);
            for (int i = 0; i < nr; ++i) {
                float * yr = y + (size_t) tb * ORE_FB * ystride + r + i;
                for (int f = 0; f < valid; ++f) yr[(size_t) f * ystride] = o[i][f];
            }
        }
    }
}

const ore_kernels ore_kernels_avx512 = {
    "avx512",        quantize_q8k_avx2, quantize_q80_avx2, gemm_q4k_avx512, gemm_q80_avx512,     gemm_f32_avx512,
    layer_norm_avx2, silu_avx2,         glu_avx2,          softmax_avx2,    dwconv_bn_silu_avx2, dwconv_bias_avx2,
    gemv_f32_avx2,
};

// The same table with the 256-bit float product, for processors that run a
// 512-bit instruction as two 256-bit halves (AMD's Zen 4). The 512-bit float
// kernel gains nothing there, and as MSVC compiles it, it is slower: 33
// against 43 billion multiply-adds a second on an EPYC 9V74.
const ore_kernels ore_kernels_avx512_f256 = {
    "avx512+avx2",   quantize_q8k_avx2, quantize_q80_avx2, gemm_q4k_avx512, gemm_q80_avx512,     gemm_f32_avx2,
    layer_norm_avx2, silu_avx2,         glu_avx2,          softmax_avx2,    dwconv_bn_silu_avx2, dwconv_bias_avx2,
    gemv_f32_avx2,
};

#endif  // ORE_X86
