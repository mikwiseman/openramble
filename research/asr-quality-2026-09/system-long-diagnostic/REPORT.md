# Local ASR quality

One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet / system_speech_long_diagnostic/ru | 1 | 0 | 2.98% | 2.88% | 1.12% | 1.04% | 31.665 / 31.665 |
| turbo / system_speech_long_diagnostic/ru | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | unavailable |
| breeze / system_speech_long_diagnostic/ru | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | unavailable |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet | ok | 0.273 / 0.056 | 924.5 |
| turbo | ok | 0.276 / 1.139 | 1067.9 |
| breeze | ok | 0.624 / 2.690 | 2062.6 |

