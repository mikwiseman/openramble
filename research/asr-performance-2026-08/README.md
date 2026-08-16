# OpenRamble ASR performance research handoff

This directory is the durable handoff for the August 2026 ASR performance and
reliability program. Start with [CONTINUATION_PROMPT.md](CONTINUATION_PROMPT.md).
It is written so a new agent can resume without reading the original chat.

The working objective was aggressive: make local English and Russian dictation
materially faster than Handy on short and long recordings, ideally 10× on every
fixture, without weakening transcript quality, privacy, cancellation, recovery,
or determinism. The experiments established real wins, several architectural
limits, and a long list of rejected ideas. Only the proven production-safe wins
were committed to the product branch.

## Snapshot contents

- [CONTINUATION_PROMPT.md](CONTINUATION_PROMPT.md): copy/paste prompt for the
  next agent, including objective, constraints, exact state, priorities, and
  stop conditions.
- [EXPERIMENTS.md](EXPERIMENTS.md): success and failure matrix with measured
  results and decisions.
- [AGENT_LOG.md](AGENT_LOG.md): roles, reviews, workstreams, and the final state
  of every agent lane.
- [REPRODUCIBILITY.md](REPRODUCIBILITY.md): hardware, revisions, commands,
  artifact policy, and how to regenerate the archive.
- [LICENSE_AND_PRIVACY.md](LICENSE_AND_PRIVACY.md): why 51.18 GiB of raw temp
  payload is represented by hashes/manifests rather than committed wholesale.
- `evidence/`: 478 small source/evidence files copied from temp worktrees with
  absolute local paths redacted. Original and archived hashes are recorded.
- `source-patches/`: metadata for every discovered temp Git checkout and the
  complete textual diff for each dirty checkout.
- `manifests/ARCHIVED_CONTENT.json`: original path, original SHA-256, archived
  path, archived SHA-256, sizes, and redaction status for every copied file.
- `manifests/TEMP_ROOT_INVENTORY.tsv`: all 244 top-level research roots, sizes,
  mtimes, and preservation class.
- `manifests/ALL_TEMP_FILE_PATHS.tsv.gz`: metadata-only inventory of 182,487
  files under those roots. This is intentionally compressed because build
  caches contain enormous numbers of repetitive paths.

## Snapshot scale

| Item | Value |
|---|---:|
| Temp roots inventoried | 244 |
| Temp files inventoried | 182,487 |
| Temp payload represented | 54,956,004,322 bytes (51.18 GiB) |
| Reviewable files archived | 478 |
| Original reviewable bytes | 22,189,841 |
| Repository snapshot size including authored docs | about 26 MiB |
| Dirty isolated Git worktrees captured | 17 |

## Product branch state at capture

- Repository: `mikwiseman/openramble`
- Branch: `perf/asr-phase-timing`
- Base at capture: `origin/main` at
  `aaebcacd8b9dbc0820b92b3ed02f51b1755d121d`
- Pre-handoff branch HEAD:
  `f2b6e8cc66d20f7a07094f79af0faf3ba861af64`
- Pinned FluidAudio work used by most model experiments:
  `ee9a7f12d91710da53de6d75f8b7160e09eccee4`
- Hardware: Apple M4, 16 GiB, macOS 26.4
- Installed OpenRamble was deliberately stopped while model experiments ran.

The four existing branch commits add benchmark-only phase timings, remove a
redundant fixed-input clear, remove CTC tensor boxing, and scope CTC rescoring to
candidate terms. The handoff commits add no new model behavior.

## Fastest honest summary

- Ordinary short dictation is already approximately 38–50 ms on this M4.
- The full-context 15 s encoder alone costs roughly 22–32 ms. Therefore a 10×
  win on every short fixture is not reachable through Swift cleanup or decoder
  tuning while preserving this exact model contract.
- The optional vocabulary/CTC path did have large avoidable host overhead. The
  committed direct tensor access and term filtering reduced representative
  vocabulary-on totals from roughly 212 ms to 84 ms with exact output hashes.
- Exact closed-window precomputation is a large long-form win: 56 s stop latency
  dropped from about 174 ms to 58 ms; 300 s dropped from about 748 ms to 65 ms.
  It is not integrated because an in-flight, non-preemptible Core ML operation
  can make an unlucky stop boundary slower on the single execution lane.
- Static 7.5, 10.0, and 12.5 s encoder shapes, fused decoder/joint, lean joint,
  GPU speculation, pseudo-streaming, SenseVoice Small, Nemotron experiments,
  Apple SpeechTranscriber, and endpoint speculation all failed at least one
  preregistered quality, parity, latency, language, or architecture gate.
- One source-only future candidate remains: PengChengStarling streaming
  Zipformer through sherpa-onnx CPU. It has explicit EN/RU and real recurrent
  caches, but no published EN/RU WER, no proven Core ML/Metal path, and requires
  a fail-closed initial-language-token API seam before any model download.

## Important interpretation rule

An archived failure is not a TODO to retry. Before touching a rejected branch,
the next agent must name a new falsifiable hypothesis that invalidates the old
failure mechanism. Re-running a model with more repetitions does not count.

## Regenerating the snapshot

```bash
python3 scripts/archive-asr-research.py
```

The collector is safe only for this public handoff policy. It intentionally
does not copy model weights, compiled bundles, audio, traces, build products,
credentials, or corpus payloads. See [LICENSE_AND_PRIVACY.md](LICENSE_AND_PRIVACY.md).
