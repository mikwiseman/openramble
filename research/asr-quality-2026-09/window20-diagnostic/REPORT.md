# Local ASR quality

One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet-window20 / system_speech_long_diagnostic/en | 1 | 0 | 1.07% | 1.07% | 0.61% | 0.61% | 23.963 / 23.963 |
| parakeet-window20 / system_speech_long_diagnostic/mixed | 1 | 0 | 14.74% | 14.71% | 7.74% | 7.75% | 29.907 / 29.907 |
| parakeet-window20 / system_speech_long_diagnostic/ru | 1 | 0 | 3.01% | 2.92% | 1.15% | 1.07% | 33.921 / 33.921 |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet-window20 | ok | 9.001 / 0.076 | 917.2 |

