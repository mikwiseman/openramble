# OpenRamble scorecard

The scorecard measures one recognition setup, called a candidate, on accuracy,
robustness, speed and memory, and writes the numbers to one JSON file per
candidate and one HTML page that compares them. A candidate is an engine, a
model, a runtime version or an app build. Every number on the page comes from
the same Mac, the same frozen inputs and the same text normalization, so two
candidates can be compared directly.

```bash
./scripts/scorecard.sh openramble-0.32.0 whisper-turbo
open research/scorecard/index.html
```

The scorecard continues the October 9 product benchmark in
`research/product-benchmark-2026-10`. It uses that study's frozen FLEURS
selection and checks it hash for hash, it uses the same normalization and the
same word aligner (jiwer 4.0.0), and it runs every process with the network
denied and the same 14-process CPU load. A unit test re-scores the retained
October 9 transcripts and reproduces the published word error rates exactly,
including substitutions, deletions and insertions.

## What is measured

Each suite is a set of inputs, and each metric is computed from one suite.

| Family | Metric | Suite and method |
|---|---|---|
| Accuracy | WER, English and Russian | 100 FLEURS test files per language, the October 9 selection. Words are lowercased, ё becomes е, punctuation is removed, numerals are not expanded. |
| Accuracy | WER on all FLEURS test speech | Every English and Russian FLEURS test utterance, 1,422 in all and 4.3 hours, for decisions that need more speech than the frozen subsets. The 200 frozen files are part of it with identical audio. Its hashes are in `fleurs-full.json.gz`. `scorecard.py paired` gives a WER difference between two candidates with a 95% interval from a paired bootstrap over utterances. |
| Accuracy | Punctuation F1 for commas, periods and question marks | The same files, scored against the FLEURS raw transcriptions, which keep their punctuation. See "Punctuation and capitalization" below. |
| Accuracy | Capitalization F1 | The same files. A word counts as capitalized when its first letter is uppercase. |
| Accuracy | WER on long dictation takes | Six takes of 33 to 129 seconds, built from whole FLEURS utterances with 0.5 seconds of silence between them, recognized through the same call a finished dictation reaches. |
| Robustness | Wrong-script rate | A decode is in the wrong script when most of its letters belong to the other alphabet, e.g. English speech written in Cyrillic. Measured on the 200 FLEURS files and on Mik's private English takes in `~/.openramble/lang-bug` (199 clips, including the 79-point boundary sweep). |
| Robustness | Words invented on silence and noise | Eleven generated clips with no speech: digital silence, white, pink and brown noise, mains hum and clicks, 2 to 45 seconds. Every word recognized there is invented. Bracketed annotations such as `[BLANK_AUDIO]` are counted apart, because products built on Whisper remove them. |
| Robustness | Long-file completeness | The October 9 hour composites (English, Russian and alternating), recognized through the file-import path. The deleted-word rate is the share of reference words with no counterpart in the output. |
| Speed | Warm latency, p50, p95 and p99 | A persistent `asr-bench serve` process with the model loaded and warmed up as the app does it. Six FLEURS files (the shortest, median and longest per language) and the six long takes, ten times each per condition. "Short" means under 15 seconds of audio, like the app's journal. |
| Speed | Whole-process latency | The candidate's command-line program from launch to exit on the six FLEURS files, six times each per condition. This includes model loading, so it is the cold path. |
| Speed | Under load | Both lanes are repeated while one busy process runs per logical CPU. Quiet and loaded blocks alternate in ABBA order, so slow drift is not mistaken for load. |
| Resources | Model load, peak memory, model file size | Load time and warm-up come from every warm process start. Peak memory is the maximum resident set size reported by `/usr/bin/time -l`. |

Speed is measured on a shared desktop, so a timed block starts only when two
one-second samples show at least 85% of the CPUs idle and no other recognition
process is running. The idle share is stored with every timed observation.
Several candidates given to one command are interleaved block by block in
balanced order, which is the only fair way to compare their speed. Numbers
from separate runs carry the drift of the machine between those runs.

## Punctuation and capitalization

Words are first aligned exactly as the WER alignment aligns them. Each word
carries the mark that follows it in the text, if that mark is a comma, a
period or a question mark. An exclamation mark and an ellipsis count as a
period, and a period or comma between two digits is part of a number. For
each aligned pair of words, a matching mark is a true positive. A reference
mark that the output lacks or replaces is a miss, and an output mark that the
reference lacks or replaces is a false alarm. A reference word that the
output deleted loses its mark as a miss, and an inserted output word with a
mark is a false alarm. Capitalization is compared only on words that both
sides recognized identically.

## Candidates

A candidate is a JSON file in `candidates/`. Its fields are listed here:

- `model.path` and `model.sha256` name the model file under the scorecard root and pin it.
- `process` names the command-line program for the whole-process lane: `openramble-cli`, `whisper-cli` or `asr-bench`.
- `warm` names the source commit whose `LocalASR` and `DictationCore` the warm lane is built from. The `asr-bench` tool target is always today's, so an old build can answer the scorecard's requests without any change to what it measures.

A candidate without a `warm` lane is measured through its process lane only.
For `whisper-cli` that means its accuracy, script and noise numbers come from
whole processes, and its warm latency is missing. Whisper's own reported
compute time is stored as `self_reported_compute` and is not mixed with
measured wall time.

## Inputs and the scorecard root

Inputs, binaries and raw outputs live in `$SCORECARD_ROOT`, by default
`~/Library/Caches/OpenRambleScorecard`. `scorecard.py prepare` downloads the
pinned FLEURS archives through the October 9 scripts, refuses to continue
unless every audio and reference hash matches the frozen manifest, and then
builds the noise clips and long takes from a fixed seed. Their hashes are
committed in `fixtures.json`, and a regenerated clip that differs is refused.

The baseline binaries are set up once:

```bash
R=~/Library/Caches/OpenRambleScorecard
# OpenRamble 0.32.0, the official signed DMG; openramble-cli SHA-256 23c28d79…
gh release download v0.32.0 -R mikwiseman/openramble -p 'OpenRamble-0.32.0.dmg' -D $R/dl
# mount it and copy OpenRamble.app to $R/apps/OpenRamble-0.32.0/
# whisper.cpp v1.9.5
git clone --branch v1.9.5 https://github.com/ggml-org/whisper.cpp $R/src/whisper.cpp
cmake -S $R/src/whisper.cpp -B $R/src/whisper.cpp/build -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON
cmake --build $R/src/whisper.cpp/build -j4 --target whisper-cli
# models, checked against the SHA-256 in each candidate file
#   $R/models/parakeet-tdt-0.6b-v3-Q8_0/parakeet-tdt-0.6b-v3-Q8_0.gguf
#   $R/models/whisper-large-v3-turbo/ggml-large-v3-turbo.bin
```

## Privacy

Public inputs keep their transcripts in the committed observation archive, so
anyone can re-score them. Private inputs never leave the Mac that holds them.
For a private clip the scorecard stores only letter counts per alphabet, a word
count, a hash of the normalized text, and the error counts computed while the
text was in memory. The committed results name the private corpus by a hash of
its audio hashes, not by file names.

## Hooks for metrics that need new data

Some metrics in the plan need recordings that do not exist yet. They are
reported as "not measured" with what they need, never as zero. A private
suite is a JSON Lines file in `~/.openramble/scorecard/suites/<name>.jsonl`
with one row per clip, e.g.
`{"path": "/abs/take.wav", "language": "en", "reference": "…", "terms": ["Kubernetes"]}`.
`prepare` picks it up and the `hooks` suite runs it.

| Suite name | Metric | What a row needs |
|---|---|---|
| `term-recall` | Share of expected names and terms found in the output | `reference` and `terms` |
| `code-switch` | WER on Russian and English mixed inside one take | `reference` |
| `noise-accent` | WER on MUSAN mixes at 20, 10 and 5 dB and on non-native speech | `reference`, optional `tag` |
| `onset-offset` | First-word and last-word capture rate | `reference`, with speech at the clip edges |

These metrics need the app rather than a recognizer, so this harness reports
them as outside its reach:

- The insertion matrix (right app, right text, clipboard unchanged) needs the Phase 4 end-to-end harness.
- Key-up to paste timing needs the journal's paste fields from Phase 4.
- Energy per dictated minute needs `powermetrics`, which needs sudo.
- Meaning preservation on disfluent speech belongs to the Clean Verbatim work in DictationCore.

## Comparing two candidates

`scorecard.py compare <baseline> <candidate>` prints each gated metric side by
side and exits with status 1 when any metric is worse than its tolerance. The
tolerances are in `GATES` in `scripts/scorecard/scorecard.py`, e.g. 0.25
percentage points of WER, no new wrong-script decodes, no new invented words,
and 10% on warm p50 with a 5 ms floor. A release candidate is meant to pass
this comparison against the shipping baseline.

## Limits

- One Mac, an Apple M4 Pro with 14 CPUs and 24 GB, running macOS 27.0.1.
- FLEURS is read speech. It does not stand for spontaneous dictation, accents, noise or code switching.
- The long takes and hour files are composites of public utterances with silence between them, not natural speech.
- The private wrong-script clips come from five takes by one speaker, so they measure a known failure, not a general rate.
- Whole-process latency is not key-release-to-paste latency.
- None of these numbers is a product claim.
