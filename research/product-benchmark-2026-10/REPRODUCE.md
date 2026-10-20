# Repeat the product benchmark

macOS and Apple Silicon are required for this exact protocol. Use a new work
directory for a new product/model version. The runner refuses changed hashes
in an existing run and skips existing observations on resume. Do not run
inference, builds, downloads, or other benchmarks concurrently with a timing
batch. Keep the normal desktop workload comparable. CPU workers are owned and
terminated by the runner; do not abruptly kill it while pressure is active.

## Download pinned inputs and official applications

1. Get [OpenRamble 0.32.0](https://github.com/mikwiseman/openramble/releases/tag/v0.32.0)
   and [Handy 0.9.8](https://github.com/cjpais/Handy/releases/tag/v0.9.8).
   Extract the official arm64 apps into the benchmark directory without
   replacing the user's installed apps. Do not patch either app.
2. Use the Parakeet v3 Q8 file listed in `data/protocol-v2.json`. Source:
   [handy-computer/parakeet-tdt-0.6b-v3-gguf](https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf).
   Verify the exact SHA-256 in the report. Make `Handy.app/Contents/MacOS/portable`
   before its first launch and link the model into
   `Handy.app/Contents/MacOS/Data/models/parakeet-tdt-0.6b-v3-Q8_0.gguf`.
   Defaults, auto language/GPU, no custom vocabulary or post-processing.
3. Build [official whisper.cpp](https://github.com/ggml-org/whisper.cpp/tree/v1.9.5)
   at commit `d1be6fde11ac6e0407606b4e42fe72d34add8037`:
   `cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON`, then
   `cmake --build build --config Release -j4 --target whisper-cli`.
4. Download `ggml-large-v3-turbo.bin` from
   [the official model revision](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1).
   Check SHA-256 `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`.
5. Set explicit paths below. Python 3, macOS `afconvert`, and `uv` are used.
   The scripts download pinned public FLEURS archives, check hashes, select
   fixed filenames, and convert to mono 16 kHz signed 16-bit PCM.

```sh
export BENCH_ROOT="$HOME/Library/Caches/OpenRambleProductBenchmark-next"
export OPENRAMBLE_CLI="$BENCH_ROOT/OpenRamble.app/Contents/MacOS/openramble-cli"
export HANDY_CLI="$BENCH_ROOT/Handy.app/Contents/MacOS/handy"
export PARAKEET_MODEL="$BENCH_ROOT/models/parakeet-tdt-0.6b-v3-Q8_0.gguf"
export WHISPER_CLI="$BENCH_ROOT/whisper.cpp/build/bin/whisper-cli"
export WHISPER_MODEL="$BENCH_ROOT/models/ggml-large-v3-turbo.bin"
python3 scripts/prepare-handy-benchmark.py
python3 scripts/prepare-long-mono.py
python3 scripts/run-handy-benchmark.py smoke
python3 scripts/run-handy-benchmark.py quality
python3 scripts/run-handy-benchmark.py quality --engine whisper
python3 scripts/run-handy-benchmark.py speed
python3 scripts/run-handy-benchmark.py long
python3 scripts/run-handy-benchmark.py long-mono
uv run --with jiwer==4.0.0 python scripts/score-products.py
```

Change `scripts/` to `src/` in the standalone review pack. Both copies accept
the explicit environment variables above. The separate archived executed scripts
retain the original local paths for audit. Input-path strings will change the
manifest byte hash on a different machine; compare audio/reference hashes and
ordered fixture IDs as well as retaining the new manifest itself.

Every CLI subprocess is wrapped in `/usr/bin/time -l` and the macOS network-deny
sandbox. The measured interval covers complete process startup to exit. No GUI
or microphone automation is involved. The synthetic load uses one Python busy
process per logical CPU, 14 on this machine. Six permutations balance app order;
normal and busy conditions alternate. Long files use two OH/HO pairs per condition.

`score-products.py` can also rescore retained data without running recognition:
set `BENCH_ROOT` to the directory containing `manifest.json`, `extended-long.json`,
`observations.jsonl`, and optional `superwhisper-quality.jsonl`.

## Optional Superwhisper quality pass

Use [official CLI 0.2.0](https://github.com/superultrainc/superwhisper-cli-release/releases/tag/v0.2.0)
and installed app 2.19.2. Select local Whisper Turbo, language Auto, no AI model,
translation, realtime, or literal punctuation. Keep the app running and do not
record unrelated audio during the batch. The script checks each result's model,
version, duration and disabled rewrite/translation before accepting it. It
fails on multiple new recording folders to avoid attributing personal speech.

Put the executable at `$BENCH_ROOT/superwhisper-cli-0.2.0/superwhisper`. Set
`SUPERWHISPER_RECORDINGS` only if its recordings directory differs from
`$HOME/superwhisper/recordings`, then run `python3 scripts/run-superwhisper.py`.
This exact experiment pins app version 2.19.2; change the check deliberately for
a new version and report it. Restore the user's original app mode afterward.

[CLI docs](https://superwhisper.com/docs/get-started/cli) and
[file-transcription docs](https://superwhisper.com/docs/get-started/transcribe-files).
Its `processingTime` excludes a different set of operations, so it is not added
to the complete-process timing chart.

## Attribution and limitations

Speech/reference source: [Google FLEURS](https://huggingface.co/datasets/google/fleurs),
revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd`, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/),
English and Russian test splits. Derived material: 16 kHz PCM conversion,
SHA-selected subsets and concatenated stress fixtures. Reference transcripts
are unchanged in the manifest; normalization happens only during scoring.

These read-speech files are not a representative microphone/hotkey, spontaneous
code-switching, real meeting, noise, punctuation, diarization, or insertion test.
The broader existing model corpus covers more conditions, but is kept separate.
Do not label CLI results as end-to-end dictation latency. Do not drop failed
runs, report failure times as speed, or quote long-file speed without its WER.

Archived figures: `uv run --with matplotlib python scripts/plot.py`. This renderer has pinned 9 October version captions; update them explicitly when publishing a new experiment.
