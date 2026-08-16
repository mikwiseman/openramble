# Agent and workstream log

This is a compact map of the parallel workstreams. Detailed outputs, tests, and
hashes are in `EXPERIMENTS.md`, `evidence/`, and `source-patches/`.

## Product correctness and release work

- **Capture architecture/adversarial review**: bounded cancellation recovery,
  atomic committed-prefix sealing, late-append fencing, start containment outside
  the actor, exact ownership, bounded preservation, and causal N+1 admission.
- **Durable deletion/recovery**: exact/batch tombstones, cross-directory
  manifests, no unsafe expiry, file leases, partial repair, maintenance scans,
  storage-fault containment, and durable-ack APIs.
- **Clipboard/text insertion**: PID-targeted paste/Return and delayed clipboard
  restore serialized through one process-wide lane.
- **ASR worker soak**: 1,000/10,000 cycles, cancellation storms, descriptor
  reuse, protocol faults, zero orphan, and stable FD evidence.
- **Release hardening/review**: honest network wording, deny-network packaged
  recognition, strict nested signing without `--deep`, and artifact identity.
- **Cross-hardware review**: `.all` automatic placement, concurrency 4, optional
  CTC not gating primary TDT, and explicit readiness/residency concerns.
- **Critical reviews** also recorded remaining readiness, warmup vocabulary,
  recovered-audio refresh, timeout, and lifecycle risks. Read archived notes
  before declaring a release.

## Performance and model work

- **Fair benchmark harness**: persistent OpenRamble/Handy servers, canonical PCM,
  balanced order, resume identity, bootstrap intervals, and no plaintext output.
- **Phase timing design/review**: immutable per-result timings, exact boundaries,
  stable nullable schema, semantic validation, and no shipping suspension change.
- **Short shape/export and long cache**: model shapes, packaging, exact long
  cache, phase decomposition, placement, Nemotron, streaming source audit, and
  the PengChengStarling candidate.
- **Short-bucket quality**: engineering/untouched quality gates, dominant-short
  corpus provenance, fused graph rejection, endpoint/VAD and SenseVoice audits.
- **Endpoint/cache prototype**: endpoint falsification, portable cache theorem,
  dual-process lifecycle harness, trace honesty, and source-only model audits.

## Consultation and limitations

- Claude artifacts are included where generated.
- Kimi failed with HTTP 403 billing; no Kimi validation exists.
- Some Codex subagents exhausted usage after sealing files; those roots are in
  the manifests.
- Model weights, corpus audio, credentials, and user recordings were never
  authorized for Git.

## Takeover rule

Do not assign a rejected experiment as if unexplored. State the old failure,
name the new falsifiable hypothesis, define the hard stop, then open a new lane.
