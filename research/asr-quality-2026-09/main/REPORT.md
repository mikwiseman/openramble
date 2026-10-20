# Local ASR quality

One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet / common_voice_19_mirror/en | 500 | 0 | 8.06% | 8.06% | 3.92% | 3.92% | 0.096 / 0.146 |
| parakeet / common_voice_19_mirror/ru | 500 | 0 | 5.62% | 5.62% | 1.34% | 1.34% | 0.093 / 0.146 |
| parakeet / golos_crowd_mirror/ru | 500 | 0 | 3.21% | 3.21% | 0.66% | 0.66% | 0.075 / 0.137 |
| parakeet / golos_farfield_mirror/ru | 500 | 0 | 7.37% | 7.37% | 2.27% | 2.27% | 0.052 / 0.091 |
| turbo / common_voice_19_mirror/en | 500 | 0 | 12.84% | 12.84% | 7.25% | 7.25% | 1.296 / 1.439 |
| turbo / common_voice_19_mirror/ru | 500 | 0 | 7.88% | 7.88% | 3.32% | 3.32% | 1.164 / 1.378 |
| turbo / golos_crowd_mirror/ru | 500 | 0 | 23.34% | 23.34% | 17.54% | 17.54% | 1.192 / 1.379 |
| turbo / golos_farfield_mirror/ru | 500 | 0 | 19.90% | 19.90% | 6.99% | 6.99% | 1.161 / 1.388 |
| breeze / common_voice_19_mirror/en | 500 | 0 | 9.65% | 9.65% | 4.58% | 4.58% | 1.573 / 1.700 |
| breeze / common_voice_19_mirror/ru | 500 | 0 | 10.05% | 10.05% | 4.24% | 4.24% | 1.775 / 2.190 |
| breeze / golos_crowd_mirror/ru | 500 | 0 | 37.41% | 37.41% | 29.48% | 29.48% | 1.537 / 1.732 |
| breeze / golos_farfield_mirror/ru | 500 | 0 | 38.39% | 38.39% | 23.92% | 23.92% | 1.541 / 1.808 |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet | ok | 0.228 / 0.062 | 914.2 |
| turbo | ok | 0.281 / 1.057 | 1094.4 |
| breeze | ok | 0.749 / 8.332 | 2087.5 |

Paired WER differences (candidate minus baseline), grouped by source:

| Candidate / set / lane | ΔWER pp | 95% interval pp | Groups |
|---|---:|---:|---:|
| turbo/common_voice_19_mirror/en/raw | 4.77 | [3.11, 6.69] | 497 |
| turbo/common_voice_19_mirror/en/app | 4.77 | [3.11, 6.69] | 497 |
| turbo/common_voice_19_mirror/ru/raw | 2.26 | [0.98, 3.50] | 425 |
| turbo/common_voice_19_mirror/ru/app | 2.26 | [0.98, 3.50] | 425 |
| turbo/golos_crowd_mirror/ru/raw | 20.13 | [17.01, 23.41] | 497 |
| turbo/golos_crowd_mirror/ru/app | 20.13 | [17.01, 23.41] | 497 |
| turbo/golos_farfield_mirror/ru/raw | 12.53 | [10.35, 14.70] | 449 |
| turbo/golos_farfield_mirror/ru/app | 12.53 | [10.35, 14.70] | 449 |
| breeze/common_voice_19_mirror/en/raw | 1.58 | [0.65, 2.54] | 497 |
| breeze/common_voice_19_mirror/en/app | 1.58 | [0.65, 2.54] | 497 |
| breeze/common_voice_19_mirror/ru/raw | 4.43 | [2.89, 6.11] | 425 |
| breeze/common_voice_19_mirror/ru/app | 4.43 | [2.89, 6.11] | 425 |
| breeze/golos_crowd_mirror/ru/raw | 34.21 | [30.75, 37.87] | 497 |
| breeze/golos_crowd_mirror/ru/app | 34.21 | [30.75, 37.87] | 497 |
| breeze/golos_farfield_mirror/ru/raw | 31.02 | [27.36, 34.67] | 449 |
| breeze/golos_farfield_mirror/ru/app | 31.02 | [27.36, 34.67] | 449 |
