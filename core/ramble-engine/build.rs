//! Compiles the recognition engine in `engine/` into this crate.
//!
//! The engine is plain C with no dependencies, so there is nothing to
//! configure and nothing of the build machine to keep out: every file is
//! compiled for the baseline processor, and the kernels for newer instruction
//! sets say so function by function and are chosen when a model is opened.
//! The flags are the ones `engine/CMakeLists.txt` uses.

use std::path::Path;

const SOURCES: [&str; 12] = [
    "ore.c",
    "ore_cpu.c",
    "ore_decoder.c",
    "ore_encoder.c",
    "ore_gguf.c",
    "ore_kernels_generic.c",
    "ore_kernels_neon.c",
    "ore_kernels_sme.c",
    "ore_kernels_sse.c",
    "ore_longform.c",
    "ore_mel.c",
    "ore_model.c",
    "ore_r8.c",
    "ore_threads.c",
];
/// The one file MSVC must be told the instruction set of: every other
/// compiler takes it from a function attribute.
const AVX2_SOURCE: &str = "ore_kernels_avx2.c";

fn main() {
    let engine = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../engine");
    println!("cargo:rerun-if-changed={}", engine.join("src").display());
    println!(
        "cargo:rerun-if-changed={}",
        engine.join("include").display()
    );

    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();

    let common = || {
        let mut build = cc::Build::new();
        build
            .include(engine.join("include"))
            // Always optimized: a debug build of the app must not wait ten
            // times as long for its words, and the tests time recognition.
            .opt_level(3)
            .warnings(false);
        if build.get_compiler().is_like_msvc() {
            build.flag("/fp:precise");
        } else {
            // No contraction: the code names its fused multiply-adds itself,
            // which is what keeps every kernel set giving the same numbers.
            build.std("c11").flag("-ffp-contract=off");
            // The baseline is named. Left to the compiler it is whatever the
            // distribution chose, and Ubuntu 26.04's compiler assumes AVX.
            // A Mac keeps Apple's own baseline, which every Intel Mac meets.
            if target_arch == "x86_64" && target_os != "macos" {
                build.flag("-march=x86-64");
            }
            if target_os != "macos" && target_os != "windows" {
                build
                    .define("_POSIX_C_SOURCE", "200809L")
                    .define("_DEFAULT_SOURCE", None);
            }
        }
        build
    };

    let mut build = common();
    for source in SOURCES {
        build.file(engine.join("src").join(source));
    }
    let msvc = build.get_compiler().is_like_msvc();
    if msvc && target_arch == "x86_64" {
        let mut avx2 = common();
        avx2.flag("/arch:AVX2")
            .file(engine.join("src").join(AVX2_SOURCE))
            .compile("ore_avx2");
    } else {
        build.file(engine.join("src").join(AVX2_SOURCE));
    }
    build.compile("ore");
}
