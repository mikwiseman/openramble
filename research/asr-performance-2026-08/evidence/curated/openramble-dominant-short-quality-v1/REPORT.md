# Dominant-short EN/RU quality corpus audit

Status: **BLOCKED BEFORE INFERENCE**. No ASR/CoreML output was produced or inspected.

## Pinned FLEURS core

- Dataset: `google/fleurs`, revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd`, CC BY 4.0.
- Exact untouched train/test availability for complete 1.0–4.0 s utterances:
  - EN: 18 total, all in 3–4 s (13 train, 5 test).
  - RU: 12 total, all in 3–4 s (12 train, 0 test).
  - Both 1–2 s and 2–3 s bins contain zero rows.
- Across all FLEURS splits, one additional unused EN validation row exists, so the all-split untouched maximum is EN 19 / RU 12. It does not change the maximum language-balanced count.
- Frozen core: 12 EN + 12 RU selected by stable hash without transcript-content selection, all in 3–4 s.
- All 24 source WAVs and canonical headerless mono 16 kHz f32le files were hashed. There are 24 unique PCM hashes.
- Overlap against the union of the existing 128-row engineering and 300-row holdout manifests: zero source identities and zero PCM SHA-256 values.

Core artifact hashes:

- Selection plan: `7b780a379c696dcfadb0d3ae518877a30bd2ba9f34475175ffaa25b2d163b415`
- Manifest: `994154cd47313f2ee275716f2b6da1c43c689a211178cedaaa93086c7e3c1407`
- PCM index: `a07d213dd000e05e672c27a4d1916324f2e23de9d5eb5abea19960d9afa1ac14`
- Source index: `b1669daa482fabb2421efe698db60a3dcee4dde68d8b1dc36bc05190adfb3712`

## One-source supplement audit

Source family: Mozilla Common Voice Corpus 17.0, CC0-1.0. The anonymously accessible pinned artifact is the unofficial Hugging Face mirror `fsicoli/common_voice_17_0` at commit `8262c16bf297c87a9cd88c51997c4758ed7a8ba2`. The official `mozilla-foundation/common_voice_17_0` Hugging Face repository at commit `11dc88355e899d1bf2df74f01b904a8544a17b33` now contains only a migration notice to Mozilla Data Collective.

Metadata-only dev+test audit of genuine, complete utterances found:

| Language | 1–2 s | 2–3 s | 3–4 s |
|---|---:|---:|---:|
| EN | 109 | 1,399 | 3,967 |
| RU | 98 | 1,498 | 3,398 |

The frozen supplement selection contains 34/34/22 rows per language for the three bins. Combined with the FLEURS core's 12 rows per language in 3–4 s, the intended final corpus is exactly 34 rows per language/bin, or 102 EN + 102 RU (204 total).

- No audio was downloaded for the supplement.
- No MP3 was decoded or resampled.
- No supplement source/PCM hash is claimed yet.
- No trimming, forced alignment, transcript truncation, or generated reference is permitted.

Supplement artifact hashes:

- Audit: `8c2a47153a6a9e4eedfd37c45253352ed77b7d81e0889f0d2410dfd9ecef72d5`
- Frozen metadata selection: `de0e219fc3f21ec7cd7d400bc691cb58c5d400f85551ea306c7fecac238c8456`

## Frozen evaluation contract

The preregistration is intentionally blocked until all 180 selected Common Voice files are downloaded, a deterministic MP3-to-16 kHz f32le canonicalizer is frozen, and every raw/reference/PCM SHA is sealed into a complete 204-row manifest.

Hard gates are frozen now:

- Combined observed candidate-minus-shipping WER <= +0.20 pp; paired bootstrap p97.5 <= +0.75 pp.
- Each language observed delta <= +0.40 pp; bootstrap p97.5 <= +1.0 pp.
- Each duration bin observed delta <= +0.50 pp; bootstrap p97.5 <= +1.5 pp.
- No utterance may have two or more extra word errors.
- Zero structural/emission failures and zero custom-vocabulary candidate false negatives.
- Token alignment >= 0.98, word alignment >= 0.97, aligned timing p95 <= 120 ms, and confidence p95 delta <= 0.10.
- CER and paired CER intervals are mandatory report fields.
- One-shot evaluator creates a consumed receipt before scoring and cannot be rerun at the same output path.

Frozen contract hashes:

- Blocked preregistration: `fc11882edf45b3727d124f5689a6fb179e8e7123b8437498226c00c41a5dd719`
- Evaluator: `e0ec47123c4e31b83da0e1ebf067f9e1f1ae10488362e967739b731491b8397d`
- Final-manifest sealer: `72c339777d6b81d3b60e4a9760b06001878305eee4eb43306d28bb095ab7656a`
- Verification receipt: `f5853c068e5340513b8ad2806e64e8c8c432e0e11b1fd4bd0cfd95ab7f52fdc8`

The evaluator and sealer both fail closed in the current state. Shared repository commit `f2b6e8cc66d20f7a07094f79af0faf3ba861af64` remained clean; all artifacts are under `$TMP/openramble-dominant-short-quality-v1`.
