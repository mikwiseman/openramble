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


## Selected file policy and rejected echo candidates

The fixed 15-second/gap-preserving file policy passed the sealed 50-RU/50-EN
quality holdout: WER 6.1269→5.8097%, 8.1250→7.9875%, and mixed
43.8749→33.1596%. All 18 computational repetitions agree exactly within
cells. These are repeated composites of 100 distinct phrases, not 18 new
speech samples. Full native FileTranscriber parity is the next gate.

The pure reproduction fails on the old source and passes after the change;
36 native-word exports also match the frozen selected replay exactly.
An ordinary debug package run with the installed model still fails the
pre-existing trailing-English assertion. This has not been hidden by
weakening it. Model-independent validation uses an explicit empty model root
and is reported separately from the three prior release E2E failures.

The suffix-read study completed 40 runs with exact final text, samples and
decode-size parity, zero memory warnings and two preserved compiler aborts.
Normal long-input median gains are RU 35.665% and EN 6.085%. The registered
10% gate for both languages fails. The app is not wired to the optional
research callback.

Preserve-all and global speechPeak=0.005 both fail prospective capture-echo
falsifiers. The live threshold is unchanged; the registered speech/noise
map still runs to document the tradeoff. The second speech holdout stays sealed.

The selected-policy model-independent validation passes: 649 DictationCore,
199 LocalASR (32 explicit skips), 9 Swift FFI and 188 Rust tests. Rust format,
clippy, conformance, design-token, network and diagnostic checks also pass.
The driver initially could not find cargo after the two passing Swift suites;
the remaining checks then ran with the installed rustup and cmake on PATH.
This tooling recovery does not erase the separate installed-model failure.
