# Shared-weight static 7.5 s quality gate

Decision: **INTEGRATE CANDIDATE ONLY WITH FALLBACK**.

The 7.5 s graph passed the frozen non-inferiority gates, but it is not transcript-identical to the shipping 15 s graph. Any short-path lexical candidate must be rerun through shipping before returning text.

## Corpus

- 122 scored real/reference utterances: 60 FLEURS EN, 60 FLEURS RU, one LibriSpeech and one VOiCES.
- 727.08 seconds total; every fixture is <=7.5 s; six additional developer-term boundary diagnostics.
- FLEURS revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd`, CC BY 4.0.
- 128/128 unique PCM hashes; zero integrity failures; four representative AudioFileReader exports matched frozen Float32 PCM bit-for-bit.

## Frozen-reference quality

| Group | n | Shipping WER | Short WER | ΔWER | ΔWER paired 95% CI | Shipping CER | Short CER | ΔCER | Regressed / tied / improved |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| all | 122 | 6.529% | 6.852% | +0.323% | [-0.251%, +0.911%] | 2.543% | 2.478% | -0.065% | 6 / 113 / 3 |
| en | 62 | 6.982% | 7.095% | +0.113% | [-0.698%, +1.018%] | 3.766% | 3.588% | -0.178% | 3 / 56 / 3 |
| ru | 60 | 5.918% | 6.525% | +0.607% | [+0.000%, +1.411%] | 1.284% | 1.336% | +0.052% | 3 / 57 / 0 |

Observed combined ΔWER was +0.323 percentage points and ΔCER was -0.065 points. Six utterances gained errors, three improved, and 113 tied; the worst case gained two word errors, below the catastrophic gate.

## Vocabulary fallback

| Shipping outcome | Short outcome | Count |
|---|---|---:|
| no_candidate | no_candidate | 111 |
| rescored_modified | rescored_modified | 16 |
| rescored_unmodified | rescored_unmodified | 1 |

- Shipping-candidate / short-none false negatives: **0**.
- Short candidates requiring a shipping rerun: **17/128 (13.28%)**.
- Effective fallback WER: 6.787% versus shipping 6.529% (Δ +0.259%); effective CER Δ -0.065%.
- All six developer-term diagnostics took the candidate path. Three differed before fallback; fallback returns shipping output for all six.

This gate supports the stated fallback on this corpus. It does not prove that a future vocabulary or distribution can never produce a false negative.

## Transcript, token timing and confidence

Raw transcripts differed on 22/128; normalized transcripts differed on 14/128 (11 scored, 3 diagnostic).

- Tokens: 4012/4046 shipping tokens aligned by exact piece text (99.16%); absolute start Δ p50/p95 0.000/0.000 s, absolute end Δ p50/p95 0.000/0.080 s, absolute confidence Δ p50/p95 0.0000/0.0261.
- Words: 1584/1616 shipping words aligned (98.02%); absolute start Δ p50/p95 0.000/0.000 s, absolute end Δ p50/p95 0.000/0.080 s, absolute confidence Δ p50/p95 0.0000/0.0681.
- Structural validation failures: 0 shipping, 0 short. The maximum aligned deltas are retained in JSON; repeated tokens make maxima alignment-sensitive.

## Latency diagnostic

This one-pass quality run observed p50 49.520 ms shipping versus 33.556 ms short (-32.24%). It was sequential rather than balanced and is not the timing claim; the separate balanced n=60 product A/B remains authoritative.

## Hard gates and limitations

- Combined observed ΔWER/ΔCER <= +0.5 pp; each language <= +1.0 pp.
- Paired-bootstrap upper 95% bound <= +1.0 pp combined and <= +1.5 pp per language.
- Zero shipping-candidate / short-none false negatives; valid monotonic token/word structures and confidences.
- No catastrophic single-utterance regression (>=3 extra word errors, >=25 pp WER and >=10 pp CER).
- One M4 host, one pinned validation sample, one pass per graph. This is an internal integration gate, not a public quality claim.
- Exact run binary SHA is recorded in JSON. A later CPU-only canonicalization probe relinked the temp binary, so the byte-identical run executable was not retained.

JSON report SHA-256 after finalization: `a8dcd5b1d2ef977bd1d959b216a471a5611d0f3ecc9def84d5012bb4c0a8358e`.
