# Short-only risk-gate analysis

Decision: **keep policy A; reject an additional learned short-only risk gate from this corpus**.

This is a CPU-only follow-up over the frozen 122-reference/6-diagnostic run. No Core ML process was started and the shared repository was not edited.

## Six regressions and three improvements

| Outcome | Fixture | Lang | Duration / samples | Candidate | Δword | Δchar | Token conf mean / p10 / min | Word conf mean / p10 / min | End margin | Classification |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| regression | `fleurs-en_us-0066-1615` | en | 6.00s / 96000 | no | +2 | +6 | 0.979 / 0.999 / 0.619 | 0.954 / 0.823 / 0.619 | 0.24s | real deletion/merge: 'solar system moved' -> 'solar soved'; shipping exactly matches reference |
| regression | `fleurs-en_us-0124-1543` | en | 5.76s / 92160 | no | +2 | +1 | 0.901 / 0.641 / 0.284 | 0.852 / 0.483 / 0.284 | 0.24s | segmentation plus verb substitution: 'solar virus have' -> 'solavirus had' |
| regression | `fleurs-ru_ru-0355-1560` | ru | 5.76s / 92160 | no | +2 | +0 | 0.992 / 0.991 / 0.841 | 0.984 / 0.979 / 0.841 | 0.16s | whitespace segmentation only: 'не труднее' -> 'нетруднее'; CER unchanged |
| regression | `fleurs-en_us-0358-1554` | en | 4.20s / 67200 | yes | +1 | +0 | 0.932 / 0.770 / 0.540 | 0.923 / 0.770 / 0.540 | 0.44s | whitespace segmentation only: 'wifi' -> 'wi fi'; CER unchanged; vocabulary fallback catches it |
| regression | `fleurs-ru_ru-0070-1612` | ru | 5.34s / 85440 | no | +1 | +1 | 0.975 / 0.930 / 0.723 | 0.910 / 0.733 / 0.723 | 0.38s | single-vowel inflection substitution: 'отрезке' -> 'отрезки' |
| regression | `fleurs-ru_ru-0335-1562` | ru | 6.96s / 111360 | no | +1 | +2 | 0.981 / 0.996 / 0.630 | 0.947 / 0.743 / 0.630 | 0.48s | lexical substitution: 'износу' -> 'истосу' |
| improvement | `fleurs-en_us-0332-1564` | en | 7.32s / 117120 | no | -2 | -6 | 0.961 / 0.944 / 0.454 | 0.929 / 0.663 / 0.454 | 0.12s | articles restored: 'a bug in hospital' -> 'the bug in the hospital' |
| improvement | `fleurs-en_us-0245-1646` | en | 6.00s / 96000 | no | -1 | -4 | 0.971 / 0.957 / 0.385 | 0.960 / 0.973 / 0.385 | 0.16s | proper noun improved: 'offland' -> 'auckland' |
| improvement | `fleurs-en_us-0311-1557` | en | 7.50s / 120000 | no | -1 | -3 | 0.982 / 0.998 / 0.500 | 0.965 / 0.927 / 0.500 | 0.22s | reference form improved: 'world war one' -> 'world war i' |

Two of the six WER regressions are whitespace-only and have zero CER delta. One of those is the Wi-Fi vocabulary candidate and policy A already removes it. The other four include three real substitutions/deletions and one mixed segmentation/substitution. All three improvements are English.
Two additional normalized transcript differences (`fleurs-en_us-0362-1567`, `fleurs-ru_ru-0276-1543`) have zero word-error delta and improve CER by one character each; they are WER ties and are not counted in the 6/3 labels.

Group summaries below are descriptive, not thresholds (median of the per-utterance feature):

| WER outcome | N | Duration | Token conf mean | Word conf mean | Word conf p10 | End margin | Token/s | Word/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| regression | 6 | 5.76s | 0.977 | 0.935 | 0.757 | 0.31s | 5.13 | 1.98 |
| improvement | 3 | 7.32s | 0.971 | 0.960 | 0.927 | 0.16s | 6.00 | 2.83 |
| tie | 113 | 6.18s | 0.993 | 0.988 | 0.991 | 0.24s | 5.12 | 1.99 |

## Policy comparison

| Policy | Fallback all / scored | Short use | Regressions caught / missed | Missed +word errors | Improvements forfeited | Effective WER | ΔWER pp | Effective CER | ΔCER pp |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| short_everywhere_no_fallback | 0.0% / 0.0% | 100.0% | 0 / 6 | 9 | 0 (0 words) | 6.852% | +0.323 | 2.478% | -0.065 |
| A_vocab_candidate_fallback | 13.3% / 9.0% | 86.7% | 1 / 5 | 8 | 0 (0 words) | 6.787% | +0.259 | 2.478% | -0.065 |
| B_any_vocabulary_configured_shipping | 100.0% / 100.0% | 0.0% | 6 / 0 | 0 | 3 (4 words) | 6.529% | +0.000 | 2.543% | +0.000 |

Policy B is quality-identical to shipping because vocabulary was configured for every request; it also discards 100% of the short-path speed benefit.
Policy A has zero candidate-parity false negatives (shipping candidate while short has none), but it is not a general quality detector: it misses 5/6 WER-regression utterances and 8/9 added word errors. Its one caught regression is Wi-Fi whitespace segmentation with zero CER delta.

### Descriptive duration / sample buckets

These fixed descriptive buckets are not used for threshold selection.

| Bucket | N (EN/RU) | Candidates | Regression / improvement / tie | Net Δword | Short WER | ΔWER pp | Short CER | ΔCER pp |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| <=5.0s (<=80k samples) | 25 (20/5) | 7 | 1 / 0 / 24 | +1 | 12.030% | +0.376 | 4.094% | +0.000 |
| >5.0-6.0s (80-96k samples) | 33 (14/19) | 2 | 4 / 1 / 28 | +6 | 5.656% | +1.542 | 2.120% | +0.197 |
| >6.0-7.0s (96-112k samples) | 40 (18/22) | 1 | 1 / 0 / 39 | +1 | 6.567% | +0.188 | 2.648% | +0.000 |
| >7.0-7.5s (112-120k samples) | 24 (10/14) | 1 | 0 / 2 / 22 | -3 | 4.735% | -0.836 | 1.599% | -0.496 |

### Policy C: short only at or below X seconds, plus vocabulary fallback

| X | Fallback all / scored | Short use | Regressions caught / missed | Effective WER | ΔWER pp | Effective CER | ΔCER pp |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 3.00s | 100.0% / 100.0% | 0.0% | 6 / 0 | 6.529% | +0.000 | 2.543% | +0.000 |
| 4.00s | 94.5% / 94.3% | 5.5% | 6 / 0 | 6.529% | +0.000 | 2.543% | +0.000 |
| 5.00s | 85.9% / 85.2% | 14.1% | 6 / 0 | 6.529% | +0.000 | 2.543% | +0.000 |
| 6.00s | 61.7% / 59.8% | 38.3% | 2 / 4 | 6.917% | +0.388 | 2.595% | +0.052 |
| 6.50s | 47.7% / 45.1% | 52.3% | 2 / 4 | 6.917% | +0.388 | 2.595% | +0.052 |
| 7.00s | 31.2% / 27.9% | 68.8% | 1 / 5 | 6.981% | +0.452 | 2.595% | +0.052 |
| 7.25s | 23.4% / 19.7% | 76.6% | 1 / 5 | 6.981% | +0.452 | 2.595% | +0.052 |
| 7.40s | 17.2% / 13.1% | 82.8% | 1 / 5 | 6.852% | +0.323 | 2.517% | -0.026 |
| 7.50s | 13.3% / 9.0% | 86.7% | 1 / 5 | 6.787% | +0.259 | 2.478% | -0.065 |

A duration threshold is acceptable only as a fixed product policy, not as a learned quality detector. X=5.0s is the largest grid point with in-sample shipping parity, but it falls back on 85.9% and uses the short path on only 14.1%; selecting it from these outcomes would be overfit. Every X>=6.0s misses at least four regressions.

### Language-only policies

| Shipping language (+ vocab) | Fallback all / scored | Regressions caught / missed | Missed +word errors | Improvements forfeited | Effective WER | ΔWER pp | Effective CER | ΔCER pp |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| RU | 60.2% / 58.2% | 4 / 2 | 4 | 0 (0 words) | 6.529% | +0.000 | 2.453% | -0.090 |
| EN | 53.1% / 50.8% | 3 / 3 | 4 | 3 (4 words) | 6.787% | +0.259 | 2.569% | +0.026 |

Fallback-RU happens to match shipping aggregate WER, but it still misses two EN regressions (+4 word errors); the retained three EN improvements (-4 word errors) cancel them. This is not per-utterance safety.

### Policy D: confidence / end-margin / count / rate

- Full-data best under 25% scored fallback: `word_confidence_p10_lt_0.8`; fallback all/scored 23.4%/19.7%, caught/missed 4/2 (4 added word errors missed), forfeited improvements 1 (2 words), effective WER/CER 6.658%/2.504%, ΔWER/ΔCER +0.129/-0.039pp. Exploration-only because the same corpus selected it.
- Full-data best under 50% scored fallback: `word_confidence_p10_lt_0.85`; fallback all/scored 32.8%/29.5%, caught/missed 5/1 (2 added word errors missed), forfeited improvements 1 (2 words), effective WER/CER 6.529%/2.427%, ΔWER/ΔCER +0.000/-0.116pp. Exploration-only because the same corpus selected it.

Leave-one-language-out, with rule and threshold selected only on the other language:

- Budget 25%:
  - train ru -> test en: `tail_word_confidence_min_lt_0.9`; held fallback 50.0%, caught/missed 2/1.
  - train en -> test ru: `word_confidence_p10_lt_0.5`; held fallback 0.0%, caught/missed 0/3.
  - Combined held-out: fallback 25.4%, caught/missed 2/4 (6 added word errors missed), effective WER/CER 6.658%/2.478%, ΔWER/ΔCER +0.129/-0.065pp; same rule in both folds: no.
- Budget 50%:
  - train ru -> test en: `tail_word_confidence_min_lt_0.9`; held fallback 50.0%, caught/missed 2/1.
  - train en -> test ru: `word_confidence_p10_lt_0.85`; held fallback 15.0%, caught/missed 2/1.
  - Combined held-out: fallback 32.8%, caught/missed 4/2 (4 added word errors missed), effective WER/CER 6.529%/2.440%, ΔWER/ΔCER +0.000/-0.103pp; same rule in both folds: no.

No D rule is accepted: language folds choose different thresholds/rules and still miss held-out regressions. A full-data confidence gate would be classic multiple-threshold overfit on five non-candidate regressions.
The 50% full-data and 50% held-out rows reaching aggregate WER parity do not prove safety: each still misses regression utterances, with their added errors canceled by retained or forfeited improvements. The conservative criterion is zero held-out regression misses, not aggregate cancellation.

Language-only fallback is also not a general risk signal: regressions split 3 EN / 3 RU, while all three improvements are EN. Leaving out sources is unusable because all nine WER changes are FLEURS and Libri/VOiCES contribute only two unchanged samples.

Emission validation was persisted: `emission_validation_failures` is empty for all 128 outputs on both paths, so it cannot discriminate risk. `ctc_inference_invocations=1` on exactly the same 17 short-path vocabulary candidates and 0 elsewhere, adding no signal beyond A. Blank-decision and decoder-loop counters were not persisted and were not reconstructed.

## Recommendation

- Retain A if the accepted non-inferiority margins are the product decision: candidate -> shipping, otherwise short.
- Use B for a zero-quality-drift requirement when custom vocabulary is configured; it means no short-path acceleration in the current default configuration.
- Do not ship C or D as a learned quality gate from this dataset. A fixed X can be chosen only from an independent product latency/coverage requirement, then validated on a new corpus.
- The next defensible quality gate needs an independent held-out corpus and serialized decoder diagnostics before threshold design.
