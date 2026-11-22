// ore_base.h - shared definitions for the OpenRamble engine.
//
// Plain C11, no dependencies beyond libc (and Accelerate nowhere: the engine
// carries its own kernels so that every platform computes the same numbers).
#ifndef ORE_BASE_H
#define ORE_BASE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

// Fused multiply-add is used only where the code asks for it by name. A
// compiler that contracts `a * b + c` on its own would make the result depend
// on the compiler, so contraction is switched off in every engine file.
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#elif defined(__GNUC__)
#pragma GCC optimize("fp-contract=off")
#elif defined(_MSC_VER)
#pragma fp_contract(off)
#endif

#if defined(_MSC_VER)
#define ORE_INLINE static __forceinline
#define ORE_NOINLINE __declspec(noinline)
#define ORE_RESTRICT __restrict
#else
#define ORE_INLINE static inline __attribute__((always_inline))
#define ORE_NOINLINE __attribute__((noinline))
#define ORE_RESTRICT __restrict__
#endif

#if defined(__x86_64__) || defined(_M_X64)
#define ORE_X86 1
#else
#define ORE_X86 0
#endif
#if defined(__aarch64__) || defined(_M_ARM64)
#define ORE_ARM64 1
#else
#define ORE_ARM64 0
#endif

#define ORE_MIN(a, b) ((a) < (b) ? (a) : (b))
#define ORE_MAX(a, b) ((a) > (b) ? (a) : (b))

// ---- memory ---------------------------------------------------------------

// 64-byte aligned allocation, zero-filled. NULL on failure.
void * ore_alloc(size_t bytes);
void   ore_free(void * p);

// ---- half precision ---------------------------------------------------------

// IEEE half to single, exact.
ORE_INLINE float ore_f16_to_f32(uint16_t h) {
    uint32_t sign = (uint32_t) (h & 0x8000u) << 16;
    uint32_t exp  = (h >> 10) & 0x1fu;
    uint32_t man  = h & 0x3ffu;
    uint32_t bits;
    if (exp == 0) {
        if (man == 0) {
            bits = sign;
        } else {
            // subnormal: normalize
            int shift = 0;
            while ((man & 0x400u) == 0) {
                man <<= 1;
                ++shift;
            }
            man &= 0x3ffu;
            bits = sign | ((uint32_t) (113 - shift) << 23) | (man << 13);
        }
    } else if (exp == 31) {
        bits = sign | 0x7f800000u | (man << 13);
    } else {
        bits = sign | ((exp + 112) << 23) | (man << 13);
    }
    float f;
    memcpy(&f, &bits, 4);
    return f;
}

// Single to IEEE half, round to nearest even.
ORE_INLINE uint16_t ore_f32_to_f16(float f) {
    uint32_t x;
    memcpy(&x, &f, 4);
    uint32_t sign = (x >> 16) & 0x8000u;
    uint32_t man  = x & 0x007fffffu;
    int      exp  = (int) ((x >> 23) & 0xff);
    if (exp == 255) {
        return (uint16_t) (sign | 0x7c00u | (man ? 0x200u : 0));
    }
    exp -= 127;
    if (exp > 15) {
        return (uint16_t) (sign | 0x7c00u);
    }
    if (exp >= -14) {
        uint32_t half = (uint32_t) ((exp + 15) << 10) | (man >> 13);
        uint32_t rest = man & 0x1fffu;
        if (rest > 0x1000u || (rest == 0x1000u && (half & 1u))) {
            ++half;
        }
        return (uint16_t) (sign | half);
    }
    if (exp < -25) {
        return (uint16_t) sign;
    }
    man |= 0x00800000u;
    int      shift = -exp - 14 + 13;  // 14..24
    uint32_t half  = man >> shift;
    uint32_t rest  = man & ((1u << shift) - 1u);
    uint32_t mid   = 1u << (shift - 1);
    if (rest > mid || (rest == mid && (half & 1u))) {
        ++half;
    }
    return (uint16_t) (sign | half);
}

ORE_INLINE uint16_t ore_rd16(const uint8_t * p) {
    uint16_t v;
    memcpy(&v, p, 2);
    return v;
}

// ---- GGUF tensor element types we read --------------------------------------

enum {
    ORE_T_F32  = 0,
    ORE_T_F16  = 1,
    ORE_T_Q8_0 = 8,
    ORE_T_Q4_K = 12,
};

// Q4_K: 256 weights in 144 bytes: f16 d, f16 dmin, 12 bytes of 6-bit scales
// and mins for 8 groups of 32, then 128 bytes of 4-bit values.
#define ORE_Q4K_BLOCK 256
#define ORE_Q4K_BYTES 144
// Q8_0: 32 weights in 34 bytes: f16 d, then 32 int8.
#define ORE_Q80_BLOCK 32
#define ORE_Q80_BYTES 34

// Unpack one Q4_K block's group scales and mins (0..63 each).
ORE_INLINE void ore_q4k_scales(const uint8_t * blk, uint8_t sc[8], uint8_t mn[8]) {
    const uint8_t * s = blk + 4;
    for (int j = 0; j < 4; ++j) {
        sc[j]     = s[j] & 63;
        mn[j]     = s[j + 4] & 63;
        sc[j + 4] = (uint8_t) ((s[j + 8] & 0x0f) | ((s[j] >> 6) << 4));
        mn[j + 4] = (uint8_t) ((s[j + 8] >> 4) | ((s[j + 4] >> 6) << 4));
    }
}

// A Q4_K block's header, decoded once per weight row and reused for every
// frame. The scale and min are stored in the shape a 16-bit multiply-add wants:
// sc2 holds the scale in both halves of a 32-bit lane, mn in the low half only.
typedef struct {
    int32_t sc[8];
    int32_t sc2[8];
    int32_t mn[8];
    float   d;
    float   dmin;
} ore_q4k_hdr;

// Widest Q4_K row the kernels accept: 64 blocks, 16,384 columns.
#define ORE_Q4K_MAX_BLOCKS 64
#define ORE_Q4K_MAX_COLS (ORE_Q4K_MAX_BLOCKS * ORE_Q4K_BLOCK)

ORE_INLINE void ore_q4k_decode_row(const uint8_t * row, int nb, ore_q4k_hdr * h) {
    for (int b = 0; b < nb; ++b) {
        const uint8_t * blk = row + (size_t) b * ORE_Q4K_BYTES;
        uint8_t         sc[8], mn[8];
        ore_q4k_scales(blk, sc, mn);
        for (int g = 0; g < 8; ++g) {
            h[b].sc[g]  = sc[g];
            h[b].sc2[g] = (int32_t) sc[g] * 0x10001;
            h[b].mn[g]  = mn[g];
        }
        h[b].d    = ore_f16_to_f32(ore_rd16(blk));
        h[b].dmin = ore_f16_to_f32(ore_rd16(blk + 2));
    }
}

// One Q4_K row's four-bit values as bytes 0..15, in column order.
ORE_INLINE void ore_q4k_unpack_row(const uint8_t * row, int nb, uint8_t * out) {
    for (int b = 0; b < nb; ++b) {
        const uint8_t * qs = row + (size_t) b * ORE_Q4K_BYTES + 16;
        uint8_t *       o  = out + (size_t) b * 256;
        for (int g = 0; g < 4; ++g) {
            for (int i = 0; i < 32; ++i) {
                o[g * 64 + i]      = qs[g * 32 + i] & 0x0f;
                o[g * 64 + 32 + i] = qs[g * 32 + i] >> 4;
            }
        }
    }
}

#endif  // ORE_BASE_H
