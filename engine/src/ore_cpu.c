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
#else
static int x86_has_avx2_fma_f16c(void) {
    __builtin_cpu_init();
    return __builtin_cpu_supports("avx2") && __builtin_cpu_supports("fma") && __builtin_cpu_supports("f16c");
}
static int x86_has_sse41(void) {
    __builtin_cpu_init();
    return __builtin_cpu_supports("ssse3") && __builtin_cpu_supports("sse4.1");
}
#endif
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
    if (x86_has_avx2_fma_f16c()) return &ore_kernels_avx2;
    if (x86_has_sse41()) return &ore_kernels_sse;
#endif
    return &ore_kernels_generic;
}
