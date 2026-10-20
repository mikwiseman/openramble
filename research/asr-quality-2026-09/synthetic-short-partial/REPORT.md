# Eleven v4 development diagnostics

36 AI-generated dev examples, 12 texts with three voices each. Reference is the intended fictional script, not independently verified spoken gold. Related voices are grouped by text.


One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet / eleven_v4_short/en | 15 | 0 | 8.70% | 8.70% | 11.44% | 11.44% | 0.187 / 0.294 |
| parakeet / eleven_v4_short/mixed | 6 | 0 | 12.96% | 12.96% | 12.07% | 12.07% | 0.147 / 0.164 |
| parakeet / eleven_v4_short/ru | 15 | 0 | 10.97% | 10.55% | 12.34% | 11.88% | 0.199 / 0.251 |
| turbo / eleven_v4_short/en | 15 | 0 | 6.52% | 6.52% | 7.38% | 7.38% | 1.133 / 1.159 |
| turbo / eleven_v4_short/mixed | 6 | 0 | 9.26% | 9.26% | 9.41% | 9.41% | 1.175 / 1.193 |
| turbo / eleven_v4_short/ru | 15 | 0 | 3.80% | 3.80% | 2.53% | 2.53% | 1.216 / 1.235 |
| breeze / eleven_v4_short/en | 15 | 0 | 6.52% | 6.52% | 9.49% | 9.49% | 1.873 / 2.128 |
| breeze / eleven_v4_short/mixed | 6 | 0 | 15.74% | 15.74% | 6.75% | 6.75% | 1.904 / 2.161 |
| breeze / eleven_v4_short/ru | 15 | 0 | 5.06% | 5.06% | 4.14% | 4.14% | 2.261 / 2.519 |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet | ok | 0.589 / 0.071 | 898.4 |
| turbo | ok | 0.746 / 1.122 | 1055.7 |
| breeze | ok | 1.359 / 9.029 | 2046.0 |

Paired WER differences (candidate minus baseline), grouped by source:

| Candidate / set / lane | ΔWER pp | 95% interval pp | Groups |
|---|---:|---:|---:|
| turbo/eleven_v4_short/en/raw | -2.17 | [-6.67, 0.00] | 5 |
| turbo/eleven_v4_short/en/app | -2.17 | [-6.67, 0.00] | 5 |
| turbo/eleven_v4_short/mixed/raw | -3.70 | [-17.65, 8.77] | 2 |
| turbo/eleven_v4_short/mixed/app | -3.70 | [-17.65, 8.77] | 2 |
| turbo/eleven_v4_short/ru/raw | -7.17 | [-14.72, -0.43] | 5 |
| turbo/eleven_v4_short/ru/app | -6.75 | [-14.29, -0.43] | 5 |
| breeze/eleven_v4_short/en/raw | -2.17 | [-6.67, 0.00] | 5 |
| breeze/eleven_v4_short/en/app | -2.17 | [-6.67, 0.00] | 5 |
| breeze/eleven_v4_short/mixed/raw | 2.78 | [1.75, 3.92] | 2 |
| breeze/eleven_v4_short/mixed/app | 2.78 | [1.75, 3.92] | 2 |
| breeze/eleven_v4_short/ru/raw | -5.91 | [-13.25, -0.43] | 5 |
| breeze/eleven_v4_short/ru/app | -5.49 | [-12.82, -0.43] | 5 |
