# Polish loop, November 2026

Mik's request on 19 November 2026: improve design, speed and accuracy in a
loop until a round stops finding improvements. Each entry below records what
was measured, the hypothesis, the result and the decision. Negative results
stay.

Raw outputs are outside the repository, in `~/.openramble/polish-loop/`
(`probe/` holds the timing and comparison tools, `parity/` their outputs,
`fleurs/` the public FLEURS English and Russian test sets).

## Baseline, 19 November 2026

**Speed, from real use.** The installed app's own journal
(`SupportLogs/events-*.jsonl`, 0.40.0, 13 to 19 November, 323 completed
dictations on an M4 Pro):

| | p50 | p90 | p95 | p99 | max |
|---|---|---|---|---|---|
| key-up to finished, ms | 181 | 391 | 502 | 651 | 1,703 |
| engine after key-up, ms | 159 | 368 | 454 | 626 | 1,640 |
| take length, s | 9.3 | 32.2 | 43.7 | 112.6 | 188.4 |

- The wait is the engine: a least-squares fit over the 305 takes of 1 to 60 s
  recognized whole gives 67 ms + 9.7 ms per second of audio. Everything after
  the engine is 23 ms at the median, and the paste is sent 9 ms later.
- How long the engine had been idle before the key went down does not move the
  fit (residual medians between −4 and +4 ms from 0 s to an hour).
- Pieces recognized while speaking are rare: 11 of the 72 takes of 20 s or
  longer had any. The kept takes show why: quiet blocks are 20 to 35% of a
  take, but in runs of 90 to 270 ms, shorter than the 700 ms the segmenter
  asks for (350 ms after half a minute).
- Large disk reads (300 MB and more, the model loading at key-down) happen in
  32 takes and cost nothing after key-up: their median wait is 172 ms.

**Speed, in a quiet process.** `probe/probe.c` against the shipped runtime
(fork v0.4.1-c4cd60da, Parakeet Ultra Q4_K_M, Metal, one thread), best of nine:

| clip, s | whole run, ms | encoder | decoder |
|---|---|---|---|
| 1 | 25 | 16 | 7 |
| 4 | 64 | 40 | 24 |
| 8 | 110 | 64 | 45 |
| 15.8 | 213 | 117 | 89 |

A run that follows 0.25 s or more of idleness costs about 20 ms more than a
run that follows another at once (67 ms against 84 to 91 ms for a 4 s clip),
split between the encoder and the decoder.

**Accuracy.** FLEURS test, first 200 clips of each language, shipped runtime,
lower-cased and stripped of punctuation only (numbers written as digits count
as errors): English 203 of 4,238 words (4.79%), Russian 190 of 3,791 (5.01%).
The app's own file check: 15 word errors in 455 for the whole-file reference.

**Design.** A screenshot of every window and take panel state, in both
appearances (`~/.openramble/gallery/`). No layout defects found. Two details
were off in Settings; see D1.

## S1. The decoder's steps on Accelerate

Hypothesis. A greedy step is four matrix-vector products through the
predictor and two through the joint, all with one column. ggml's `mul_mat`
has no fast path for that shape, so a step costs 0.77 ms; `cblas_sgemv` on the
same fp32 weights does the same arithmetic in 0.28 ms (`probe/gemv.c`:
predictor 168 µs against 383 µs in plain NEON, joint 113 µs against 333 µs).
Half-precision weights were also tried in that probe and help far less
(318 µs and 279 µs), so the cost is arithmetic, not memory traffic.

Change. transcribe.cpp fork, branch `openramble/decoder-accelerate`, commit
`3842d658` on top of `c4cd60da`: on Apple the three greedy decoders step
through `cblas_sgemv` and `cblas_sgemm` on the resident weights, with the
graphs' own order of operations and the graphs kept for every other platform
and for any weight that is not host memory.

Result, same probe, shipped against patched:

| clip, s | whole run, ms | decoder, ms |
|---|---|---|
| 1 | 25 → 20 | 6.8 → 3.2 |
| 4 | 64 → 53 | 24 → 10 |
| 8 | 110 → 89 | 45 → 23 |
| 15.8 | 213 → 159 | 89 → 43 |

In the app's own pipeline (`DictationLatencyTests`, real model, three runs
each, the Mac under other load): recognition 69–73 → 61–64 ms for a 4.3 s
phrase, 471–489 → 370–389 ms for 36.8 s, 2.35–2.40 → 1.81–1.85 s for three
minutes.

Same words. `probe/dump.c` prints text, token ids, token times and token
confidence for each clip from each build:

| set | clips | different text | different tokens or times |
|---|---|---|---|
| FLEURS English, Ultra | 200 | 0 | 0 |
| FLEURS Russian, Ultra | 200 | 0 | 0 |
| English clips cut at awkward end points (`lang-bug`), Ultra | 402 | 0 | 0 |
| FLEURS Hebrew, Ultra | 108 | 0 | 0 |
| FLEURS Hebrew, the Hebrew model | 108 | 0 | 0 |

Token confidence differs by at most 1e-6. Word error rate is the same number
on both builds. `swift test` for `Packages/LocalASR` with the real model
passes on the patched build (194 tests and the 22 end-to-end ones), with the
file-quality counts unchanged.

Against the rule the October research set for a decoder change (H8: at least
30% off the decoder, at least 97% of FLEURS transcripts identical): about 50%
off, 100% identical on the sets above.

Decision. Adopt. Not shipped: it needs a new release of the fork and the two
pins (`Packages/LocalASR/Package.swift`, `core/ramble-engine/Cargo.toml`),
which is Mik's call. The audited package is built
(`scripts/build-transcribe-xcframework.sh`, checksum
`b81fea70b7ff13de99888b015b9ffaa92f9609c14ba66145a8ab22edd6480b97`).

## D1. Two details in Settings

The microphone's chevron sat beside the first line of a two-line name; it is
now part of the text and follows the last word. The note under the shortcuts
restated their names in forty words; it now says the two things the names do
not. Checked in the gallery screenshot of the General tab. Commit `b4cb080`.

## Found, not done

- **Dictionary terms inside the decoder (October research, H4c).** Passed all
  five of its rules (English term recall 22 of 37 to 31 of 37, FLEURS word
  error rate +0.047 points, nothing invented on noise) and has waited since
  for a fork release. It belongs in the same release as S1.
- **Leftover files.** `Takes/` in the installed app's support folder holds 66
  `.openramble-delete-take-*.intent` files from August, 50 bytes each.
- **The latency gate in the release** has no allowance for a busy Mac (see
  the 0.41.0 notes).
