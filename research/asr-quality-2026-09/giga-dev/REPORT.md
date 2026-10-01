# Local ASR quality

One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet / common_voice_19_mirror/ru | 100 | 0 | 4.90% | 4.90% | 1.59% | 1.59% | 0.079 / 0.131 |
| gigaam-e2e-ctc / common_voice_19_mirror/ru | 100 | 0 | 3.27% | 3.27% | 1.30% | 1.30% | 0.038 / 0.062 |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet | ok | 0.347 / 0.067 | 897.4 |
| gigaam-e2e-ctc | ok | 0.095 / 0.223 | 332.2 |

Paired WER differences (candidate minus baseline), grouped by source:

| Candidate / set / lane | ΔWER pp | 95% interval pp | Groups |
|---|---:|---:|---:|
| gigaam-e2e-ctc/common_voice_19_mirror/ru/raw | -1.63 | [-3.26, -0.28] | 88 |
| gigaam-e2e-ctc/common_voice_19_mirror/ru/app | -1.63 | [-3.26, -0.28] | 88 |
