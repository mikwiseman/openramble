# Preregistered 10.0 / 12.5 static-shape quality gate

Decision: **REJECT both standalone shapes**. Each independently failed only the frozen per-utterance gate (no utterance may add two or more word errors). Aggregate WER, bootstrap, structure, timing/confidence, and vocabulary false-negative gates passed.

| Shape | n EN/RU | Shipping WER | Candidate WER | observed ΔWER | bootstrap 95% ΔWER (all) | failed gates |
|---|---:|---:|---:|---:|---:|---|
| 10.0 s | 100/100 | 4.731% | 4.671% | -0.060 pp | [-0.374 pp, +0.257 pp] | `no_utterance_with_two_or_more_extra_word_errors` |
| 12.5 s | 150/150 | 5.392% | 5.228% | -0.164 pp | [-0.367 pp, +0.036 pp] | `no_utterance_with_two_or_more_extra_word_errors` |

## Language results

### 10.0 s

- EN: ΔWER +0.157 pp; bootstrap 95% [-0.254 pp, +0.594 pp].
- RU: ΔWER -0.345 pp; bootstrap 95% [-0.842 pp, +0.135 pp].
- Worst: +2 word errors; fleurs-holdout-en_us-0285-1631, fleurs-holdout-en_us-0346-1519.

### 12.5 s

- EN: ΔWER -0.226 pp; bootstrap 95% [-0.495 pp, +0.032 pp].
- RU: ΔWER -0.084 pp; bootstrap 95% [-0.395 pp, +0.210 pp].
- Worst: +2 word errors; fleurs-holdout-en_us-0346-1519.

## Integrity and repeatability

- Both evaluations: zero integrity failures and zero shipping-candidate / short-none vocabulary false negatives.
- Every full primary/duplicate pair was semantically compared after shutdown; exact counts are in `posthoc-analysis.json`.
- The 122-reference engineering result remains separate and was never pooled with this holdout.

Frozen 10.0 report SHA: `aef6f6add28c4b37345fe5d6e6c40c78e131974bb9eed592abd6bac6aaea9856`.
Frozen 12.5 report SHA: `e1d3d6bd7c67e7fd04c915d1ab25a3625327f4689f98e066ff4ef37bf028e815`.
Artifact lineage SHA: `4b976c8be281ed945f0a84064f4c0965d65139c35723f847b72b4c81b89cbc29`.
Raw artifact index SHA: `fee13b2e28d59232ea1c6a5f2e458fafc1c497d45f1833063ad5dae9bda64246`.
