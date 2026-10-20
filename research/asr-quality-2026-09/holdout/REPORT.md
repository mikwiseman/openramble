# Local ASR quality

One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet / fleurs/en | 647 | 0 | 5.44% | 5.44% | 2.45% | 2.45% | 0.138 / 0.235 |
| parakeet / fleurs/ru | 775 | 0 | 5.55% | 5.55% | 1.64% | 1.64% | 0.162 / 0.286 |
| turbo / fleurs/en | 647 | 0 | 4.92% | 4.92% | 2.23% | 2.23% | 1.160 / 1.232 |
| turbo / fleurs/ru | 775 | 1 | 4.80% | 4.80% | 1.67% | 1.67% | 1.206 / 1.337 |
| breeze / fleurs/en | 647 | 0 | 5.39% | 5.39% | 2.87% | 2.87% | 2.080 / 2.387 |
| breeze / fleurs/ru | 775 | 1 | 6.74% | 6.74% | 3.30% | 3.30% | 2.243 / 2.848 |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet | ok | 0.206 / 0.048 | 940.7 |
| turbo | ok | 0.261 / 1.022 | 1097.7 |
| breeze | ok | 0.716 / 2.217 | 2084.3 |

Paired WER differences (candidate minus baseline), grouped by source:

| Candidate / set / lane | ΔWER pp | 95% interval pp | Groups |
|---|---:|---:|---:|
| turbo/fleurs/en/raw | -0.51 | [-0.91, -0.14] | 350 |
| turbo/fleurs/en/app | -0.51 | [-0.91, -0.14] | 350 |
| turbo/fleurs/ru/raw | -0.75 | [-1.45, 0.19] | 344 |
| turbo/fleurs/ru/app | -0.75 | [-1.45, 0.19] | 344 |
| breeze/fleurs/en/raw | -0.04 | [-0.62, 0.51] | 350 |
| breeze/fleurs/en/app | -0.04 | [-0.62, 0.51] | 350 |
| breeze/fleurs/ru/raw | 1.19 | [0.44, 2.13] | 344 |
| breeze/fleurs/ru/app | 1.19 | [0.44, 2.13] | 344 |
