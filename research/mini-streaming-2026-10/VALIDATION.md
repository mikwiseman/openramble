# Candidate validation, 11 October 2026

The suffix callback regression failed against the old complete-read behavior
before implementation. Both boundary regressions failed against parameters
accepted but ignored. Reproduction patches and assertion records are in
[regression-red](regression-red/README.md). The complete streaming test class
then passed10tests with the suffix implementation.

The model-independent check lane passed:

* DictationCore:649tests, zero failures
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
The release control has now completed with all three failures. The new release
binary reproduced the same three assertion categories, including the same
mixed-fixture counts (38 one-shot errors, 30 chunked errors, 109 reference
words). The baseline half-minute path was 1.046s against its 1s threshold.
These failures precede the candidate changes. They remain failures; this is
not a model-level pass. One original control attempt was interrupted by
memory pressure, and a later run completed after resource cleanup. See
[release control evidence](regression-red/release-e2e-comparison.json).
The resource gate requires normal pressure and no active compiler.

Candidate default wiring remains unchanged. Inference results and final
adoption gates will be added after the registered experiments complete.

The meeting offset regression also failed against the original code: its cut
ended at frame261600, before speech ended at frame272000. The correction
restores the retained one-second quiet prefix to the relative segmenter
counter after leading-silence trimming. It does not change the0.02 speech
threshold or enable quiet-audio decoding for live capture. Coverage results
will remain separate from timing adoption claims.
