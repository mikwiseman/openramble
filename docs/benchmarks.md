# Benchmark methodology

The `asr-bench` executable measures a pinned local recognition pipeline. These
benchmarks are development evidence, not an application release gate.

## Build and install models

```bash
swift build --package-path Packages/LocalASR -c release --product asr-bench
./Packages/LocalASR/.build/release/asr-bench install
./Packages/LocalASR/.build/release/asr-bench install-vocab
```

## Run a fixture

```bash
./Packages/LocalASR/.build/release/asr-bench transcribe path/to/audio.wav
```

The scorer reports word error rate, character error rate, punctuation errors,
and explicit insertions, deletions, and substitutions. Case is folded, the two
common written forms of the Russian yo/ye sound are treated as equivalent, and
spoken numerals are normalized before comparison. Punctuation is scored
separately rather than silently discarded.

Use only consented audio. Keep voice files outside Git and freeze reference
transcripts before comparing pipeline variants. Record the model revisions,
dependency commits, command-line options, fixture checksum, and source commit
for every published result.

Synthetic fixtures are useful for reproducibility but do not establish quality
on live speech. Do not present synthetic scores as human-speech measurements.
