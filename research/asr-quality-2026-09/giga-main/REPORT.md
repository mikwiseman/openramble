# Local ASR quality

One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet / common_voice_19_mirror/ru | 500 | 0 | 5.62% | 5.62% | 1.34% | 1.34% | 0.104 / 0.158 |
| parakeet / golos_crowd_mirror/ru | 500 | 0 | 3.21% | 3.21% | 0.66% | 0.66% | 0.079 / 0.139 |
| parakeet / golos_farfield_mirror/ru | 500 | 0 | 7.37% | 7.37% | 2.27% | 2.27% | 0.058 / 0.097 |
| gigaam-e2e-ctc / common_voice_19_mirror/ru | 500 | 0 | 2.24% | 2.24% | 0.63% | 0.63% | 0.052 / 0.080 |
| gigaam-e2e-ctc / golos_crowd_mirror/ru | 500 | 0 | 19.16% | 19.16% | 16.03% | 16.03% | 0.040 / 0.075 |
| gigaam-e2e-ctc / golos_farfield_mirror/ru | 500 | 0 | 7.23% | 7.23% | 2.91% | 2.91% | 0.031 / 0.048 |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet | ok | 0.223 / 0.053 | 909.5 |
| gigaam-e2e-ctc | ok | 0.109 / 0.031 | 339.6 |

Paired WER differences (candidate minus baseline), grouped by source:

| Candidate / set / lane | ΔWER pp | 95% interval pp | Groups |
|---|---:|---:|---:|
| gigaam-e2e-ctc/common_voice_19_mirror/ru/raw | -3.38 | [-4.39, -2.36] | 425 |
| gigaam-e2e-ctc/common_voice_19_mirror/ru/app | -3.38 | [-4.39, -2.36] | 425 |
| gigaam-e2e-ctc/golos_crowd_mirror/ru/raw | 15.95 | [12.67, 19.43] | 497 |
| gigaam-e2e-ctc/golos_crowd_mirror/ru/app | 15.95 | [12.67, 19.43] | 497 |
| gigaam-e2e-ctc/golos_farfield_mirror/ru/raw | -0.14 | [-1.56, 1.21] | 449 |
| gigaam-e2e-ctc/golos_farfield_mirror/ru/app | -0.14 | [-1.56, 1.21] | 449 |
