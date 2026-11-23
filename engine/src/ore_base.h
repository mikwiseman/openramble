// ore_base.h - shared definitions for the OpenRamble engine.
//
// Plain C11, no dependencies beyond libc (and Accelerate nowhere: the engine
// carries its own kernels so that every platform computes the same numbers).
#ifndef ORE_BASE_H
#define ORE_BASE_H

#include <math.h>
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

// ---- exp ----------------------------------------------------------------------

// Single-precision exp, the same operations in the same order as the vector
// versions in the kernel files (after ggml's ggml_v_expf, which follows Arm's
// optimized routines; both MIT), so a value gives the same bits whichever one
// computes it.
ORE_INLINE float ore_expf(float x) {
    const float r = 0x1.8p23f;
    const float z = fmaf(x, 0x1.715476p+0f, r);
    const float n = z - r;
    const float b = fmaf(-n, 0x1.7f7d1cp-20f, fmaf(-n, 0x1.62e4p-1f, x));
    uint32_t    zb, one;
    const float f1 = 1.0f;
    memcpy(&zb, &z, 4);
    memcpy(&one, &f1, 4);
    const uint32_t e  = zb << 23;
    const uint32_t kb = e + one;
    float          k;
    memcpy(&k, &kb, 4);
    const float u = b * b;
    const float j = fmaf(fmaf(fmaf(0x1.0e4020p-7f, b, 0x1.573e2ep-5f), u, fmaf(0x1.555e66p-3f, b, 0x1.fffdb6p-2f)), u,
                         0x1.ffffecp-1f * b);
    const float an = fabsf(n);
    if (!(an > 126.0f)) return fmaf(j, k, k);
    const uint32_t d   = (n <= 0.0f) ? 0x82000000u : 0u;
    const uint32_t s1b = d + 0x7f000000u, s2b = e - d;
    float          s1, s2;
    memcpy(&s1, &s1b, 4);
    memcpy(&s2, &s2b, 4);
    if (an > 192.0f) return s1 * s1;
    return fmaf(s2, j, s2) * s1;
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
// frame: the eight group scales, then the eight group mins (each 0..63), and
// the two block scales as floats.
typedef struct {
    uint8_t sm[16];
    float   d;
    float   dmin;
} ore_q4k_hdr;

// Widest Q4_K row the kernels accept: 64 blocks, 16,384 columns.
#define ORE_Q4K_MAX_BLOCKS 64
#define ORE_Q4K_MAX_COLS (ORE_Q4K_MAX_BLOCKS * ORE_Q4K_BLOCK)

// The twelve packed bytes hold sixteen 6-bit values; three masked shifts on
// 32-bit words unpack them four at a time (ggml's method). Little-endian, as
// every processor this engine runs on is.
ORE_INLINE void ore_q4k_decode_row(const uint8_t * row, int nb, ore_q4k_hdr * h) {
    for (int b = 0; b < nb; ++b) {
        const uint8_t * blk = row + (size_t) b * ORE_Q4K_BYTES;
        uint32_t        u[4];
        memcpy(u, blk + 4, 12);
        u[3]               = ((u[2] >> 4) & 0x0f0f0f0fu) | (((u[1] >> 6) & 0x03030303u) << 4);
        const uint32_t low = u[1] & 0x3f3f3f3fu;
        u[1]               = (u[2] & 0x0f0f0f0fu) | (((u[0] >> 6) & 0x03030303u) << 4);
        u[2]               = low;
        u[0] &= 0x3f3f3f3fu;
        memcpy(h[b].sm, u, 16);
        h[b].d    = ore_f16_to_f32(ore_rd16(blk));
        h[b].dmin = ore_f16_to_f32(ore_rd16(blk + 2));
    }
}

#endif  // ORE_BASE_H
