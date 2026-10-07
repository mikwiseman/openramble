# OpenRamble: speed and quality benchmark, 7 October 2026

Open [the visual benchmark](index.html) or read [the Russian research report](REPORT.ru.md).

This is an evidence refresh and a reproducible presentation of the existing
30 September–1 October study, not a new inference run. No production code,
model, setting or release is changed. The source study is commit
`53dca43` on `codex/asr-quality-20260930`; its product baseline is OpenRamble
0.31.2 / transcribe.cpp 0.2.3, commit
`ed1d0fe14bda180e7f6977b664f0d9d14e0455fc`.

The benchmark covers 3,422 public human recordings across six language/domain
sets, plus a separately labeled 36-recording synthetic holdout. It compares
model configurations inside the OpenRamble harness. These are not measurements
of official Handy, klava-nevinovata, or other GUI applications.

- [benchmark.json](benchmark.json): derived values, counts, paired intervals,
  scope and source checksums. Missing measurements remain absent.
- [quality.png](quality.png), [quality.svg](quality.svg): exportable human-speech
  WER figure; values are generated from the original JSON, not typed into a chart.
- [PROTOCOL.md](PROTOCOL.md): staged reuse of existing evidence, comparison
  rules, and a separately scoped future custom eval.
- [sources.json](sources.json): external source inventory checked on 7 October.
- [build.py](build.py): validates and rebuilds the data, plots and standalone HTML.

From this directory, with Python and Matplotlib installed:

```sh
python3 build.py
```

Matplotlib 3.11.2 was used for this export. The builder uses the Python standard
library otherwise, makes no network requests and reads only curated aggregate
reports. It does not execute ASR, access private audio, or touch installed models.
The existing inference and scoring entry points remain documented in
[docs/benchmarks.md](../../docs/benchmarks.md).

The headline conclusion is bounded: the shipping configuration is a strong
default in the tested class, but a claim of overall market leadership is not
established. The highest-value next experiments are the newer native runtime,
properly tuned Whisper controls, and a genuine RU/EN streaming candidate.

The Russian report also contains a staged improvement roadmap: small runtime
and text-correction experiments, measured pipeline issues, ready-made model
alternatives, and only then a GPU fine-tuning pilot that must verify export back
to Mac. Fine-tuning needs checked audio/transcript pairs; text-only adaptation
and TTS-derived training are described separately. No training was launched.

## Verification of this presentation

The builder validated 32 model/domain rows, shared reference denominators,
3,422 human inputs and 36 synthetic holdout inputs. Seven input report hashes
and 41 local document links were checked. The rendered page was inspected in
the Codex browser: human/synthetic switching, the mixed subset, FLEURS RU
failures and paired intervals, and narrow-window layout; no console warnings
or errors were recorded. The final PNG was visually inspected.

`./scripts/check.sh --fast` passed its DictationCore, LocalASR and shared-core
stages (three LocalASR tests skipped), then stopped at the Swift/Rust bridge.
`./scripts/build-ffi.sh` reproduced a `mis-aligned LINKEDIT string pool` error
while loading a generated Rust proc-macro library. The host reports Rust 1.88.0;
CI pins 1.97.1. The repository gate is **not green** on this host. No application
source was modified to work around that build failure.

The subsequent [CI run for `ba173f0`](https://github.com/mikwiseman/openramble/actions/runs/37576330235)
completed all 14 checks successfully, including the Swift/Rust bridge. This
confirms that commit's CI result without changing the local failure record.
The following roadmap extension changes prose and the source inventory only.

Its local `check.sh --fast` retry passed DictationCore and then stopped earlier,
in LocalASR: the existing ready-PCM-to-test-insertion latency test measured
1.0345 s for the fixture labeled “half a minute”, over its 1 s budget. This
single observation is recorded in the roadmap, not imported into the benchmark
charts or treated as a controlled regression. No thresholds were changed.
