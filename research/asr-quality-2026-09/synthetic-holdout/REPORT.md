# Local ASR quality

One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet / eleven_v4_short/en | 15 | 0 | 10.62% | 10.62% | 10.34% | 10.34% | 0.109 / 0.140 |
| parakeet / eleven_v4_short/mixed | 6 | 0 | 11.46% | 11.46% | 7.05% | 7.05% | 0.116 / 0.123 |
| parakeet / eleven_v4_short/ru | 15 | 0 | 9.52% | 9.09% | 8.47% | 8.01% | 0.117 / 0.149 |
| turbo / eleven_v4_short/en | 15 | 0 | 5.49% | 5.49% | 4.81% | 4.81% | 1.086 / 1.116 |
| turbo / eleven_v4_short/mixed | 6 | 0 | 8.33% | 8.33% | 4.49% | 4.49% | 1.105 / 1.126 |
| turbo / eleven_v4_short/ru | 15 | 0 | 3.03% | 3.03% | 3.31% | 3.31% | 1.126 / 1.165 |
| breeze / eleven_v4_short/en | 15 | 0 | 6.96% | 6.96% | 7.69% | 7.69% | 1.679 / 1.729 |
| breeze / eleven_v4_short/mixed | 6 | 0 | 16.67% | 16.67% | 8.12% | 8.12% | 1.670 / 1.749 |
| breeze / eleven_v4_short/ru | 15 | 0 | 9.52% | 9.52% | 4.62% | 4.62% | 1.791 / 1.950 |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet | ok | 0.205 / 0.055 | 895.4 |
| turbo | ok | 0.326 / 1.033 | 1085.4 |
| breeze | ok | 0.593 / 1.567 | 2090.2 |

Paired WER differences (candidate minus baseline), grouped by source:

| Candidate / set / lane | ΔWER pp | 95% interval pp | Groups |
|---|---:|---:|---:|
| turbo/eleven_v4_short/en/raw | -5.13 | [-14.40, 0.00] | 5 |
| turbo/eleven_v4_short/en/app | -5.13 | [-14.40, 0.00] | 5 |
| turbo/eleven_v4_short/mixed/raw | -3.12 | [-5.88, 0.00] | 2 |
| turbo/eleven_v4_short/mixed/app | -3.12 | [-5.88, 0.00] | 2 |
| turbo/eleven_v4_short/ru/raw | -6.49 | [-14.23, 0.00] | 5 |
| turbo/eleven_v4_short/ru/app | -6.06 | [-13.82, 0.00] | 5 |
| breeze/eleven_v4_short/en/raw | -3.66 | [-9.85, 0.00] | 5 |
| breeze/eleven_v4_short/en/app | -3.66 | [-9.85, 0.00] | 5 |
| breeze/eleven_v4_short/mixed/raw | 5.21 | [-6.67, 15.69] | 2 |
| breeze/eleven_v4_short/mixed/app | 5.21 | [-6.67, 15.69] | 2 |
| breeze/eleven_v4_short/ru/raw | 0.00 | [-4.71, 5.63] | 5 |
| breeze/eleven_v4_short/ru/app | 0.43 | [-4.71, 7.04] | 5 |
