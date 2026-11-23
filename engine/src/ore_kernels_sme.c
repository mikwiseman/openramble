// ore_kernels_sme.c - the matrix unit of Apple's M4 and later (ledger K8).
//
// One instruction (SMOPA) adds the products of 16 weight rows and 16 frames
// over four columns into a 16 by 16 tile of 32-bit sums. The activations the
// other tables make, 16 frames by 4 columns in 64 bytes, are already one
// operand; ore_r8_make packs the weights the same way. Four tiles hold four
// 16-frame blocks, so every weight load feeds four instructions. The
// activations carry one scale per frame for every 256 columns, so after each
// 256 columns the tiles are read out frame by frame, scaled and added in
// single precision. Everything here runs in the unit's streaming mode, where
// NEON is not available, so the loops use only SVE and SME instructions and
// call nothing.
#include "ore_kernels.h"

#if ORE_HAVE_SME
#include <arm_sme.h>

#define SME __attribute__((target("sme")))

SME __arm_locally_streaming __arm_new("za") static void r8_groups(const ore_r8 * w, int g0, int g1,
                                                                    const ore_qact * x, float * y,
                                                                    size_t ystride) {
    const int      nc = w->n / 4, nb = x->nb, per = nc / x->nb;
    const svbool_t all8 = svptrue_b8(), all32 = svptrue_b32();
    float          acc[4][16][16];  // [tile][frame][row]
    for (int g = g0; g < g1; ++g) {
        const int8_t *    wg = w->q + (size_t) g * nc * 64;
        const svfloat32_t rs = svld1_f32(all32, w->scale + (size_t) g * 16);
        for (int tb = 0; tb < x->ntb; tb += 4) {
            const int      tiles = x->ntb - tb < 4 ? x->ntb - tb : 4;
            const int8_t * x0    = x->q + (size_t) tb * nc * 64;
            const int8_t * x1    = x0 + (size_t) nc * 64;
            const int8_t * x2    = x1 + (size_t) nc * 64;
            const int8_t * x3    = x2 + (size_t) nc * 64;
            for (int b = 0; b < nb; ++b) {
                svzero_za();
                for (int c = b * per; c < (b + 1) * per; ++c) {
                    const svint8_t wv = svld1_s8(all8, wg + (size_t) c * 64);
                    svmopa_za32_s8_m(0, all8, all8, wv, svld1_s8(all8, x0 + (size_t) c * 64));
                    if (tiles > 1) svmopa_za32_s8_m(1, all8, all8, wv, svld1_s8(all8, x1 + (size_t) c * 64));
                    if (tiles > 2) svmopa_za32_s8_m(2, all8, all8, wv, svld1_s8(all8, x2 + (size_t) c * 64));
                    if (tiles > 3) svmopa_za32_s8_m(3, all8, all8, wv, svld1_s8(all8, x3 + (size_t) c * 64));
                }
                // Column j of a tile is frame j's 16 rows.
#define ORE_R8_READ(t)                                                                                   \
    if (tiles > t) {                                                                                     \
        const float * d = x->d + ((size_t) (tb + t) * x->nb + b) * 16;                                   \
        for (int j = 0; j < 16; ++j) {                                                                   \
            const svfloat32_t v = svcvt_f32_s32_x(all32, svread_ver_za32_s32_m(svdup_n_s32(0), all32, t, j)); \
            const svfloat32_t a = b ? svld1_f32(all32, acc[t][j]) : svdup_n_f32(0.0f);                  \
            svst1_f32(all32, acc[t][j], svmla_n_f32_x(all32, a, v, d[j]));                              \
        }                                                                                                \
    }
                ORE_R8_READ(0)
                ORE_R8_READ(1)
                ORE_R8_READ(2)
                ORE_R8_READ(3)
#undef ORE_R8_READ
            }
            for (int t = 0; t < tiles; ++t) {
                for (int j = 0; j < 16; ++j) {
                    const int f = (tb + t) * 16 + j;
                    if (f >= x->rows) break;
                    svst1_f32(all32, y + (size_t) f * ystride + (size_t) g * 16,
                              svmul_f32_x(all32, svld1_f32(all32, acc[t][j]), rs));
                }
            }
        }
    }
}

void ore_gemm_r8_sme(const ore_r8 * w, int r0, int r1, const ore_qact * x, float * y, size_t ystride) {
    r8_groups(w, r0 / 16, r1 / 16, x, y, ystride);
}

#endif  // ORE_HAVE_SME
