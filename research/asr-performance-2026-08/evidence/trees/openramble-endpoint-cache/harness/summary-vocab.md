# Endpoint-cache product matrix

- vocabulary enabled: `True` (28 terms)
- deterministic repeats: `True`
- unique PCM / runs: 49 / 98
- process peak RSS: 184.4 MiB
- inference median / max: 49.63 / 95.19 ms
- endpoint-eligible exact digest: 14 / 14
- eligible canonical-vs-raw acoustic parity: 0 / 14
- eligible result already complete at stop: 11 / 14

| fixture | change | eligible | digest | raw→base changed | canonical→raw changed | vocab | raw ms | cached wait ms |
|---|---:|:---:|:---:|---|---|---|---:|---:|
| libri | +0.00s | False | False | none | none | no_candidate→no_candidate | 49.13 | 49.13 |
| libri | +0.10s | False | False | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 59.31 | 59.31 |
| libri | +0.25s | False | False | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 50.16 | 50.16 |
| libri | +0.50s | True | True | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 50.44 | 50.16 |
| libri | +1.00s | True | True | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 53.41 | 0.00 |
| libri | −0.10s | False | None | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 49.52 | 49.52 |
| libri | −0.25s | False | None | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 52.17 | 52.17 |
| libri | −0.50s | False | None | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 50.27 | 50.27 |
| libri | −1.00s | False | None | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 50.39 | 50.39 |
| voices | +0.00s | False | False | none | none | no_candidate→no_candidate | 39.04 | 39.04 |
| voices | +0.10s | False | False | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 38.90 | 38.90 |
| voices | +0.25s | False | False | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 41.48 | 41.48 |
| voices | +0.50s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 38.55 | 41.48 |
| voices | +1.00s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 41.67 | 0.00 |
| voices | −0.10s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 39.22 | 39.22 |
| voices | −0.25s | False | None | raw_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 38.52 | 38.52 |
| voices | −0.50s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 38.59 | 38.59 |
| voices | −1.00s | False | None | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 36.42 | 36.42 |
| ru1 | +0.00s | True | True | none | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 47.97 | 0.00 |
| ru1 | +0.10s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 49.02 | 0.00 |
| ru1 | +0.25s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 48.05 | 0.00 |
| ru1 | +0.50s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 48.96 | 0.00 |
| ru1 | +1.00s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 54.53 | 0.00 |
| ru1 | −0.10s | True | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 47.03 | 22.27 |
| ru1 | −0.25s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 46.66 | 52.27 |
| ru1 | −0.50s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 48.21 | 48.21 |
| ru1 | −1.00s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 47.02 | 53.99 |
| ru6 | +0.00s | False | False | none | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 51.55 | 51.67 |
| ru6 | +0.10s | False | False | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 46.75 | 51.67 |
| ru6 | +0.25s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 46.50 | 0.00 |
| ru6 | +0.50s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 50.69 | 0.00 |
| ru6 | +1.00s | True | True | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 53.36 | 0.00 |
| ru6 | −0.10s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | no_candidate→no_candidate | 52.37 | 51.67 |
| ru6 | −0.25s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 49.57 | 49.57 |
| ru6 | −0.50s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 48.38 | 48.38 |
| ru6 | −1.00s | False | None | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | no_candidate→no_candidate | 49.94 | 49.94 |
| terms | +0.00s | False | False | none | none | rescored_modified→rescored_modified | 91.51 | 91.51 |
| terms | +0.10s | False | False | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | rescored_modified→rescored_modified | 83.36 | 83.36 |
| terms | +0.25s | False | False | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | audio_duration_ns | rescored_modified→rescored_modified | 84.11 | 83.61 |
| terms | +0.50s | True | True | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | rescored_modified→rescored_modified | 83.29 | 55.80 |
| terms | +1.00s | True | True | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | token_timing_sha256, word_timing_sha256, audio_duration_ns | rescored_modified→rescored_modified | 85.97 | 0.00 |
| terms | −0.10s | False | None | token_timing_sha256, word_timing_sha256, audio_duration_ns | none | rescored_modified→rescored_modified | 84.87 | 84.87 |
| terms | −0.25s | False | None | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | rescored_modified→rescored_modified | 82.64 | 82.64 |
| terms | −0.50s | False | None | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | rescored_modified→rescored_modified | 81.59 | 81.59 |
| terms | −1.00s | False | None | raw_transcript_sha256, normalized_transcript_sha256, token_timing_sha256, word_timing_sha256, audio_duration_ns | none | rescored_modified→rescored_modified | 86.37 | 86.37 |
