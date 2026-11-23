// ore_r8.c - weights made ready for a matrix unit: 8-bit numbers with one
// scale per row, packed in tiles of 16 rows by 4 columns (see ore_kernels.h).
// Ledger E1 measured what this layout does to the words.
#include "ore_kernels.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

// ggml's dequantize_row_q4_K, for one row of n values.
static void q4k_row(const uint8_t * row, int n, float * y) {
    for (int b = 0; b < n / ORE_Q4K_BLOCK; ++b) {
        const uint8_t * blk = row + (size_t) b * ORE_Q4K_BYTES;
        uint8_t         sc[8], mn[8];
        ore_q4k_scales(blk, sc, mn);
        const float     d = ore_f16_to_f32(ore_rd16(blk)), dmin = ore_f16_to_f32(ore_rd16(blk + 2));
        const uint8_t * q = blk + 16;
        float *         out = y + (size_t) b * ORE_Q4K_BLOCK;
        for (int j = 0; j < 4; ++j) {
            const float d1 = d * sc[2 * j], m1 = dmin * mn[2 * j];
            const float d2 = d * sc[2 * j + 1], m2 = dmin * mn[2 * j + 1];
            for (int l = 0; l < 32; ++l) {
                out[64 * j + l]      = d1 * (float) (q[32 * j + l] & 0x0f) - m1;
                out[64 * j + 32 + l] = d2 * (float) (q[32 * j + l] >> 4) - m2;
            }
        }
    }
}

int ore_r8_make(ore_r8 * r, const uint8_t * w, int type, int n, int rows) {
    memset(r, 0, sizeof(*r));
    if (n <= 0 || rows <= 0 || n % ORE_Q4K_BLOCK || rows % 16) return 0;
    if (type != ORE_T_Q4_K && type != ORE_T_F16) return 0;
    r->q     = (int8_t *) ore_alloc((size_t) n * rows);
    r->scale = (float *) ore_alloc(sizeof(float) * (size_t) rows);
    float * y = (float *) malloc(sizeof(float) * (size_t) n);
    if (!r->q || !r->scale || !y) {
        free(y);
        ore_r8_free(r);
        return 0;
    }
    const size_t row_bytes = type == ORE_T_Q4_K ? (size_t) n / ORE_Q4K_BLOCK * ORE_Q4K_BYTES : (size_t) n * 2;
    for (int i = 0; i < rows; ++i) {
        const uint8_t * src = w + (size_t) i * row_bytes;
        if (type == ORE_T_Q4_K) {
            q4k_row(src, n, y);
        } else {
            for (int k = 0; k < n; ++k) y[k] = ore_f16_to_f32(ore_rd16(src + 2 * (size_t) k));
        }
        float big = 0.0f;
        for (int k = 0; k < n; ++k) big = fmaxf(big, fabsf(y[k]));
        const float scale = big / 127.0f, inv = scale > 0.0f ? 1.0f / scale : 0.0f;
        r->scale[i]       = scale;
        // Group i / 16 starts n * 16 bytes in; row i % 16 is 4 bytes of every 64.
        int8_t * dst = r->q + (size_t) (i / 16) * n * 16 + (size_t) (i % 16) * 4;
        for (int k = 0; k < n; ++k) {
            const long v                         = lrintf(y[k] * inv);
            dst[(size_t) (k / 4) * 64 + (k % 4)] = (int8_t) (v > 127 ? 127 : v < -127 ? -127 : v);
        }
    }
    free(y);
    r->n    = n;
    r->rows = rows;
    return 1;
}

void ore_quantize_rows(const float * x, size_t xstride, int tb0, int tb1, ore_qact * out) {
    const int n = out->n, nb = out->nb, block = n / nb;
    for (int tb = tb0; tb < tb1; ++tb) {
        for (int f = 0; f < ORE_FB; ++f) {
            const int     t   = tb * ORE_FB + f;
            const float * row = x + (size_t) t * xstride;
            int8_t *      dst = out->q + (size_t) tb * n * ORE_FB + (size_t) f * 4;
            for (int b = 0; b < nb; ++b) {
                float big = 0.0f;
                if (t < out->rows) {
                    for (int k = b * block; k < (b + 1) * block; ++k) big = fmaxf(big, fabsf(row[k]));
                }
                const float scale = big / 127.0f, inv = scale > 0.0f ? 1.0f / scale : 0.0f;
                for (int k = b * block; k < (b + 1) * block; ++k) {
                    const long v                         = t < out->rows ? lrintf(row[k] * inv) : 0;
                    dst[(size_t) (k / 4) * 64 + (k % 4)] = (int8_t) (v > 127 ? 127 : v < -127 ? -127 : v);
                }
                out->d[((size_t) tb * nb + b) * ORE_FB + f] = scale;
            }
        }
    }
}

void ore_r8_free(ore_r8 * r) {
    ore_free(r->q);
    ore_free(r->scale);
    memset(r, 0, sizeof(*r));
}
