# CV19 development screen

200 human-speech dev examples; no holdout inference; file timing is screening evidence.


One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet / common_voice_19_mirror/en | 100 | 0 | 7.95% | 7.95% | 3.29% | 3.29% | 0.099 / 0.147 |
| parakeet / common_voice_19_mirror/ru | 100 | 0 | 4.90% | 4.90% | 1.59% | 1.59% | 0.096 / 0.165 |
| turbo / common_voice_19_mirror/en | 100 | 0 | 12.44% | 12.44% | 6.20% | 6.20% | 1.134 / 1.167 |
| turbo / common_voice_19_mirror/ru | 100 | 0 | 8.54% | 8.54% | 3.23% | 3.23% | 1.144 / 1.245 |
| breeze / common_voice_19_mirror/en | 100 | 0 | 8.15% | 8.15% | 3.71% | 3.71% | 1.617 / 1.877 |
| breeze / common_voice_19_mirror/ru | 100 | 0 | 10.05% | 10.05% | 4.74% | 4.74% | 1.688 / 1.947 |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet | ok | 0.623 / 0.086 | 875.9 |
| turbo | ok | 0.283 / 1.183 | 1091.3 |
| breeze | ok | 0.708 / 3.400 | 2081.7 |

Paired WER differences (candidate minus baseline), grouped by source:

| Candidate / set / lane | ΔWER pp | 95% interval pp | Groups |
|---|---:|---:|---:|
| turbo/common_voice_19_mirror/en/raw | 4.49 | [1.44, 8.24] | 100 |
| turbo/common_voice_19_mirror/en/app | 4.49 | [1.44, 8.24] | 100 |
| turbo/common_voice_19_mirror/ru/raw | 3.64 | [1.15, 6.51] | 88 |
| turbo/common_voice_19_mirror/ru/app | 3.64 | [1.15, 6.51] | 88 |
| breeze/common_voice_19_mirror/en/raw | 0.20 | [-1.36, 1.93] | 100 |
| breeze/common_voice_19_mirror/en/app | 0.20 | [-1.36, 1.93] | 100 |
| breeze/common_voice_19_mirror/ru/raw | 5.15 | [2.62, 8.09] | 88 |
| breeze/common_voice_19_mirror/ru/app | 5.15 | [2.62, 8.09] | 88 |
