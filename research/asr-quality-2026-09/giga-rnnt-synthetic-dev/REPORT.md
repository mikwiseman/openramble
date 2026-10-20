# Local ASR quality

One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet / eleven_v4_short/ru | 15 | 0 | 10.97% | 10.55% | 12.34% | 11.88% | 0.154 / 0.181 |
| gigaam-e2e-ctc / eleven_v4_short/ru | 15 | 0 | 13.50% | 13.50% | 10.50% | 10.50% | 0.070 / 0.084 |
| gigaam-v3-e2e-rnnt / eleven_v4_short/ru | 15 | 0 | 13.08% | 11.39% | 11.11% | 9.43% | 0.079 / 0.094 |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet | ok | 0.232 / 0.062 | 895.9 |
| gigaam-e2e-ctc | ok | 0.100 / 0.023 | 334.0 |
| gigaam-v3-e2e-rnnt | ok | 0.109 / 0.037 | 345.3 |

Paired WER differences (candidate minus baseline), grouped by source:

| Candidate / set / lane | ΔWER pp | 95% interval pp | Groups |
|---|---:|---:|---:|
| gigaam-e2e-ctc/eleven_v4_short/ru/raw | 2.53 | [-6.93, 12.85] | 5 |
| gigaam-e2e-ctc/eleven_v4_short/ru/app | 2.95 | [-6.93, 14.06] | 5 |
| gigaam-v3-e2e-rnnt/eleven_v4_short/ru/raw | 2.11 | [-6.93, 11.65] | 5 |
| gigaam-v3-e2e-rnnt/eleven_v4_short/ru/app | 0.84 | [-6.93, 7.42] | 5 |
