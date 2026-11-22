// ore_cpu.c - choose the kernel table from what the processor reports at run
// time, so one binary is right on every machine: it never runs an instruction
// the processor lacks, and never leaves one unused that it has.
#include "ore_kernels.h"

#if ORE_X86
#if defined(_MSC_VER)
#include <immintrin.h>
#include <intrin.h>
static int x86_has_avx2_fma_f16c(void) {
    int r[4];
    __cpuid(r, 0);
    if (r[0] < 7) return 0;
    __cpuid(r, 1);
    const int osxsave = (r[2] >> 27) & 1, avx = (r[2] >> 28) & 1, fma = (r[2] >> 12) & 1, f16c = (r[2] >> 29) & 1;
    if (!osxsave || !avx || !fma || !f16c) return 0;
    if ((_xgetbv(0) & 6) != 6) return 0;  // the system saves YMM state
    __cpuidex(r, 7, 0);
    return (r[1] >> 5) & 1;
}
static int x86_has_sse41(void) {
    int r[4];
    __cpuid(r, 1);
    return ((r[2] >> 9) & 1) && ((r[2] >> 19) & 1);  // SSSE3 and SSE4.1
}
static int x86_has_avx512_vnni(void) {
    int r[4];
    if (!x86_has_avx2_fma_f16c()) return 0;
    if ((_xgetbv(0) & 0xe6) != 0xe6) return 0;  // the system saves the mask and ZMM state
    __cpuidex(r, 7, 0);
    const int f = (r[1] >> 16) & 1, bw = (r[1] >> 30) & 1, vl = (r[1] >> 31) & 1, vnni = (r[2] >> 11) & 1;
    return f && bw && vl && vnni;
}
static void x86_cpuid(unsigned leaf, unsigned out[4]) {
    int r[4];
    __cpuid(r, (int) leaf);
    for (int i = 0; i < 4; ++i) out[i] = (unsigned) r[i];
}
#else
#include <cpuid.h>
static void x86_cpuid(unsigned leaf, unsigned out[4]) {
    out[0] = out[1] = out[2] = out[3] = 0;
    __get_cpuid(leaf, &out[0], &out[1], &out[2], &out[3]);
}
static int x86_has_avx2_fma_f16c(void) {
    __builtin_cpu_init();
    return __builtin_cpu_supports("avx2") && __builtin_cpu_supports("fma") && __builtin_cpu_supports("f16c");
}
static int x86_has_sse41(void) {
    __builtin_cpu_init();
    return __builtin_cpu_supports("ssse3") && __builtin_cpu_supports("sse4.1");
}
static int x86_has_avx512_vnni(void) {
    __builtin_cpu_init();
    return x86_has_avx2_fma_f16c() && __builtin_cpu_supports("avx512f") && __builtin_cpu_supports("avx512bw") &&
           __builtin_cpu_supports("avx512vl") && __builtin_cpu_supports("avx512vnni");
}
#endif

// AMD's Zen 4 (family 19h; its predecessor in that family has no AVX-512) runs
// a 512-bit instruction as two 256-bit halves.
static int x86_512_in_halves(void) {
    unsigned r[4];
    x86_cpuid(0, r);
    if (r[1] != 0x68747541u || r[3] != 0x69746e65u || r[2] != 0x444d4163u) return 0;  // "AuthenticAMD"
    x86_cpuid(1, r);
    const unsigned base = (r[0] >> 8) & 0xf;
    return base == 0xf && base + ((r[0] >> 20) & 0xff) == 0x19;
}
#endif

#if ORE_ARM64
#if defined(__APPLE__)
static int arm_has_dotprod(void) { return 1; }  // every Apple silicon Mac
#elif defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static int arm_has_dotprod(void) {
#ifndef PF_ARM_V82_DP_INSTRUCTIONS_AVAILABLE
#define PF_ARM_V82_DP_INSTRUCTIONS_AVAILABLE 43
#endif
    return IsProcessorFeaturePresent(PF_ARM_V82_DP_INSTRUCTIONS_AVAILABLE) != 0;
}
#elif defined(__linux__)
#include <sys/auxv.h>
static int arm_has_dotprod(void) { return (getauxval(AT_HWCAP) & (1ul << 20)) != 0; }  // HWCAP_ASIMDDP
#else
static int arm_has_dotprod(void) { return 0; }
#endif
#endif

const ore_kernels * ore_kernels_named(const char * name) {
    if (strcmp(name, "generic") == 0) return &ore_kernels_generic;
#if ORE_ARM64
    if (strcmp(name, "neon") == 0) return arm_has_dotprod() ? &ore_kernels_neon : NULL;
#endif
#if ORE_X86
    if (strcmp(name, "avx512") == 0) return x86_has_avx512_vnni() ? &ore_kernels_avx512 : NULL;
    if (strcmp(name, "avx512+avx2") == 0) return x86_has_avx512_vnni() ? &ore_kernels_avx512_f256 : NULL;
    if (strcmp(name, "avx2") == 0) return x86_has_avx2_fma_f16c() ? &ore_kernels_avx2 : NULL;
    if (strcmp(name, "sse") == 0) return x86_has_sse41() ? &ore_kernels_sse : NULL;
#endif
    return NULL;
}

const ore_kernels * ore_kernels_pick(void) {
#if ORE_ARM64
    if (arm_has_dotprod()) return &ore_kernels_neon;
#endif
#if ORE_X86
    if (x86_has_avx512_vnni()) return x86_512_in_halves() ? &ore_kernels_avx512_f256 : &ore_kernels_avx512;
    if (x86_has_avx2_fma_f16c()) return &ore_kernels_avx2;
    if (x86_has_sse41()) return &ore_kernels_sse;
#endif
    return &ore_kernels_generic;
}
