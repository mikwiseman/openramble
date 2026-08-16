# Endpoint-cache product matrix

- vocabulary enabled: `False` (0 terms)
- deterministic repeats: `True`
- unique PCM / runs: 49 / 98
- process peak RSS: 2153.6 MiB
- inference median / max: 46.24 / 70.86 ms
- endpoint-eligible exact digest: 14 / 14
- eligible canonical-vs-raw acoustic parity: 0 / 14
- eligible result already complete at stop: 11 / 14

| fixture | change | eligible | digest | raw→base changed | canonical→raw changed | vocab | raw ms | cached wait ms |
|---|---:|:---:|:---:|---|---|---|---:|---:|
| libri | +0.00s | False | False | none | none | not_configured→not_configured | 46.51 | 46.51 |
| libri | +0.10s | False | False | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 57.19 | 57.19 |
| libri | +0.25s | False | False | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 48.81 | 48.81 |
| libri | +0.50s | True | True | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 46.94 | 48.81 |
| libri | +1.00s | True | True | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 49.34 | 0.00 |
| libri | −0.10s | False | None | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 47.57 | 47.57 |
| libri | −0.25s | False | None | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 48.04 | 48.04 |
| libri | −0.50s | False | None | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 47.20 | 47.20 |
| libri | −1.00s | False | None | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 50.72 | 50.72 |
| voices | +0.00s | False | False | none | none | not_configured→not_configured | 38.51 | 38.51 |
| voices | +0.10s | False | False | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 38.42 | 38.42 |
| voices | +0.25s | False | False | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 38.39 | 38.39 |
| voices | +0.50s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 38.24 | 38.39 |
| voices | +1.00s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 39.51 | 0.00 |
| voices | −0.10s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 37.96 | 37.96 |
| voices | −0.25s | False | None | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 37.74 | 37.74 |
| voices | −0.50s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 37.82 | 37.82 |
| voices | −1.00s | False | None | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 35.95 | 35.95 |
| ru1 | +0.00s | True | True | none | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 46.67 | 0.00 |
| ru1 | +0.10s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 46.08 | 0.00 |
| ru1 | +0.25s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 45.88 | 0.00 |
| ru1 | +0.50s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 46.14 | 0.00 |
| ru1 | +1.00s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 57.45 | 0.00 |
| ru1 | −0.10s | True | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 45.74 | 16.06 |
| ru1 | −0.25s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 46.00 | 46.06 |
| ru1 | −0.50s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 45.94 | 45.94 |
| ru1 | −1.00s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 45.95 | 52.10 |
| ru6 | +0.00s | False | False | none | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 45.56 | 45.73 |
| ru6 | +0.10s | False | False | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 45.49 | 45.73 |
| ru6 | +0.25s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 45.83 | 0.00 |
| ru6 | +0.50s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 46.69 | 0.00 |
| ru6 | +1.00s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 45.37 | 0.00 |
| ru6 | −0.10s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 45.57 | 45.73 |
| ru6 | −0.25s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 45.46 | 45.46 |
| ru6 | −0.50s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 46.76 | 46.76 |
| ru6 | −1.00s | False | None | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 43.27 | 43.27 |
| terms | +0.00s | False | False | none | none | not_configured→not_configured | 70.35 | 70.35 |
| terms | +0.10s | False | False | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 68.45 | 68.45 |
| terms | +0.25s | False | False | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | audio_duration_ns | not_configured→not_configured | 68.76 | 68.65 |
| terms | +0.50s | True | True | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 67.85 | 40.84 |
| terms | +1.00s | True | True | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | not_configured→not_configured | 69.89 | 0.00 |
| terms | −0.10s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 69.07 | 69.07 |
| terms | −0.25s | False | None | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 67.53 | 67.53 |
| terms | −0.50s | False | None | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 66.87 | 66.87 |
| terms | −1.00s | False | None | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | not_configured→not_configured | 66.30 | 66.30 |
