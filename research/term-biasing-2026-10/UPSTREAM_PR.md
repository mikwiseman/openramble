# Draft upstream pull request: parakeet vocabulary through phrase boosting

Target: `handy-computer/transcribe.cpp`, branch `main`.
Status: draft. Not opened. Opening it needs Mik's approval.
Commit on top of `main`: `ece570e5` in the local checkout; the same change on
top of `v0.4.0` is `81d40989`, which is what OpenRamble measured.

## Title

parakeet: honor run_params.vocabulary with phrase boosting

## Description

`transcribe_run_params::vocabulary` exists since 0.3, but Parakeet ignores it
with a WARN because it has no prompt slot. This change makes the TDT and RNN-T
greedy decoders take the terms as phrase boosting, so every Parakeet user (v3,
Ultra, Nemotron and the rest of the family) can bias recognition toward names
and jargon through the existing API, with no new public symbol.

How it works:

- Each term is tokenized the way the model writes it, starting at a word
  boundary, with the existing SentencePiece encoder. A term with characters
  the tokenizer cannot write is skipped with a WARN.
- The terms form an Aho-Corasick automaton over token ids
  (`src/transcribe-phrase-boost.{h,cpp}`), with every transition resolved
  through the failure links once, at build time.
- On every greedy step the decoder adds to each candidate token the score
  emitting it would earn: a token that extends a partial match earns a logit
  bonus, a token that breaks one gives back what the unfinished match earned,
  and a completed term keeps its bonus. Blank is never adjusted.
- The argmax is taken over the boosted logits; the reported token confidence
  stays the model's own.
- With no terms the decoder never calls into the automaton, so output is
  bit-exact with today's.
- The bonus defaults to the value chosen below and can be overridden with
  `TRANSCRIBE_VOCABULARY_BOOST` for tuning. Streaming and CTC heads ignore
  terms for now; the docs say so.

The automaton has a host-only unit test (`tests/phrase_boost_unit.cpp`): a
completed term keeps its bonus, a broken match gives back exactly what it
earned, a suffix that completes another term keeps that term through the
failure link, and `apply` matches `delta` for every token while leaving blank
alone. All 59 existing tests pass.

## Measurements

To be filled from `research/term-biasing-2026-10/REPORT.md` after the gate:

- Term recall on the test half of a 70-sentence synthetic set (English names
  and tools; Russian speech with English developer terms), with and without
  the terms.
- WER on all 1,422 FLEURS English and Russian test utterances with the same
  60 terms active, against the unbiased decode, to show the cost of biasing on
  speech that contains none of the terms.
- Decode time with and without terms.

## Credit

Phrase boosting with a context graph follows icefall's `ContextGraph` and
NeMo's phrase boosting work; this is the single-hypothesis greedy reduction.
