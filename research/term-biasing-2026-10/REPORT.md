# Phrase boosting for vocabulary terms

The question was whether the transcribe.cpp runtime can bias Parakeet toward a
person's vocabulary while it decodes, so names and jargon come out right
without hurting ordinary speech. The plan, the gate and every change to them
are in [PREREGISTRATION.md](PREREGISTRATION.md). Three designs were tested in
order, each preregistered before its code existed.

## What was measured

- **Term recall.** Seventy synthetic sentences read by macOS voices
  ([corpus.json](corpus.json)): 40 English sentences with rare product and tool
  names, and 30 Russian sentences where a speaker says English developer terms
  the Russian way ("пул реквест"). A term counts when its written form appears
  as whole words. Even rows tune the weight; odd rows are the test half.
- **The cost on ordinary speech.** WER on all 1,422 FLEURS English and Russian
  test utterances with all 60 terms active, against the same runtime with no
  terms, with a paired bootstrap interval.
- **Invented speech.** Words written on eleven clips of silence and noise.

All runs use Parakeet v3 Q8 through the app's own adapter (`asr-bench serve`,
one decoder thread, Metal), on transcribe.cpp v0.4.0 plus the change under
test, built by `scripts/build-transcribe-xcframework.sh`.

## Results

| | No terms | H4 | H4b | H4c |
|---|---:|---:|---:|---:|
| Design | | bonus on every matched piece | H4, but blank decided by the model alone | H4b, and no bonus on a term's first piece |
| Weight (chosen on the dev half) | | 3.0 | 3.0 | 8.0 |
| Term recall, test half, English | 22/37 | 32/37 | 32/37 | 31/37 |
| Term recall, test half, Russian | 0/34 | 2/34 | 2/34 | 0/34 |
| Pooled FLEURS WER difference, pp | | +0.071 | +0.044 | +0.047 |
| 95% interval, pp | | +0.010 to +0.137 | −0.007 to +0.097 | +0.014 to +0.091 |
| FLEURS utterances changed | | not counted | 62 | 16 |
| Words invented on noise | 0 | 18 | 0 | 0 |
| Gate (rules 1 to 4) | | failed rules 2 and 4 | passed | passed |
| Rule 5: warm p50 with terms, idle / under load | | | | +0.5% / +1.5% |

With no terms, all three runtimes give transcripts identical to upstream
transcribe.cpp 0.4.0 on all 1,422 FLEURS utterances.

**H4** made biasing change whether the decoder emitted anything: a bonus on a
term's first piece could outscore blank, which wrote "Postgres." on two
seconds of digital silence. **H4b** removed that by letting the model alone
decide between blank and a token. Its remaining cost came from short first
pieces: many terms begin with a one- or two-letter word piece, and a bonus there
rewrote ordinary words ("brides" to "hrides", "christina" to "cristina").
**H4c** gives no bonus until the model has begun a term itself, so it only
completes terms. All 16 utterances it changed moved toward a vocabulary term
("sintra" to "sentry", "features" to "feature").

H4b and H4c both pass the preregistered rules 1 to 4. H4b is marginally ahead
on both averages; H4c is carried forward because its errors only move toward
the person's own terms, while H4b rewrites unrelated names. That choice was
made after seeing the results, and it is recorded as such.

## What this does not fix

Russian speech that says English terms the Russian way is not helped: the
model writes "пул реквест" in Cyrillic, and biasing toward the Latin spelling
found at most 2 of 34 terms. For Russian, the app's text dictionary remains the
tool. The speech is synthetic, so real takes may behave differently; the
`term-recall` hook in the scorecard is for consented recordings.

Rule 5 was measured for H4c in an interleaved warm run of the same runtime with
and without the 60 terms: p50 327.8 against 326.3 ms idle and 428.1 against
421.9 ms under load, within the 5% limit. **H4c passes all five rules and is
adopted.**

## Still open

- The app wiring that hands the person's own dictionary to
  `TranscribeCppAdapter.setVocabulary` is written on this branch and has a
  unit test; it has not been compiled with the full app yet.
- A runtime build that ships it needs Mik's approval for a fork release or an
  upstream merge.
- The draft upstream pull request is in [UPSTREAM_PR.md](UPSTREAM_PR.md); it
  is not opened.
