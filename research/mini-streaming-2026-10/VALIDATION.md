# Candidate validation, 11 October 2026

The suffix callback regression failed against the old complete-read behavior
before implementation. Both boundary regressions failed against parameters
accepted but ignored. Reproduction patches and assertion records are in
[regression-red](regression-red/README.md). The complete streaming test class
then passed10tests with the suffix implementation.

The model-independent check lane passed:

* DictationCore:648tests, zero failures
* LocalASR:192tests,31model-dependent skips, zero failures
* Rust shared core:188tests, zero failures
* Swift FFI, cross-language conformance, network and diagnostic surface gates

This lane explicitly used an empty WAI_MODELS_ROOT. Its skips are not model
validation. A preceding ordinary check with the installed model discovered
three actual failures: the final English “send it” assertion, a repeated
name in the long mixed-language fixture, and a1.396s path against a1s latency
threshold on the loaded host. Expected dictionary failures are separate.
No assertion or threshold was weakened. These fixtures use system speech
synthesis and are separate from the public FLEURS benchmark.

The original373f2c2 release test binary and its native dependencies have been
preserved to check whether those failures precede the new changes. Its binary
SHA-256 is5655b028e257e04ec090aecb6d89b22179865fbe039ad73766d1bbfb25c43d73.
That control has not yet run; no baseline attribution or model-level pass is
claimed. The resource gate requires normal pressure and no active compiler.

Candidate default wiring remains unchanged. Inference results and final
adoption gates will be added after the registered experiments complete.
