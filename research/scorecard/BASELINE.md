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

Pending. The interleaved speed run covers both baselines and all bake-off
candidates in one session, so their numbers share the same machine state. It
starts only when the Mac is at least 85% idle with no other recognition
process; on 20 October sibling builds and Spotlight indexing kept the Mac
below that, and this section is filled in when the run completes.

## Limits

These are one Mac's measurements of read and composite speech, not product
claims. The private clips are five takes by one speaker. Whisper Turbo ran
through its own CLI only, so it has no warm-lane latency.
