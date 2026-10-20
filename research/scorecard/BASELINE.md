# Baseline: OpenRamble 0.32.0 and whisper.cpp Turbo

Measured 19 and 20 October 2026 on one MacBook Pro M4 Pro (14 CPUs, 24 GB),
macOS 27.0.1, with `./scripts/scorecard.sh`. The definitions of every metric
are in [README.md](README.md); the numbers are in
[results/openramble-0.32.0.json](results/openramble-0.32.0.json) and
[results/whisper-turbo.json](results/whisper-turbo.json), and the page that
compares all candidates is [index.html](index.html).

OpenRamble 0.32.0 is the official signed release (`openramble-cli` SHA-256
`23c28d79…`) with Parakeet v3 Q8 on transcribe.cpp 0.2.3. Its warm lane is
`asr-bench` built from the 0.32.0 source commit `3c5aaf9`. whisper.cpp Turbo is
v1.9.5 with large-v3-turbo F16 and its defaults (beam 5, automatic language).

## The scorecard reproduces the October 9 study

Before anything new was measured, the scorecard was checked against the
October 9 product benchmark it continues:

- Re-scoring the retained October 9 transcripts gives exactly the published
  WER, substitutions, deletions and insertions for all three engines in both
  languages. A unit test keeps it that way.
- The regenerated FLEURS corpus matches the frozen manifest hash for hash.
- Recognizing the frozen 200 files again through the warm lane gives the same
  5.57% (English) and 5.95% (Russian) as the shipping CLI did on October 9.
- The hour composites give the same WER and deleted-word rates as on October
  9: Russian 6.49% with 1.71% deleted, English 9.76% with 4.80% deleted, and
  the alternating hour 39.07% with 33.80% deleted.

## Results

| | OpenRamble 0.32.0 | whisper.cpp Turbo |
|---|---:|---:|
| WER, FLEURS English, frozen 100 | 5.57% | 5.10% |
| WER, FLEURS Russian, frozen 100 | 5.95% | 5.15% |
| Punctuation F1, English / Russian | 84.7% / 89.6% | 84.7% / 89.7% |
| Capitalization F1, English / Russian | 93.3% / 93.1% | 93.9% / 92.8% |
| WER, six dictation takes of 33 to 129 s | 6.03% | 13.50% |
| Wrong script, Mik's 199 private English clips | 20 | 0 |
| Wrong script, 79-point boundary sweep | 17 | 0 |
| Words invented on 11 silence and noise clips | 0 | 19 |
| Hour, English: WER / deleted words | 9.76% / 4.80% | 24.05% / 4.13% |
| Hour, Russian: WER / deleted words | 6.49% / 1.71% | 6.47% / 1.52% |
| Hour, alternating Russian and English: WER | 39.07% | 64.68% |
| Hour file, English, whole process | 42.6 s | 144.6 s |
| Model file | 740 MB | 1,625 MB |

Whisper Turbo is more accurate on short read sentences in both languages. It
fails differently on longer input: on the 37-second English take it dropped 46
of the reference words, on the 129-second one it inserted 25, and its
alternating hour has 64.68% WER. On silence and noise it writes "Thank you."
and similar phrases (19 words over the 11 clips), while Parakeet writes
nothing.

Parakeet v3's distinctive failure is the wrong alphabet. On Mik's preserved
English takes it writes 20 of 199 decodes in Cyrillic, 17 of them in the
boundary sweep, where the same recording is cut at 79 points a tenth of a
second apart. That is the known v3 behavior described in
`TranscribeCppAdapter.swift`; Whisper Turbo and Parakeet Ultra
(`research/model-upgrade-2026-10/`) have no such decode.

## Speed and memory

One interleaved run on 20 October covered both baselines and the bake-off
candidates, so their numbers share the same machine state. Each timed block
started only with the Mac at least 75% idle and no other recognition process;
quiet and loaded blocks alternate in ABBA order.

| | OpenRamble 0.32.0 | whisper.cpp Turbo |
|---|---:|---:|
| Warm, short takes (under 15 s), p50 / p95 | 73 / 122 ms | not measurable |
| Warm, short takes under 14 busy CPUs, p50 / p95 | 102 / 171 ms | not measurable |
| Warm, 33 to 129 s takes decoded whole, p50 / p95 | 615 / 1,459 ms | not measurable |
| Whole process, six FLEURS files, p50 / p95 idle | 0.424 / 0.620 s | 1.666 / 2.135 s |
| Whole process under 14 busy CPUs, p50 / p95 | 0.541 / 0.735 s | 1.951 / 2.291 s |
| Model load, warm file cache | 0.22 s | — |
| Peak resident memory, warm / whole process | 1.02 / 0.95 GB | — / 2.02 GB |

Whisper has no persistent mode in its CLI, so its warm latency is not
measured; its whole-process time includes loading a 1.6 GB model each time.
The warm short-take numbers are the engine's share of a dictation: the app's
journal reports 167 ms of engine time at p50 for real takes, which include
longer ones. The long takes are decoded whole here; the app decodes long
dictations in segments while the person is still speaking, so this row is the
upper bound for a take that never pauses.

## Limits

These are one Mac's measurements of read and composite speech, not product
claims. The private clips are five takes by one speaker. Whisper Turbo ran
through its own CLI only, so it has no warm-lane latency.
