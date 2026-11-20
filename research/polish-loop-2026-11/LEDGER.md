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

## S1, on all 1,422 FLEURS clips

The comparison above, repeated on every English and Russian test utterance,
the size October's decoder gate (H8) used:

| set | clips | different text | different tokens or times | tokens | word errors, both builds |
|---|---|---|---|---|---|
| English | 647 | 0 | 0 | 29,770 | 735 of 14,481 (5.08%) |
| Russian | 775 | 0 | 0 | 46,140 | 735 of 15,105 (4.87%) |

## A1. Taught words inside the decoder (October's H4c), on the current model

Hypothesis. October's phrase boosting passed its gate on Parakeet v3 and was
never released. It should hold on Parakeet Ultra, and it should sit on top of
S1 unchanged, because it only re-ranks the logits a step produced.

Change. The four commits of `openramble/v0.4.0-phrase-boosting` cherry-pick
cleanly onto S1 (branch `openramble/v0.4.1-next`, tip `dacdba09`). In the app,
`AppState` hands the written forms of the person's own dictionary entries to
both recognizers at launch and on every change; the starter set and entries
marked `noAcousticBoost` are left out, as October designed it.

Result, Parakeet Ultra Q4_K_M, default weight 8.0, the 70 synthetic sentences
of `research/term-biasing-2026-10/corpus.json` read by the same macOS voices,
with all 60 terms of its `vocabulary.txt` active:

| | without | with |
|---|---|---|
| English terms found, test half | 23 of 37 | 32 of 37 |
| English terms found, dev half | 26 of 41 | 33 of 41 |
| Russian terms found, test half | 1 of 34 | 1 of 34 |
| FLEURS English, first 200, word errors | 203 (4.79%) | 206 (4.86%) |
| FLEURS Russian, first 200, word errors | 190 (5.01%) | 190 (5.01%) |
| decoder time for the 70 sentences | 681 ms | 688 ms |

With no terms the build is identical to S1 on all 400 FLEURS clips (text,
tokens, times). The four English transcripts that changed with 60 terms moved
toward a term: "Sintra" to "Sentry" twice, "Giza" to "Ghost", "Festicella" to
"Figicella". A person's own dictionary is a handful of words, not sixty.

Through the app's own recognizer (`TaughtWordsEndToEndTests`, real model, the
boosted build): "…built with Tori…" without the word, "…built with Tauri…"
with it, and "Tori" again once it is removed. The whole `Packages/LocalASR`
suite passes on that build, file-quality counts unchanged.

Not helped: Russian speech that says English terms the Russian way. The model
writes them in Cyrillic and never begins the Latin spelling, so there is
nothing to complete. The text dictionary stays the tool there.

Decision. Adopt with S1 in one fork release. The wiring and its unit tests
are on the branch and change nothing on the shipped runtime; the real-model
test lands with the pin.

## A2. Upstream 0.4.2's mel fix (negative)

Hypothesis. Upstream 0.4.2 drops a padding mel frame that leaked into the
encoder "whenever floor(n/hop) is a multiple of 8", for checkpoints that do
not mask it in the graph. Ultra masks it; the Hebrew model does not, so
Hebrew might gain.

Result. Built 0.4.2 with our two changes (`openramble/v0.4.2-next`,
`16a6dd8d`). Ultra: all 400 FLEURS clips identical to the 0.4.1 line. Hebrew
model on the 108 FLEURS Hebrew clips: 395 of 1,873 word errors before, 396
after. The same clips trimmed so every length is a multiple of eight frames:
393 before, 397 after, no empty transcript either way.

Decision. No accuracy reason to move the base. 0.4.2 also carries a fix for
x86 processors whose operating system has not enabled a register set (#246),
which may matter on Windows and Linux; that is a robustness question for
another round, not this one.

## Design, round 2

The rest of the gallery was reviewed as contact sheets (onboarding, import,
Library in both appearances, the protected-typing banner): no defects.

One gap is not a defect: the take panel appears, changes state and leaves
with hard cuts. The code says why its contents are static ("an iterative
effect drove a RenderBox/CA commit on every display refresh through the
glass" while recognition waits for the main actor). A window-level fade at
appearance and departure would not touch that path, but it changes the feel
of the most-seen surface, so it is a proposal for Mik, not a change.

## Published, 20 November

Mik said to publish. Before the runtime went out, the Intel slice was
checked, because S1 runs there too (Accelerate exists on Intel Macs) and
every earlier comparison was on Apple silicon.

Method. The comparison probe built for x86_64 with the CPU backend, once
against the shipped framework and once against the new one, run under
Rosetta on 12 English and 8 Russian FLEURS clips (210 s of audio).

Result. The same text, token ids and token times on all 20 clips; token
confidence differs by at most 1e-6. Decoding took 1,758 ms before and 855 ms
after. The encoder, which is nearly all of the time on that path, is
unchanged (179 s either way under Rosetta). Rosetta is not an Intel Mac, so
this says the code path is right, not how fast a real one is.

The fork's branch `openramble/v0.4.1` moved to `dacdba09` and the release
`v0.4.1-dacdba09` carries the audited package (checksum `f181b34d…7d3d`).
Against the published package the speech package's tests pass, the
real-model ones included, and `TaughtWordsEndToEndTests` with them.

## Found, not done

- **Leftover files.** `Takes/` in the installed app's support folder holds 66
  `.openramble-delete-take-*.intent` files from August, 50 bytes each.
- **The latency gate in the release** has no allowance for a busy Mac (see
  the 0.41.0 notes).
