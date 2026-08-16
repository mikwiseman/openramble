# Preregistered intermediate-shape quality gate

Status: **SEALED BEFORE CANDIDATE SELECTION OR INFERENCE**.

No 10.0s/12.5s outputs were inspected, no Core ML run occurred, and the shared repository was not edited during preparation.

## Frozen holdout

- Source: `google/fleurs` validation, revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd`, CC BY 4.0.
- 12.5s cohort: **300** real/reference utterances — **150 EN + 150 RU**.
- Nested 10.0s cohort: **200** — **100 EN + 100 RU**.
- Total audio: 2740.92s; 300/300 unique PCM SHA-256 values.
- Engineering overlap: 0 source identities and 0 PCM hashes against the frozen <=7.5s manifest.
- Manifest SHA-256: `bf7e768a882b7a826ab657c32ceb71e5e5a6589833fe1aaf8ab82684c140b9c7`.
- Ordered PCM-index SHA-256: `a2dff16accccf0aa9133f56f75da53319b466eba97167e47b0a731fb5cd01c90`.
- Selection-plan SHA-256: `f09cdaa95babbd505eb58e9dc03cb8f6cab31ae18934bcdc057500e68fa21f0b`.

Availability did not require changing source or relaxing counts: unused eligible pools were EN 179/RU 101 at <=10.0s and EN 93/RU 86 at >10.0–12.5s.

Canonicalization is identical to the engineering corpus: 16kHz mono, no resampling; PCM16 maps by sample/32768, and already-Float32 WAV payloads are copied bit-exact after finite validation. All 300 selected assets are Float32 WAV.

## Frozen hard gates (each shape independently)

- Observed micro ΔWER: combined <= **+0.20pp**; EN and RU each <= **+0.40pp**.
- Paired-bootstrap p97.5 ΔWER: combined <= **+0.75pp**; EN and RU each <= **+1.00pp**.
- No utterance with **>=2** extra word errors versus shipping.
- Zero shipping-candidate / intermediate-none vocabulary false negatives.
- Zero invalid token/word or emission structures; exact-text alignment >=98% tokens and >=97% words; aligned p95 timing <=120ms and confidence delta <=0.10.
- CER is reported, not gated.

The raw intermediate result is primary. Candidate-triggered shipping fallback cannot rescue a failed raw quality gate.

## One-shot analysis

The existing 122-reference corpus is engineering evidence only. The holdout evaluator must not run on partial JSONLs. It recomputes normalized WER/CER, uses 20,000 frozen paired bootstrap replicates (language-stratified for combined), and rejects if any hard gate fails. No post-result threshold or rule fitting is permitted.

Evaluator SHA-256: `d140daa510e4e4baa57dafe1b90a414859a81c309bc24f7926e341208ffff935`.
Preregistration JSON SHA-256: `d4752d8ea47d611101de49adcafa6778a7cc6afdcf3f228c2374246386691b20`.
