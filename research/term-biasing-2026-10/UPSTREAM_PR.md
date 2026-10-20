# Draft upstream pull request: parakeet vocabulary through phrase boosting

Target: `handy-computer/transcribe.cpp`, branch `main`.
Status: draft. Not opened. Opening it needs Mik's approval.
Commits on top of `main` in the local checkout: `38e6f165`, `cc00dde6`,
`28e509ff` and `00aab60d`, to be squashed into one. The same change on top of
`v0.4.0` is `34a8b356`, which is what OpenRamble measured.

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
- The model's own argmax decides between blank and a token. Only when it
  emits a token does the vocabulary re-rank the non-blank tokens, so biasing
  changes which word is written and never whether one is: it cannot invent
  speech on silence or drop a word the model emitted.
- A term earns no bonus for its first piece. Once the model has begun a term
  on its own, each piece that extends the match earns a logit bonus, a piece
  that breaks it gives back what the unfinished match earned, and a completed
  term keeps its bonus. Many terms begin with a short, common word piece, and
  a bonus there rewrote ordinary words.
- The reported token confidence stays the model's own.
- With no terms the decoder never calls into the automaton, so output is
  bit-exact with today's.
- The bonus defaults to 8.0, chosen on a held-out half of the term set, and
  can be overridden with `TRANSCRIBE_VOCABULARY_BOOST`. Streaming and CTC heads ignore
  terms for now; the docs say so.

The automaton has a host-only unit test (`tests/phrase_boost_unit.cpp`): a
completed term keeps its bonus, a broken match gives back exactly what it
earned, a suffix that completes another term keeps that term through the
failure link, and `apply` matches `delta` for every token while leaving blank
alone. All 59 existing tests pass.

## Measurements

From OpenRamble's `research/term-biasing-2026-10/REPORT.md`, Parakeet v3 Q8,
Metal, one decoder thread:

- Term recall on the held-out half of a 70-sentence synthetic set: English
  22/37 without terms and 31/37 with them.
- On all 1,422 FLEURS English and Russian test utterances with 60 unrelated
  terms active, pooled WER +0.047 points (95% interval +0.014 to +0.091); 16
  utterances changed, every one toward a vocabulary term.
- No word on eleven clips of silence and noise, with or without terms.
- Without terms, transcripts are identical to v0.4.0 on all 1,422 utterances.
- The two earlier designs and why they were dropped are in the same report.

## Credit

Phrase boosting with a context graph follows icefall's `ContextGraph` and
NeMo's phrase boosting work; this is the single-hypothesis greedy reduction.
