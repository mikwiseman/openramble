# Speech runtime spike, October 2026

OpenRamble runs Parakeet TDT 0.6B through transcribe.cpp 0.4.1 today, with
Metal on the Mac and the CPU on Windows and Linux, and ships Parakeet Ultra as
Q4_K_M GGUF. This folder makes three other runtimes runnable on this Mac so
that a later session can time them one at a time with a single command each.
Nothing here is a measurement. The only runs were smoke tests on two short
synthetic files, and the times quoted below come from single runs. The
measurements and the recommendation are in `RESULTS.md`.

Everything installed for the spike is under `~/Library/Caches/OpenRambleSpike`
(called `$SPIKE` below). Nothing was committed, and nothing under
`~/Library/Application Support/OpenRamble` was changed.

## The runner contract

Every runner takes the same two arguments.

```
<runner> [options] <manifest.jsonl> <out.jsonl>
```

- Each manifest row is `{"id": ..., "path": "/abs/16khz-mono.wav"}`. The WAV
  must be 16 kHz, mono, 16-bit PCM.
- The runner loads the model once. The first output row is
  `{"id": "__load__", "load_seconds": ..., "runner": ..., "model": ...}`, and
  the runner also prints `load_seconds N` to stderr.
- Each later row is `{"id", "text", "audio_seconds", "wall_seconds"}`, in
  manifest order.
- `wall_seconds` covers recognition of samples that are already in memory,
  which means mel features, encoder and greedy decoding. Reading the WAV file
  is outside the clock in every runner.
- No runner passes a language hint, because the app has none.
- `SPIKE_ROOT` overrides `$SPIKE`.

The measuring session should know these things about the numbers:

- The first file of a process includes one-time work in every runtime, e.g.
  Metal kernel compilation in MLX (2.3 s on the first smoke file against 0.1 s
  on the second) and the first Core ML GPU prediction (1.8 s against 0.08 s).
  Put a warm-up row at the top of the manifest and drop it, or report it as
  first-file latency.
- `/usr/bin/time -l` reports both "maximum resident set size" and "peak memory
  footprint". Do not wrap the runner in `timeout` or another launcher, because
  then the footprint line describes the launcher. Running the venv's `python`
  directly is fine, since it reports the interpreter's own footprint.
- Core ML models placed on the Neural Engine are not counted in the process's
  memory. FluidAudio's runner showed 87 MB resident and 46 MB footprint with
  the whole Ultra model loaded on the Neural Engine. System memory has to be
  measured another way for FluidAudio, e.g. by watching `vm_stat` around the
  run.
- Core ML compiles each model for the Neural Engine on its first load and keeps
  the result in `~/Library/Caches/fluidaudio-runner/com.apple.e5rt.e5bundlecache`
  (1.2 GB now). The first load of v3 took 17.1 s and of Ultra 12.6 s, and a
  later load of either took 0.27 to 0.28 s. Deleting that folder makes the next
  load a true cold start again.
- The research handoff in `research/asr-performance-2026-08` asks for one model
  lane at a time on this Mac. `/Applications/OpenRamble.app` was running, idle,
  during the smoke tests and was left alone.

## Smoke inputs

The two files are in `smoke/`, made with `say` and converted with
`afconvert -f WAVE -d LEI16@16000 -c 1`. `smoke/manifest.jsonl` lists both.

| id | Voice | Seconds | Text spoken | SHA-256 |
|---|---|---:|---|---|
| en | default (Samantha) | 5.61 | Please send the quarterly report to Anna before Friday, and remind her about the meeting at three o'clock. | `263366cc6e2254880c02c865fa7423dc0b3bb343d6888836fe8a008945665917` |
| ru | Milena | 5.56 | Привет! Сегодня мы проверяем распознавание русской речи, и результат должен быть точным. | `4cb73c7e8e213f7a0dff02205d9cb4aad0389bd95b54a1c9eef07c6b1fe7cdf9` |

## Commands

Run these from any directory. `R` is this folder.

```bash
R=/Users/mikwiseman/Documents/Code/openramble/.claude/worktrees/pensive-meitner-e4d5e6/research/runtime-spike-2026-10
SPIKE=~/Library/Caches/OpenRambleSpike

# 1. sherpa-onnx, CPU (models: v3-int8, v3-fp32, ultra-int8; --threads defaults to 4)
/usr/bin/time -l $SPIKE/sherpa-onnx/venv/bin/python -I $R/runners/sherpa_onnx_runner.py \
  --model v3-int8 --threads 4 manifest.jsonl out.jsonl
# the same with the Core ML execution provider
/usr/bin/time -l $SPIKE/sherpa-onnx/venv/bin/python -I $R/runners/sherpa_onnx_runner.py \
  --model v3-int8 --provider coreml manifest.jsonl out.jsonl

# 2. parakeet-mlx, Apple GPU (models: v3, ultra; --dtype bfloat16 | float16 | float32; optional --chunk SECONDS)
/usr/bin/time -l $SPIKE/parakeet-mlx/venv/bin/python -I $R/runners/parakeet_mlx_runner.py \
  --model v3 --dtype bfloat16 manifest.jsonl out.jsonl

# 3. FluidAudio, Core ML (models: v3, ultra; --units ane | gpu | cpu for the encoder)
/usr/bin/time -l $SPIKE/fluidaudio/build/release/fluidaudio-runner \
  --model v3 --units ane manifest.jsonl out.jsonl
```

To rebuild the FluidAudio runner:

```bash
cd $R/runners/fluidaudio-swift
swift build -c release -j 4 --scratch-path ~/Library/Caches/OpenRambleSpike/fluidaudio/build
```

To fetch a model again, `hf_fetch.py` downloads one Hugging Face repository at
a pinned commit and checks every large file against the SHA-256 that the Hub
lists for it, e.g.

```bash
python3 -I $R/hf_fetch.py csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8 \
  2bda32ec70b097a55adaa07d9a7173915b43cc78 $SPIKE/sherpa-onnx/models/v3-int8 decoder encoder joiner tokens
```

The repository and commit of every model are in the candidate sections below,
and `models.sha256` lists the SHA-256 and size of every model file on disk.

## Smoke results

Every configuration below produced the right words in both languages. The
outputs are in `smoke/out-*.jsonl` and the logs in `smoke/log-*.txt`. Each row
is one run. The English file was always the first file of the process, so its
time includes the one-time work described above, and the Russian file shows the
warm time. "First" load means the first load after download.

| Runtime and model | Accelerator | Load, s | en (first file), s | ru (second file), s | Max RSS |
|---|---|---:|---:|---:|---:|
| sherpa-onnx, v3 int8 | CPU, 4 threads | 1.23 | 0.171 | 0.139 | 1.69 GB |
| sherpa-onnx, Ultra int8 | CPU, 4 threads | 0.98 | 0.182 | 0.147 | 1.65 GB |
| sherpa-onnx, v3 int8 | Core ML EP | 5.71 | 0.885 | 0.404 | 2.35 GB |
| sherpa-onnx, v3 fp32 | CPU, 4 threads | 7.81 (first) | 1.195 | 0.137 | 2.66 GB |
| sherpa-onnx, v3 fp32 | Core ML EP | 13.11 | 1.009 | 0.450 | 3.69 GB |
| parakeet-mlx, v3 bf16 | GPU | 0.76 (9.2 first) | 2.271 | 0.097 | 0.86 GB |
| parakeet-mlx, Ultra bf16 | GPU | 0.60 | 0.240 | 0.098 | 1.40 GB, footprint 2.52 GB |
| parakeet-mlx, Ultra fp16 | GPU | 0.23 | 0.342 | 0.095 | 1.39 GB, footprint 2.52 GB |
| FluidAudio, v3 | Neural Engine | 17.06 first, 0.28 cached | 0.074 | 0.049 | 0.49 GB (see above) |
| FluidAudio, Ultra | Neural Engine | 12.60 first, 0.27 cached | 0.070 | 0.055 | 0.65 GB (see above) |
| FluidAudio, v3 | GPU encoder | 8.48 | 1.762 | 0.082 | 2.42 GB |

The transcripts were the following.

- English, every configuration: "Please send the quarterly report to Anna
  before Friday, and remind her about the meeting at 3 o'clock." FluidAudio v3
  and parakeet-mlx v3 wrote "three o'clock" instead of "3 o'clock".
- Russian, every configuration: "Привет, сегодня мы проверяем распознавание
  русской речи, и результат должен быть точным." Every runtime wrote a comma
  where the text given to `say` had "!".

## 1. sherpa-onnx

| | |
|---|---|
| Version | sherpa-onnx 1.13.8 from PyPI (`sherpa-onnx` and `sherpa-onnx-core`), tag `v1.13.8`, commit `11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf`, released 10 September 2026. It bundles ONNX Runtime 1.28.2. Versions 2.0.0 (23 October) and 2.0.1 (27 October) are newer, and 1.13.8 was chosen because it had been out for seven weeks. |
| Installed at | `$SPIKE/sherpa-onnx/venv` (61 MB, Python 3.13.3, numpy 2.5.4), models in `$SPIKE/sherpa-onnx/models/{v3-int8,v3-fp32,ultra-int8}` |
| Model v3 int8 | [csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8](https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8) at `2bda32ec70b097a55adaa07d9a7173915b43cc78`, 670,478,772 bytes. `encoder.int8.onnx` `acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247`, `decoder.int8.onnx` `179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e`, `joiner.int8.onnx` `3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3`, `tokens.txt` `d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d`. The GitHub release `asr-models` has the same model as `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2`. csukuangfj is the sherpa-onnx maintainer. |
| Model v3 fp32 | [csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3](https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3) at `1a468a35cbba69418f126de829e75261dea4a4e4`, 2,549,800,429 bytes. `encoder.onnx` `3eed7ce424bf8339ad09233533c687e2dbd07e74ccf5027b5e7344019ea373b0` with external weights `encoder.weights` `3af3f51af5f2d01dbbf5af47d42c7962a2c205f11004254bb4f2b979862f39a8` (2,435,420,160 bytes), `decoder.onnx` `d593cdb0e571f5a457ec2219af9968cbf6b0e8198e8f7839b40a8754593bf68c`, `joiner.onnx` `b9b0bcf88ac571902e69a6536223ed2d94885e981b85045410f1403d53121a63`. I found no fp16 export of v3 from k2-fsa. |
| Model Ultra int8 | [leogaudin/sherpa-onnx-nemo-parakeet-ultra-int8](https://huggingface.co/leogaudin/sherpa-onnx-nemo-parakeet-ultra-int8) at `f7bc472677ff70be95cdb0ef9df509fee6f5ec0b`, 670,576,831 bytes of model files. `encoder.int8.onnx` `8bd3b8dc07056def6dfd19910e9f90c9e1a4e7e20901f58bdfe2a570a8081a2a`, `decoder.int8.onnx` `94373c6405c8149d1c9d1e9862514e0e3e88dab1c7de18fac9d5df9c6ba5efdd`, `joiner.int8.onnx` `8a71aaccfdba3d451775507a889afd2257d2e754463fd81095a8c8f290f924c2`, `tokens.txt` identical to v3's. This is a third-party conversion (see the Ultra section). |
| License | sherpa-onnx Apache-2.0, ONNX Runtime MIT, NVIDIA Parakeet v3 CC-BY-4.0, Parakeet Ultra CC-BY-4.0 |
| Platforms | Prebuilt for macOS arm64 and x86_64 (also universal2), Linux x86_64 and aarch64, Windows x64, x86 and arm64, as PyPI wheels and as C libraries in the GitHub release (`sherpa-onnx-v1.13.8-osx-universal2-static.tar.bz2`, `-linux-x64-static`, `-win-x64-*`, and others). |
| Accelerator | CPU. The Core ML execution provider (`--provider coreml`) loads and gives the same text, but it was slower than the CPU in both smoke runs, 0.40 s against 0.14 s for the int8 model and 0.45 s against 0.14 s for fp32 on the second file, with 0.7 to 1.0 GB more memory. sherpa-onnx 1.13.8 turns the provider on with flags 0 (`sherpa-onnx/csrc/session.cc`, line 380), which means the older NeuralNetwork format, no MLProgram and no cache of compiled models. Operators that the provider cannot take, most likely including the int8 ones, stay on the CPU, so the graph is split between Core ML and the CPU. A fair Core ML test of sherpa-onnx would need a build with other flags. CUDA builds exist for Linux and Windows. |
| Word timestamps | Yes. `stream.result` has `tokens`, `timestamps` and `durations` per token, and a `words` field. The runner does not write them. |
| Streaming | No for Parakeet TDT v3. sherpa-onnx runs it only as an offline recognizer, so live text would need VAD segments or repeated decodes. sherpa-onnx has true streaming models (Zipformer, and English-only Parakeet "unified" streaming exports), but not for v3 or Ultra. |
| Russian | Yes, through the v3 and Ultra models. |
| Ultra | Not published by k2-fsa. Third-party int8 exports exist. The runner uses leogaudin's, which documents its recipe in `export_ultra.py`. |
| Swift integration | Link the static C library from the GitHub release (or build it with the repository's `build-macos.sh`), and call the C API through the Swift wrapper in `swift-api-examples/SherpaOnnx.swift`. ONNX Runtime adds about 29 MB (the size of `libonnxruntime.dylib` in the wheel). No network at run time. |
| Rust integration | The official crates `sherpa-onnx` and `sherpa-onnx-sys` (1.13.8 is on crates.io). The `build.rs` of `sherpa-onnx-sys` downloads prebuilt libraries from the GitHub release at build time unless `SHERPA_ONNX_LIB_DIR` points at a local copy, so a reproducible build should set it. One crate would serve `apps/desktop` (Windows, Linux) and `apps/cli` (Linux server). |

## 2. parakeet-mlx

| | |
|---|---|
| Version | parakeet-mlx 0.5.3 from PyPI (released 1 October 2026, commit `2d9748c04aca31405274a13c20ef9b62f1a73351` of [senstella/parakeet-mlx](https://github.com/senstella/parakeet-mlx)), MLX 0.32.4 (14 October 2026) |
| Installed at | `$SPIKE/parakeet-mlx/venv` (545 MB, Python 3.13.3, includes librosa, numba and scipy), models in `$SPIKE/parakeet-mlx/models/{v3,ultra}` |
| Model v3 | [mlx-community/parakeet-tdt-0.6b-v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3) at `ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15`. `model.safetensors` 2,508,288,736 bytes, `05e01c7f396c298cf7d23f61da7b504adeab698f0aaeafd9c82d198625464592`, float32. `config.json` 244,093 bytes. The weights are cast to bfloat16 at load by default, as parakeet-mlx does. |
| Model Ultra | Converted here from the official [moondream/parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra) at `73175eb7aeb0d82f1e2a6b53b3aabc10a90bcd0b` (`model.safetensors` 1,255,353,386 bytes, `c9608f36d0ab956c14bfcc525479b0746b3b42a56f6949ec85c14eb7466717dc`) by `runners/convert_ultra_to_mlx.py` into `model.safetensors` (1,254,905,762 bytes, `2da4de593714f2db020312255d3a366997528e6b0a30756c911bf966eb092e32`) and v3's `config.json`. The source folder was deleted after the conversion to save disk, and the fetch command for it is in the Ultra section. |
| License | parakeet-mlx Apache-2.0, MLX MIT, models CC-BY-4.0 |
| Platforms | macOS on Apple silicon only in practice. MLX also has Linux builds for CPU and CUDA, but parakeet-mlx is not tested there, and there is no Windows build and no Intel Mac support. |
| Accelerator | Apple GPU through Metal |
| Word timestamps | Yes. The result has sentences and tokens with `start`, `duration` and `confidence`. |
| Streaming | Yes, approximately. `transcribe_stream()` switches the encoder to local attention with a rotating cache, which is a different computation from the offline model, so its accuracy has to be measured separately. |
| Russian | Yes, through the v3 and Ultra models. |
| Ultra | Convertible. Moondream publishes Ultra in the transformers layout, and the conversion is a rename plus a transpose of the convolution weights (details in the Ultra section). Third-party MLX conversions also exist, e.g. selcukkubur/parakeet-ultra-mlx and beshkenadze/parakeet-ultra-mlx-fp16, but they were not used. |
| Swift integration | No direct path. parakeet-mlx is 3,001 lines of Python. It would have to be ported to Apple's mlx-swift. FluidInference/swift-parakeet-mlx is such a port, last changed in July 2025 for Parakeet v2. The app would also have to ship MLX's Metal library. |
| Rust integration | Not practical. The only route is the community mlx-rs bindings plus a port, and it would only cover the Mac, so Windows and Linux would still need another engine. |

The runner patches one function so that `parakeet-mlx` does not call `ffmpeg`
to decode the file. It hands the library the float32 samples it read itself,
which is what the library's own loader returns. It also reads the model from the
local folder without `huggingface_hub`, so the hub is never contacted, and it
evaluates the weights before stopping the load clock, because MLX loads lazily.
Without `--chunk`, the whole file is one pass with full attention, which is the
library's default for `transcribe()`. The parakeet-mlx command line tool uses
120 s chunks instead.

## 3. FluidAudio

| | |
|---|---|
| Version | FluidAudio 0.17.7 (released 8 October 2026), commit `503b4bd1bbf7220882de39fe8ae6716aae4132da`, shallow clone at `$SPIKE/fluidaudio/src` (22 MB), built with Swift 6.4 into `$SPIKE/fluidaudio/build` (446 MB; the runner binary is 10 MB) |
| Runner | `runners/fluidaudio-swift`, a Swift package that uses the local clone as a path dependency with FluidAudio's `NemoTextProcessing` trait turned off, so the prebuilt text normalization binary is not downloaded. SwiftPM would otherwise clone the full 300 MB repository into its shared cache. |
| Model v3 | [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) at `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`. Only the files FluidAudio 0.17.7 loads for v3 were fetched, 483,110,405 bytes in 23 files. `Encoder.mlmodelc/weights/weight.bin` `e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421` (445,187,200 bytes, the 6-bit palettized encoder FluidAudio uses by default), `Decoder.mlmodelc` `48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41`, `JointDecisionv3.mlmodelc` `4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e`, `Preprocessor.mlmodelc` `129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea`, `parakeet_vocab.json` `7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735`. FluidAudio also offers an int8 rebuild of this encoder (`Encoder_v2.mlmodelc`, 594 MB, written to fix token corruption in FluidAudio issue #760), which was not fetched. |
| Model Ultra | [FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml) at `95eaa59a39d4394f047a4dc5cce480388a60d1b6`, 632,318,254 bytes in 22 files. `Encoder.mlmodelc/weights/weight.bin` `315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b` (594,211,328 bytes, int8 per channel), `Decoder.mlmodelc` `02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4`, `JointDecisionv3.mlmodelc` `3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25`, with the v3 preprocessor and vocabulary. |
| License | FluidAudio Apache-2.0, models CC-BY-4.0 |
| Platforms | macOS 14 and later, and iOS 17 and later. Apple silicon uses the Neural Engine. Intel Macs could only run Core ML on the CPU or GPU, which was not tried. No Linux or Windows. |
| Accelerator | Neural Engine by default for the encoder, decoder and joint, with the preprocessor on the CPU. `--units gpu` moves the encoder to the GPU, which FluidAudio documents as about 8% faster end to end on Apple silicon. |
| Window | The Core ML encoder has a fixed 15 s input (`mel [1,128,1501]`). Longer audio is cut into overlapping 15 s windows and merged. transcribe.cpp sees up to 30 s in one pass. |
| Word timestamps | Token timings with start, end and confidence (`ASRResult.tokenTimings`). |
| Streaming | `SlidingWindowAsrManager` gives live text from repeated 15 s windows of v3 or Ultra. FluidAudio's streaming models (the Parakeet EOU and Nemotron code under `ASR/Parakeet/Streaming`) are other models, not v3 or Ultra. |
| Russian | Yes, through the v3 and Ultra models. |
| Ultra | Official. FluidAudio 0.17.7 has `AsrModelVersion.ultra`, and FluidInference publishes the Core ML conversion. |
| Swift integration | A SwiftPM dependency. OpenRamble used FluidAudio until August 2026 (see `research/asr-performance-2026-08`). The runner loads models with `AsrModels.loadLocal(from:version:)`, which reads a folder and never downloads. The library still contains Hugging Face download code (`Shared/Download/HFClient.swift`, `Shared/AssetDownloader.swift`, `ModelRegistry.swift`), which matters for OpenRamble's filename-based network check. |
| Rust integration | None. Core ML exists only on Apple platforms. |

## Parakeet Ultra and Russian

Every candidate can run Ultra, and Russian worked in every configuration.

| Runtime | Ultra source | Status |
|---|---|---|
| transcribe.cpp (today) | handy-computer/parakeet-ultra-gguf | shipping |
| sherpa-onnx | leogaudin/sherpa-onnx-nemo-parakeet-ultra-int8, third party | runs here |
| parakeet-mlx | converted here from moondream/parakeet-ultra | runs here |
| FluidAudio | FluidInference/parakeet-ultra-coreml, official | runs here |

Moondream publishes Ultra only in the transformers layout (`ParakeetForTDT`,
mostly float16, 729 tensors). It has the same architecture as v3 and the same
8,192 tokens in the same order.

- **sherpa-onnx.** k2-fsa exports Parakeet from NVIDIA's `.nemo` file with
  NeMo. leogaudin restored the v3 `.nemo`, renamed Ultra's tensors into NeMo's
  names, and exported and quantized them with sherpa-onnx's own script. Two
  other people published int8 exports with byte-identical decoder and joiner
  files (tpmaerk/parakeet-ultra-sherpa-onnx-int8 and
  Alexqwqw/parakeet-ultra-sherpa-onnx-int8), and leogaudin reports that the
  encoder graph and weights match an independent export. Making our own export
  needs PyTorch and NeMo, several GB that were not installed.
- **parakeet-mlx.** `runners/convert_ultra_to_mlx.py` renames Ultra's tensors
  to the names in mlx-community's v3 conversion, moves the convolution weights
  to MLX's channels-last layout, and adds the two LSTM bias vectors, because
  MLX's LSTM has one bias. It drops BatchNorm's counters and Moondream's six
  `vad_head` tensors, which transcription does not use. It refuses to write
  unless the result has exactly v3's 697 tensor names and shapes and Ultra's
  vocabulary equals v3's. Values are copied unchanged. Ultra's weights are
  float16, so `--dtype float16` keeps them exactly, while the default bfloat16
  rounds them. To repeat the conversion:

  ```bash
  python3 -I $R/hf_fetch.py moondream/parakeet-ultra 73175eb7aeb0d82f1e2a6b53b3aabc10a90bcd0b \
    $SPIKE/parakeet-mlx/models/ultra-source model.safetensors tokenizer.json config.json
  $SPIKE/parakeet-mlx/venv/bin/python -I $R/runners/convert_ultra_to_mlx.py
  ```
- **FluidAudio.** FluidInference converted Ultra itself, with an int8 encoder.

## A lean Parakeet-only engine

This section estimates what it would take to own the engine instead of
switching runtimes. It is based on reading the transcribe.cpp 0.4.1 source in
`~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/transcribe-cpp-sys-0.4.1/`,
OpenRamble's Swift adapter (`Packages/LocalASR/Sources/LocalASR/TranscribeCppAdapter.swift`)
and `core/ramble-engine`. Lines are non-blank lines, counted with
`grep -cv '^[[:space:]]*$'`, and comments count. For parts of files, the
ranges run from a function's signature to its closing brace.

OpenRamble uses a small part of transcribe.cpp. The Swift adapter calls 22 C
functions, which load the GGUF, open a session, run one clip or a batch of up
to 8 clips, set an abort callback, and read the text and timed words. The Rust
engine makes the same kinds of calls through the `transcribe-cpp` crate.
Neither passes a language or streams, and both cut audio into pieces of at
most 30 s themselves. The shipped Ultra GGUF holds 703 tensors (194 Q4_K for
the encoder's linear layers, 31 Q8_0 for attention output and the decoder, 48
F16 for the pointwise convolutions, and 430 F32), for 24 layers of width 1024
with 8 heads, convolution kernel 9, TDT durations 0 to 4 and full attention.

### Lines a Parakeet-only engine needs

transcribe.cpp layer, with paths under `src/`:

| Component | Where | Lines |
|---|---|---:|
| FastConformer encoder wiring, offline graph | `arch/parakeet/encoder.cpp` 1 to 145 and 314 to 750 | 537 |
| Convolution subsampling (8 times) | `conformer/conformer.cpp` 1123 to the end | 239 |
| Conformer block, relative position attention, convolution module | the rest of `conformer.cpp`, without windowed attention (652 to 794) | 889 |
| Conformer header | `conformer/conformer.h` | 429 |
| TDT prediction network (LSTM) and joint | `arch/parakeet/decoder.cpp` 1 to 1017 | 911 |
| Greedy TDT loop | `decoder.cpp` 1018 to 1227 | 186 |
| Token, word and timestamp assembly | `arch/parakeet/model.cpp` 854 to 1033 | 166 |
| Text cleanup, length masks, decode glue | `model.cpp` 646 to 853 | 198 |
| Detokenization (SentencePiece decode, vocabulary load) | parts of `transcribe-tokenizer.cpp` and its header | 650 |
| Load, BatchNorm fusion, F16 to F32 on the CPU | `model.cpp` 1 to 291 and 392 to 645 | 485 |
| Single and batch run | `model.cpp` 1034 to 1451 and 1761 to 2162 | 756 |
| Hyperparameters and tensor list | `arch/parakeet/weights.cpp`, `weights.h` | 1,407 |
| Parakeet headers and capabilities | `parakeet.h`, `decoder.h`, `encoder.h`, `capabilities.cpp` | 981 |
| Mel front end, without other models' modes | `transcribe-mel.cpp` and header | 793 |
| GGUF and model loading, metadata | `transcribe-loader`, `-load-common`, `-meta`, `-mmap`, `-model`, `-weights-util`, `-arch` | 2,740 |
| Backend selection | `transcribe-backend`, `-flash-policy`, `-env` | 402 |
| Batch packing and thread helpers | `transcribe-batch-util` | 607 |
| Long audio | none, because OpenRamble cuts audio at 30 s | 0 |
| Public C API as it is today | `transcribe.cpp`, the used part of `transcribe-asr.cpp`, internal headers, `include/transcribe.h` | 5,745 |
| **Total** | | **18,121** |

`include/transcribe.h` (2,673 lines) is mostly documentation for the whole
API. A header with only the 22 functions OpenRamble uses would bring the layer
to about 15,500 lines.

ggml parts that the Parakeet path uses:

| Part | Whole files | After trimming inside files |
|---|---:|---:|
| Core (graph, allocator, backend scheduler, GGUF, quantization formats) | 23,495 | 18,967 |
| CPU, shared code (`ggml-cpu.c`, `ops.cpp`, vector code, repacking, llamafile sgemm) | 28,787 | `ops.cpp` falls from 10,033 to about 2,970 |
| CPU, ARM NEON kernels | 8,296 | `quants.c` 3,483 to 703, `repack.cpp` 4,778 to 1,250 |
| CPU, x86 AVX2 kernels | 8,624 | `quants.c` 3,342 to 271, `repack.cpp` 4,986 to 1,638 |
| Metal host code | 14,892 | `ggml-metal-ops.cpp` 4,818 to about 2,346 |
| Metal shaders | 9,305 | not trimmed |
| **Total** | **93,399** | **about 65,600** |

The ggml operations the Parakeet graph uses are mul_mat, add, mul,
cpy/cont/cast, concat, fill, scale, norm, soft_max_ext, flash_attn_ext,
im2col, conv_2d_dw, conv_2d, pad_ext, get_rows, relu, sigmoid, silu and tanh.

For comparison, transcribe.cpp 0.4.1 has 100,131 lines in `src/` (8,011 of
them vendored miniz) and 3,537 in `include/`, and its `ggml/` has 434,891 lines
with all backends.

### What could be dropped

| Dropped | Lines |
|---|---:|
| 17 other architectures (whisper 6,592, granite 4,725, voxtral_realtime 4,466, moonshine_streaming 4,435, canary 3,781, qwen3_asr 3,748, cohere 3,743, moss 3,224, voxtral 3,212, moonshine 3,178, funasr_nano 3,001, canary_qwen 2,913, granite_nar 2,791, gigaam 2,587, medasr 2,074, granite5_ctc 1,959, sensevoice 1,689) | 58,118 |
| Diarization (sortformer, ecapa_tdnn, glue and headers) | 3,630 |
| Voice activity detection (silero_vad and `transcribe-vad`) | 1,881 |
| Language identification and Kaldi filterbank | 888 |
| Shared code of other model families (causal_lm, sanm, granite_conformer, prompting, repetition guard) | 2,341 |
| Tokenizer encoders and byte-level decoders, Unicode tables, Whisper `.bin` loader, tensor debug dumps | 5,092 |
| miniz, used only for Whisper's compression check | 8,011 |
| Parakeet streaming (model, encoder, RNNT and CTC decoders) | 2,409 |
| Parakeet long-form segmenter, its VAD head, multitalker and encoder debug hooks | 1,400 |
| Other models' mel modes, windowed attention, streaming and unused API code, extension headers | 1,777 |
| ggml backends OpenRamble never builds (OpenCL, SYCL, Vulkan, Hexagon, CUDA, ET, WebGPU, OpenVINO, CANN, virtgpu, RPC, zDNN, ZenDNN, BLAS, MUSA) | 301,388 |
| ggml CPU code for other processors and extensions (spacemit, loongarch, powerpc, riscv, s390, wasm, kleidiai, amx, tiled, hbm) | 33,566 |
| ggml core extras (backend-meta, opt, backend-dl, other backends' headers) | 3,859 |
| Metal shaders for unused operations and quantization types | 2,679 |

Deleting the backend folders only makes the source tree smaller, because
OpenRamble's build already leaves them out. The parts that reach the binary
today are the other 17 architectures, the auxiliary models, and every ggml
operation and Metal kernel, because ggml's operation switch
(`ggml-cpu.c:1787`) and the embedded Metal library reference all of them.

### Hard parts of the Parakeet path

- **Relative position attention runs inside flash attention.** The position
  bias is shifted with a strided view (`conformer.cpp:826`), scaled, cast to
  F16 and passed as the flash attention mask one head at a time
  (`conformer.cpp:843` to `859`), and K and V are cast to F16 for quantized
  models (`conformer.cpp:925`). A rewrite has to reproduce that F16 rounding.
- **Subsampling and length masks.** Three stride-2 convolutions give the
  8 times reduction (`conformer.cpp:1151`). Metal uses im2col for the
  depthwise convolution and the CPU uses a direct convolution
  (`encoder.cpp:63`). Ultra's length masking applies at every stage
  (`encoder.cpp:328` to `333`, `model.cpp:711`, `model.cpp:1481`).
- **Load-time rewrites change numerics.** BatchNorm is folded into a scale and
  shift (`model.cpp:208`), F16 pointwise weights become F32 on the CPU
  (`model.cpp:266`), and the decoder's Q8_0 weights are expanded to F32
  (`decoder.cpp:116`).
- **Matrix multiplication differs by backend.** The CPU quantizes activations
  on the fly (Q8_K for Q4_K weights, Q8_0 for Q8_0 weights), repacks weights
  into interleaved tiles (`repack.cpp:3573` and `:3825`, on by default at
  `ggml/CMakeLists.txt:152`) and uses llamafile sgemm (`CMakeLists.txt:297`).
  Metal converts both operands to half precision and accumulates in float
  (`mul_mm.metal:851` to `866`), and it switches to a tensor API kernel on
  chips that support it (`ggml-metal-device.m:460` and `:526`). So identical
  output can only be defined per backend, and on the Mac per GPU generation.
- **The decoder is simple.** It is greedy only, with no beam search
  (`decoder.cpp:1018`). Ultra uses a global symbol budget (`:1101`), caching
  of blank steps (`:1098`) and a confidence softmax per emitted token
  (`:981`). Each step runs as tiny ggml CPU graphs, and with two or more
  threads every graph node waits at a spin barrier, which is why OpenRamble
  uses one decoder thread (`TranscribeCppAdapter.swift:108`).
- **The mel front end already differs between platforms.** It uses NeMo's
  constants (`transcribe-mel.cpp:1` to `24`), a float64 FFT through vDSP on
  the Mac (`:633`) and a hand-written radix-2 FFT elsewhere (`:239`), and
  `cblas_sgemm` for the mel filterbank (`:671`). Mac and Linux features
  therefore already differ in the last bits.
- **Long audio needs no engine code.** The GGUF sets `max_segment_seconds` to
  30.0, and the long-form path runs only above that (`longform.cpp:107`,
  `model.cpp:1750`), so with OpenRamble's own 30 s cut the whole VAD head path
  is unused.

### Effort

The estimates assume one experienced C and C++ engineer, the existing test
corpus and reference transcripts, and transcribe.cpp's tensor dump hooks for
comparing layer by layer.

**(a) A Parakeet-only fork of transcribe.cpp that keeps ggml with CPU and
Metal, the same GGUF files and identical transcripts takes about 2 to 4
person-weeks.**

- About one week goes to deleting the other architectures, their registry
  entries (`transcribe-arch.cpp:106`), the CMake source list, the streaming,
  long-form, multitalker, VAD, language identification and diarization entry
  points, and the unused backend folders. The compiler guides that work.
- About one week goes to proving identical transcripts on Metal, Intel Mac
  CPU, Linux and Windows.
- One or two optional weeks go to trimming inside files (`ops.cpp`, Metal
  operations, shaders). That saves little binary size.
- Keeping up with upstream costs about half a day to one day per release plus
  verification if the fork only deletes whole files and folders, because the
  merge conflicts are then only files deleted on our side. Trimming inside
  ggml files turns every sync into conflicts and costs 2 to 5 days each, so
  the coarse fork is the one to keep.

**(b) A new plain C engine without ggml takes about 9 to 14 person-weeks for
the CPU only, and 14 to 22 with a Metal path.**

- The GGUF reader and the mel front end take about one week.
- Tensor operations (layer norm, GLU, depthwise convolution, subsampling,
  relative position attention) take about two weeks.
- Quantized matrix multiplication takes two to three weeks, for Q4_K times
  Q8_K and Q8_0 kernels on NEON and AVX2, an F32 GEMM, and threading.
- The TDT decoder, words, API and batching take about two weeks.
- Debugging differences against transcribe.cpp takes two to three weeks.
- Build and CI take about one week, and Metal adds five to eight weeks.

Fast quantized matrix multiplication and numerical parity dominate the cost,
and Metal comes after them. A close match is realistic, because the int8 block
dot products are exact integers, and the differences come from the order of
float accumulation, F16 rounding in attention, and softmax. The expected
outcome is identical text on most utterances and a small tail of one-word
differences, so the acceptance test should be WER rather than identical
bytes. Without heavy kernel work, such an engine would likely run at 0.3 to
0.6 times ggml's CPU throughput, because ggml's repacked tiles and llamafile
sgemm are hard to match. That figure is an estimate and was not measured.
Without Metal, long clips on a Mac would be several times slower than today,
and short dictation clips would lose less.

Counting commands, for reproducing the numbers:

```bash
# one file
grep -cv '^[[:space:]]*$' FILE
# a line range of a file
awk -v a=START -v b=END 'NR>=a && NR<=b && $0 !~ /^[[:space:]]*$/ {n++} END{print n}' FILE
# a tree
find DIR -type f \( -name '*.c' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' -o -name '*.m' \
  -o -name '*.metal' -o -name '*.cu' -o -name '*.cuh' -o -name '*.comp' -o -name '*.glsl' -o -name '*.cl' \
  -o -name '*.wgsl' -o -name '*.tmpl' -o -name '*.S' \) -exec grep -cv '^[[:space:]]*$' {} + \
  | awk -F: '{s+=$NF} END{print s}'
```

The tensor types were read from the GGUF header of the app's installed model
(`~/Library/Application Support/OpenRamble/Models/parakeet-ultra-gguf/.../parakeet-ultra-Q4_K_M.gguf`)
with a read-only parser.

## Disk use

The spike uses 9.3 GB under `$SPIKE` plus 1.2 GB of Core ML compile cache.
Free space on the disk fell from 33 GB to 14 GB during the session, and the
part of that drop not listed here came from other processes.

| What | Where | Size on disk |
|---|---|---:|
| sherpa-onnx venv | `$SPIKE/sherpa-onnx/venv` | 61 MB |
| sherpa-onnx v3 int8 | `$SPIKE/sherpa-onnx/models/v3-int8` | 642 MB |
| sherpa-onnx v3 fp32 | `$SPIKE/sherpa-onnx/models/v3-fp32` | 2.39 GB |
| sherpa-onnx Ultra int8 | `$SPIKE/sherpa-onnx/models/ultra-int8` | 640 MB |
| parakeet-mlx venv | `$SPIKE/parakeet-mlx/venv` | 545 MB |
| parakeet-mlx v3 (float32) | `$SPIKE/parakeet-mlx/models/v3` | 2.35 GB |
| parakeet-mlx Ultra (converted) | `$SPIKE/parakeet-mlx/models/ultra` | 1.18 GB |
| FluidAudio source | `$SPIKE/fluidaudio/src` | 22 MB |
| FluidAudio build | `$SPIKE/fluidaudio/build` | 446 MB |
| FluidAudio v3 | `$SPIKE/fluidaudio/models/v3` | 461 MB |
| FluidAudio Ultra | `$SPIKE/fluidaudio/models/ultra` | 605 MB |
| Core ML compile cache, made by macOS | `~/Library/Caches/fluidaudio-runner` | 1.2 GB |

The exact download size of each model is in its candidate section and in
`models.sha256`. The largest single download was the fp32 sherpa-onnx model at
2.55 GB, so nothing over 3 GB was fetched. Moondream's Ultra checkpoint
(1.26 GB) was deleted after the conversion. The virtual
environments were installed from PyPI with uv's cache turned off, so their
installed sizes in the table are all they use.

## What did not work or was left out

- **sherpa-onnx with Core ML.** The provider works but was slower than the
  CPU, for the reasons in the sherpa-onnx section. Measuring it is still
  possible with `--provider coreml`, but a fair result needs a sherpa-onnx
  build with MLProgram flags.
- **Our own sherpa-onnx export of Ultra.** It needs NeMo and PyTorch, so the
  runner uses leogaudin's third-party export instead.
- **FluidAudio's int8 v3 encoder** (`Encoder_v2.mlmodelc`, 594 MB) and its
  4-bit encoder were not fetched, to save disk. The v3 runs use FluidAudio's
  default 6-bit encoder.
- **True cold start for FluidAudio.** Each model has been compiled once for
  the Neural Engine, so later loads come from the cache. Delete
  `~/Library/Caches/fluidaudio-runner` to measure the 12 to 17 s first load
  again.
- **Memory of Neural Engine models.** `/usr/bin/time -l` does not see it, as
  described in the runner contract.
- **First runner builds.** The FluidAudio runner failed to build three times
  because of mistakes in the runner (a package name that clashed with
  FluidAudio's, and two Swift type errors), and the first parakeet-mlx run
  failed because the audio shim returned bfloat16 samples, which
  parakeet-mlx's mel code does not accept. Both runners are fixed, and the smoke results above come from the
  fixed versions.
- **No Linux or Windows runs.** sherpa-onnx is the only candidate with Linux
  and Windows builds, and it was run only on this Mac.
