# Existing long-file compatibility diagnostic

One existing 58.24-second system-voice fixture. A repeated script diagnoses compatibility; it is not a genuine fifteen-minute track. A one-group interval is degenerate and provides no population uncertainty estimate.


One quality pass per frozen example. Errors remain in the denominator.

| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| parakeet / existing_system_voice_diagnostic/mixed | 1 | 0 | 27.52% | 24.77% | 16.79% | 14.07% | 1.295 / 1.295 |
| turbo / existing_system_voice_diagnostic/mixed | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | unavailable |
| breeze / existing_system_voice_diagnostic/mixed | 1 | 1 | 100.00% | 100.00% | 100.00% | 100.00% | unavailable |

File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.
Peak memory is the high-water mark of one fresh process per model, never a per-file increment.
Public, synthetic and private sources must use separate manifests and reports.

| Model | Process status | Load / warm-up s | Process peak MiB |
|---|---|---:|---:|
| parakeet | ok | 0.450 / 0.066 | 906.1 |
| turbo | ok | 0.402 / 1.313 | 1047.5 |
| breeze | ok | 0.578 / 2.388 | 2035.0 |

Paired WER differences (candidate minus baseline), grouped by source:

| Candidate / set / lane | ΔWER pp | 95% interval pp | Groups |
|---|---:|---:|---:|
| turbo/existing_system_voice_diagnostic/mixed/raw | 72.48 | [72.48, 72.48] | 1 |
| turbo/existing_system_voice_diagnostic/mixed/app | 75.23 | [75.23, 75.23] | 1 |
| breeze/existing_system_voice_diagnostic/mixed/raw | 72.48 | [72.48, 72.48] | 1 |
| breeze/existing_system_voice_diagnostic/mixed/app | 75.23 | [75.23, 75.23] | 1 |
