# Local ASR quality

One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet / common_voice_19_mirror/en | 100 | 0 | 7.95% | 7.95% | 3.29% | 3.29% | 0.109 / 0.147 |
| parakeet / common_voice_19_mirror/ru | 100 | 0 | 4.90% | 4.90% | 1.59% | 1.59% | 0.091 / 0.157 |
| parakeet-q4-k-m / common_voice_19_mirror/en | 100 | 0 | 8.36% | 8.36% | 3.53% | 3.53% | 0.101 / 0.143 |
| parakeet-q4-k-m / common_voice_19_mirror/ru | 100 | 0 | 5.15% | 5.15% | 1.61% | 1.61% | 0.091 / 0.151 |
| parakeet-q5-k-m / common_voice_19_mirror/en | 100 | 0 | 7.65% | 7.65% | 3.29% | 3.29% | 0.105 / 0.145 |
| parakeet-q5-k-m / common_voice_19_mirror/ru | 100 | 0 | 5.40% | 5.40% | 1.72% | 1.72% | 0.093 / 0.154 |
| parakeet-q6-k / common_voice_19_mirror/en | 100 | 0 | 7.95% | 7.95% | 3.29% | 3.29% | 0.103 / 0.137 |
| parakeet-q6-k / common_voice_19_mirror/ru | 100 | 0 | 5.28% | 5.28% | 1.74% | 1.74% | 0.090 / 0.153 |
| parakeet-f16 / common_voice_19_mirror/en | 100 | 0 | 8.15% | 8.15% | 3.38% | 3.38% | 0.097 / 0.132 |
| parakeet-f16 / common_voice_19_mirror/ru | 100 | 0 | 4.90% | 4.90% | 1.59% | 1.59% | 0.085 / 0.144 |
| parakeet-f32 / common_voice_19_mirror/en | 100 | 0 | 8.05% | 8.05% | 3.29% | 3.29% | 0.104 / 0.140 |
| parakeet-f32 / common_voice_19_mirror/ru | 100 | 0 | 4.90% | 4.90% | 1.59% | 1.59% | 0.098 / 0.153 |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet | ok | 0.219 / 0.058 | 897.3 |
| parakeet-q4-k-m | ok | 0.379 / 0.279 | 637.4 |
| parakeet-q5-k-m | ok | 0.196 / 0.119 | 725.2 |
| parakeet-q6-k | ok | 0.199 / 0.122 | 777.7 |
| parakeet-f16 | ok | 0.380 / 0.061 | 1399.1 |
| parakeet-f32 | ok | 1.318 / 0.192 | 2555.7 |

Paired WER differences (candidate minus baseline), grouped by source:

| Candidate / set / lane | ΔWER pp | 95% interval pp | Groups |
|---|---:|---:|---:|
| parakeet-q4-k-m/common_voice_19_mirror/en/raw | 0.41 | [-0.49, 1.23] | 100 |
| parakeet-q4-k-m/common_voice_19_mirror/en/app | 0.41 | [-0.49, 1.23] | 100 |
| parakeet-q4-k-m/common_voice_19_mirror/ru/raw | 0.25 | [-0.43, 1.13] | 88 |
| parakeet-q4-k-m/common_voice_19_mirror/ru/app | 0.25 | [-0.43, 1.13] | 88 |
| parakeet-q5-k-m/common_voice_19_mirror/en/raw | -0.31 | [-1.18, 0.42] | 100 |
| parakeet-q5-k-m/common_voice_19_mirror/en/app | -0.31 | [-1.18, 0.42] | 100 |
| parakeet-q5-k-m/common_voice_19_mirror/ru/raw | 0.50 | [-0.38, 1.64] | 88 |
| parakeet-q5-k-m/common_voice_19_mirror/ru/app | 0.50 | [-0.38, 1.64] | 88 |
| parakeet-q6-k/common_voice_19_mirror/en/raw | 0.00 | [-0.31, 0.30] | 100 |
| parakeet-q6-k/common_voice_19_mirror/en/app | 0.00 | [-0.31, 0.30] | 100 |
| parakeet-q6-k/common_voice_19_mirror/ru/raw | 0.38 | [0.00, 1.05] | 88 |
| parakeet-q6-k/common_voice_19_mirror/ru/app | 0.38 | [0.00, 1.05] | 88 |
| parakeet-f16/common_voice_19_mirror/en/raw | 0.20 | [0.00, 0.51] | 100 |
| parakeet-f16/common_voice_19_mirror/en/app | 0.20 | [0.00, 0.51] | 100 |
| parakeet-f16/common_voice_19_mirror/ru/raw | 0.00 | [0.00, 0.00] | 88 |
| parakeet-f16/common_voice_19_mirror/ru/app | 0.00 | [0.00, 0.00] | 88 |
| parakeet-f32/common_voice_19_mirror/en/raw | 0.10 | [-0.21, 0.42] | 100 |
| parakeet-f32/common_voice_19_mirror/en/app | 0.10 | [-0.21, 0.42] | 100 |
| parakeet-f32/common_voice_19_mirror/ru/raw | 0.00 | [0.00, 0.00] | 88 |
| parakeet-f32/common_voice_19_mirror/ru/app | 0.00 | [0.00, 0.00] | 88 |
