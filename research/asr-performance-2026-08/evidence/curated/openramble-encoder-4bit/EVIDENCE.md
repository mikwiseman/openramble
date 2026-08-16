# TEMP-only 4-bit encoder smoke — rejected

Date: 2026-08-14 (Europe/Moscow)

## Question

Could reducing the shipping 15-second FastConformer encoder palette from 6 to
4 bits produce a semantics-neutral >=10% short-dictation win?  The experiment
kept the 15-second input/output contract, source NeMo checkpoint, preprocessor,
decoder, joint model, compute placement, and FluidAudio call path unchanged.
It changed only the encoder k-means palette width in a temp-only re-export.

## Result

No.  The 4-bit encoder weight blob is 297,022,528 bytes versus the shipping
445,187,200 bytes (-33.3%), but encoder prediction improved only 1.64% on the
mean of four fixture medians.  Mean E2E latency regressed 2.48%.

| Frozen real fixture | shipping E2E p50 | 4-bit E2E p50 | delta | shipping encoder p50 | 4-bit encoder p50 | exact transcript |
|---|---:|---:|---:|---:|---:|---|
| LibriSpeech EN | 45.949 ms | 46.836 ms | +1.93% | 26.318 ms | 25.769 ms | no |
| VOiCES EN | 38.036 ms | 37.549 ms | -1.28% | 26.135 ms | 25.783 ms | yes |
| FLEURS RU 1 | 46.907 ms | 50.499 ms | +7.66% | 26.617 ms | 26.438 ms | no |
| FLEURS RU 6 | 45.761 ms | 46.158 ms | +0.87% | 26.424 ms | 25.773 ms | no |

All candidate repetitions were internally deterministic, but cross-model text
matched on only 1/4 fixtures.  Material regressions include:

- shipping: `Он сказал, что создал дверной звонок, работающий от вай-фай.`
  candidate: `Он сказал, что создал дверной звонок Работающий от вай-фай.`
- shipping: `О первых случаях заболевания в этом сезоне было сообщено в июле.`
  candidate: `А первый случай заболевание в этом сезоне было сообщено в июле.`

The experiment therefore fails both the latency and quality gates.  No broad
corpus run or product integration is justified.

## Method

- Four frozen real fixtures: LibriSpeech, VOiCES, and two FLEURS RU clips.
- Candidate: five warmups then ten measured calls per fixture in one persistent
  process; `.all` compute units, 15-second graph, `melChunkContext=false`,
  concurrency 4, max TDT tokens 600.
- Shipping comparator: the frozen n=60 phase report produced by the identical
  diagnostic harness.  The candidate failed by a wide semantic margin, so an
  additional A/B drift bracket was intentionally not run.
- No network model load; no shared-repository modification; no thermal or
  performance warning before or after; all benchmark processes exited.

## Frozen evidence

- NeMo checkpoint SHA-256:
  `3cbdc85877e668ca7b82d0d56770eb1fac76691f55d6b97545e8d61ca588d10d`
- Frozen exporter SHA-256:
  `58944318cb4590b88d60956fc32c3d88d86dc39d947a7f5e1750da3118143d58`
- 4-bit override wrapper SHA-256:
  `4ddc59531dcbcdc21c34977f38e35bbca68c9c99cf49b827b3f25349f907021d`
- Export metadata SHA-256:
  `5d80d13153b327122c7e748aafb5c72b48f99f59e33c1abf14673434c7cd2099`
- 4-bit source weight SHA-256:
  `c58fe4a97ebbaa3549ef769401bf054e6e0e72e309148135a6bc6197767742b9`
- Compiled encoder data SHA-256:
  `be26db6ff1abe2aa75904909f077015e3b434b56cfefda44b45dc8129a5df161`
- Raw smoke report SHA-256:
  `fc87f9c16e6c2acc0021fed482d3b319f7e6a27eb0b8d9c1affe3664de587c79`
