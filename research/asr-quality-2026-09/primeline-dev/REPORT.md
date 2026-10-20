# Local ASR quality

One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet / common_voice_19_mirror/en | 100 | 0 | 7.95% | 7.95% | 3.29% | 3.29% | 0.109 / 0.147 |
| parakeet / common_voice_19_mirror/ru | 100 | 0 | 4.90% | 4.90% | 1.59% | 1.59% | 0.091 / 0.157 |
| parakeet-primeline / common_voice_19_mirror/en | 100 | 0 | 9.48% | 9.48% | 5.11% | 5.11% | 0.108 / 0.145 |
| parakeet-primeline / common_voice_19_mirror/ru | 100 | 0 | 8.17% | 8.17% | 2.42% | 2.42% | 0.092 / 0.158 |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet | ok | 0.219 / 0.058 | 897.3 |
| parakeet-primeline | ok | 0.277 / 0.058 | 901.3 |

Paired WER differences (candidate minus baseline), grouped by source:

| Candidate / set / lane | ΔWER pp | 95% interval pp | Groups |
|---|---:|---:|---:|
| parakeet-primeline/common_voice_19_mirror/en/raw | 1.53 | [0.10, 3.09] | 100 |
| parakeet-primeline/common_voice_19_mirror/en/app | 1.53 | [0.10, 3.09] | 100 |
| parakeet-primeline/common_voice_19_mirror/ru/raw | 3.27 | [1.87, 4.84] | 88 |
| parakeet-primeline/common_voice_19_mirror/ru/app | 3.27 | [1.87, 4.84] | 88 |
