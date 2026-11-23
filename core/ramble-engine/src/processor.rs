//! Whether this computer's processor can run the recognizer at all.
//!
//! On x86-64 the runtime's arithmetic is compiled for one set of processor
//! instructions, chosen when it was built: the Windows and Linux packages use
//! AVX2 with FMA, F16C and BMI2. A processor without them gets no error from
//! the runtime. It reaches an instruction it does not have, the system stops
//! the process, and the person watches the app vanish with nothing said. So
//! the question is asked here, before the runtime is given anything to do,
//! and the answer is an error a person can read.
//!
//! What the runtime uses is asked of the runtime, not written down here. A
//! package and a build tuned to its own machine are compiled for different
//! sets, and a list kept by hand would turn away a processor that the build
//! in front of it runs on.
//!
//! Asked on Windows and Linux only. An Intel build on a Mac may be running
//! under Rosetta, which runs AVX and tells the program it has none.

use std::fmt;

/// Instruction sets the runtime may be compiled to use on x86-64 and a
/// processor still in use may lack.
///
/// Read twice: once for what the runtime uses, once for what the processor
/// has. The packages are compiled for the first five. SSE4.2, which they
/// also use, is not listed: no processor has AVX without it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Instructions {
    pub avx: bool,
    pub avx2: bool,
    pub fma: bool,
    pub f16c: bool,
    pub bmi2: bool,
    pub avx512: bool,
}

impl Instructions {
    fn named(self) -> [(&'static str, bool); 6] {
        [
            ("AVX", self.avx),
            ("AVX2", self.avx2),
            ("FMA", self.fma),
            ("F16C", self.f16c),
            ("BMI2", self.bmi2),
            ("AVX-512", self.avx512),
        ]
    }
}

/// A processor that lacks instructions the runtime was compiled to use.
///
/// Nothing on the computer changes this, so it is not a failure to retry: no
/// download, setting or restart gives a processor instructions it was made
/// without.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnsupportedProcessor {
    missing: Vec<&'static str>,
}

impl UnsupportedProcessor {
    /// Can a processor that has `processor` run a runtime compiled to use
    /// `runtime`? `None` when it can.
    pub fn check(runtime: Instructions, processor: Instructions) -> Option<Self> {
        let missing: Vec<&'static str> = runtime
            .named()
            .into_iter()
            .zip(processor.named())
            .filter(|((_, used), (_, present))| *used && !*present)
            .map(|((name, _), _)| name)
            .collect();
        (!missing.is_empty()).then_some(UnsupportedProcessor { missing })
    }

    /// The same question, asked of this computer and this build.
    ///
    /// Always `None` on Arm and on a Mac, where nothing is asked at all.
    pub fn on_this_computer() -> Option<Self> {
        #[cfg(all(target_arch = "x86_64", not(target_os = "macos")))]
        {
            Self::check(x86_64::runtime(), x86_64::processor())
        }
        #[cfg(not(all(target_arch = "x86_64", not(target_os = "macos"))))]
        {
            None
        }
    }

    /// What the processor lacks, as it reads in a sentence: "AVX2, FMA and
    /// BMI2".
    pub fn missing(&self) -> String {
        match self.missing.split_last() {
            Some((last, rest)) if !rest.is_empty() => format!("{} and {last}", rest.join(", ")),
            _ => self.missing.concat(),
        }
    }
}

impl fmt::Display for UnsupportedProcessor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "this computer's processor cannot run the recognizer: it lacks {}",
            self.missing()
        )
    }
}

#[cfg(all(target_arch = "x86_64", not(target_os = "macos")))]
mod x86_64 {
    use super::Instructions;
    use std::arch::is_x86_feature_detected;
    use std::os::raw::c_int;

    // The runtime's own account of what its arithmetic was compiled to use
    // (`ggml-cpu.c`). Each returns a constant fixed when the library was
    // built: it reads no processor and computes nothing.
    extern "C" {
        fn ggml_cpu_has_avx() -> c_int;
        fn ggml_cpu_has_avx2() -> c_int;
        fn ggml_cpu_has_fma() -> c_int;
        fn ggml_cpu_has_f16c() -> c_int;
        fn ggml_cpu_has_bmi2() -> c_int;
        fn ggml_cpu_has_avx512() -> c_int;
    }

    /// What this build of the runtime was compiled to use.
    ///
    /// The one place this crate calls the runtime without its Rust wrapper,
    /// which has no word for this question.
    #[allow(unsafe_code)]
    pub(super) fn runtime() -> Instructions {
        // SAFETY: six C functions that take nothing and return a constant.
        // They are safe to call on the processor this module exists for: a
        // function that returns a constant has no arithmetic to compile into
        // the instructions that processor lacks.
        unsafe {
            Instructions {
                avx: ggml_cpu_has_avx() != 0,
                avx2: ggml_cpu_has_avx2() != 0,
                fma: ggml_cpu_has_fma() != 0,
                f16c: ggml_cpu_has_f16c() != 0,
                bmi2: ggml_cpu_has_bmi2() != 0,
                avx512: ggml_cpu_has_avx512() != 0,
            }
        }
    }

    /// What this computer's processor has, and its system lets programs use.
    pub(super) fn processor() -> Instructions {
        Instructions {
            avx: is_x86_feature_detected!("avx"),
            avx2: is_x86_feature_detected!("avx2"),
            fma: is_x86_feature_detected!("fma"),
            f16c: is_x86_feature_detected!("f16c"),
            bmi2: is_x86_feature_detected!("bmi2"),
            avx512: is_x86_feature_detected!("avx512f"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What the Windows and Linux packages are compiled to use.
    const PACKAGES: Instructions = Instructions {
        avx: true,
        avx2: true,
        fma: true,
        f16c: true,
        bmi2: true,
        avx512: false,
    };

    /// An Intel Core from 2013 on, or an AMD Ryzen.
    const HASWELL: Instructions = PACKAGES;

    /// An Intel Core of 2012: AVX and F16C, nothing newer.
    const IVY_BRIDGE: Instructions = Instructions {
        avx: true,
        f16c: true,
        ..NOTHING
    };

    /// A Celeron or Pentium of 2019, or any processor before 2011.
    const NOTHING: Instructions = Instructions {
        avx: false,
        avx2: false,
        fma: false,
        f16c: false,
        bmi2: false,
        avx512: false,
    };

    #[test]
    fn a_processor_with_everything_the_runtime_uses_can_run_it() {
        assert_eq!(UnsupportedProcessor::check(PACKAGES, HASWELL), None);
        // More than the runtime uses is not a problem either.
        let newer = Instructions {
            avx512: true,
            ..HASWELL
        };
        assert_eq!(UnsupportedProcessor::check(PACKAGES, newer), None);
    }

    #[test]
    fn a_processor_without_what_the_packages_use_cannot_run_them() {
        let celeron = UnsupportedProcessor::check(PACKAGES, NOTHING).expect("no AVX at all");
        assert_eq!(celeron.missing(), "AVX, AVX2, FMA, F16C and BMI2");

        // One missing set is enough: the runtime uses all of them.
        let older_core = UnsupportedProcessor::check(PACKAGES, IVY_BRIDGE).expect("no AVX2");
        assert_eq!(older_core.missing(), "AVX2, FMA and BMI2");

        let one = Instructions {
            bmi2: false,
            ..HASWELL
        };
        let only_one = UnsupportedProcessor::check(PACKAGES, one).expect("no BMI2");
        assert_eq!(only_one.missing(), "BMI2");
    }

    /// The Intel Mac build uses AVX and F16C only, and a build tuned to its
    /// own machine uses whatever that machine has. Asking either for AVX2
    /// would turn away a processor the build runs on.
    #[test]
    fn what_this_build_does_not_use_is_never_asked_for() {
        let intel_mac = Instructions {
            avx: true,
            f16c: true,
            ..NOTHING
        };
        assert_eq!(UnsupportedProcessor::check(intel_mac, IVY_BRIDGE), None);
        assert_eq!(UnsupportedProcessor::check(NOTHING, NOTHING), None);
    }

    /// A package built on a machine with AVX-512 and left tuned to it, which
    /// is what 0.37.0 for Linux was.
    #[test]
    fn a_build_tuned_to_a_newer_machine_is_caught_too() {
        let tuned = Instructions {
            avx512: true,
            ..PACKAGES
        };
        let ryzen = UnsupportedProcessor::check(tuned, HASWELL).expect("no AVX-512");
        assert_eq!(ryzen.missing(), "AVX-512");
    }

    #[test]
    fn the_error_says_what_is_wrong_before_it_names_instructions() {
        let error = UnsupportedProcessor::check(PACKAGES, IVY_BRIDGE)
            .expect("no AVX2")
            .to_string();
        assert_eq!(
            error,
            "this computer's processor cannot run the recognizer: it lacks AVX2, FMA and BMI2"
        );
    }

    /// Asked of the machine running the tests, whatever it is. A runtime that
    /// uses AVX2 without AVX, or AVX-512 without AVX2, was not built by any
    /// compiler, so this also proves the answers come from the runtime.
    #[test]
    fn this_computer_can_be_asked() {
        let _ = UnsupportedProcessor::on_this_computer();
        #[cfg(all(target_arch = "x86_64", not(target_os = "macos")))]
        {
            let runtime = x86_64::runtime();
            assert!(runtime.avx || !runtime.avx2, "{runtime:?}");
            assert!(runtime.avx2 || !runtime.avx512, "{runtime:?}");
        }
    }

    #[test]
    #[cfg(not(all(target_arch = "x86_64", not(target_os = "macos"))))]
    fn an_arm_processor_and_a_mac_are_never_turned_away() {
        assert_eq!(UnsupportedProcessor::on_this_computer(), None);
    }
}
