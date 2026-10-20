# Local ASR quality

One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet / system_speech_long_diagnostic/en | 1 | 0 | 1.11% | 1.11% | 0.59% | 0.59% | 23.418 / 23.418 |
| parakeet / system_speech_long_diagnostic/mixed | 1 | 0 | 17.21% | 17.21% | 10.04% | 10.04% | 29.037 / 29.037 |
| turbo / system_speech_long_diagnostic/en | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | unavailable |
| turbo / system_speech_long_diagnostic/mixed | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | unavailable |
| breeze / system_speech_long_diagnostic/en | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | unavailable |
| breeze / system_speech_long_diagnostic/mixed | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | unavailable |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet | ok | 0.312 / 0.064 | 927.8 |
| turbo | ok | 0.273 / 1.152 | 1068.0 |
| breeze | ok | 0.660 / 3.017 | 2066.2 |

