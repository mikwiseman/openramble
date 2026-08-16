# Copy/paste continuation prompt

Copy everything below this line into a new agent session. It is intentionally
self-contained. The next agent should still read the linked files because they
contain the complete measurements, patches, hashes, and failure evidence.

---

You are taking over the OpenRamble local-ASR performance, correctness, and
reliability program. Work entirely in English. Do not restart the research from
scratch, do not silently discard negative results, and do not describe a failed
or inconclusive experiment as unfinished product work.

## 1. Repository and exact handoff state

- Repository: `https://github.com/mikwiseman/openramble.git`
- Local checkout: `/Users/mikwiseman/Documents/Code/openramble`
- Working branch: `perf/asr-phase-timing`
- Pre-handoff branch HEAD: `f2b6e8cc66d20f7a07094f79af0faf3ba861af64`
- Base observed during capture: `origin/main` at
  `aaebcacd8b9dbc0820b92b3ed02f51b1755d121d`
- Pinned FluidAudio revision used by most experiments:
  `ee9a7f12d91710da53de6d75f8b7160e09eccee4`
- Test host: Apple M4, 16 GiB, macOS 26.4.
- The installed `/Applications/OpenRamble.app` was intentionally stopped while
  model experiments ran. Do not relaunch it during an exclusive benchmark.

Immediately run:

```bash
cd /Users/mikwiseman/Documents/Code/openramble
git status --short
git branch --show-current
git log --oneline --decorate -12
git fetch origin
git rev-parse HEAD origin/main
sed -n '1,260p' research/asr-performance-2026-08/README.md
sed -n '1,420p' research/asr-performance-2026-08/EXPERIMENTS.md
```

If the branch contains commits after `f2b6e8c`, those are the durable handoff
commit(s). Preserve them. Never force-push shared history.

## 2. Your objective

Continue improving local English and Russian dictation latency, especially
Stop-to-text latency, while preserving all of the following:

1. Transcript quality and deterministic output.
2. Raw token IDs, token timings, confidence bits, word timings, vocabulary
   outcome, and punctuation/fusion behavior whenever the candidate claims exact
   compatibility.
3. Offline privacy. No audio upload, model download, or network request from the
   packaged recognition worker.
4. Correct cancellation, bounded memory/tasks/file descriptors, crash recovery,
   and no stale-session result publication.
5. English and Russian support under the shipping language contract.
6. macOS 14+, arm64, 16 GiB machines, and honest resource accounting.
7. Reproducible evidence. Never fabricate, infer, or replace a missing result
   with `pass`.

The original aspirational target was 10× faster than Handy on every fixture.
The evidence now proves that this is not achievable for every short fixture by
host-language cleanup or decoder tuning while retaining the current full-context
Parakeet model: ordinary short requests are already about 38–50 ms and the
15-second encoder alone costs about 22–32 ms on the M4. Treat that as an
architectural lower bound, not a motivation to weaken quality gates.

## 3. Mandatory first reading

Read these repository files before changing code:

1. `AGENTS.md`
2. `CLAUDE.md`
3. `research/asr-performance-2026-08/README.md`
4. `research/asr-performance-2026-08/EXPERIMENTS.md`
5. `research/asr-performance-2026-08/AGENT_LOG.md`
6. `research/asr-performance-2026-08/REPRODUCIBILITY.md`
7. `research/asr-performance-2026-08/LICENSE_AND_PRIVACY.md`
8. `research/asr-performance-2026-08/manifests/ARCHIVED_CONTENT.json`
9. The relevant patch under `research/asr-performance-2026-08/source-patches/`
   before revisiting any isolated experiment.

The archive represents 244 `/private/tmp` research roots, 182,487 paths, and
51.18 GiB of original material. It intentionally commits only reviewable source,
reports, hashes, manifests, and textual diffs. Model weights, compiled bundles,
audio/corpora, traces, build caches, credentials, and user data are excluded.
Do not interpret an absent binary as lost work: reconstruct it from the pinned
revision, command, and SHA recorded in the archive.

## 4. Product changes already on this branch

Four commits precede the handoff:

1. `027b61d bench: add local ASR phase timings`
   - Optional immutable `ASRPhaseTimings` travels with `ASRResult`.
   - Collection defaults off; only `asr-bench serve-jsonl` enables it.
   - No worker wire change and no new suspension point in shipping recognition.
   - Report schema is v4; JSONL protocol remains additively compatible.

2. `d49d63b perf: skip redundant TDT input clearing`
   - Removes a fixed 240,000-sample clear only where the next preprocessor call
     provably overwrites the entire input.
   - Short p50 improved about 18–24%; exact output hashes remained unchanged.

3. `c4124b6 perf: remove CTC tensor boxing`
   - Replaces generic `MLMultiArray` NSNumber scalar access with validated typed
     Float16/Float32 contiguous/strided access.
   - Representative CTC work fell from roughly 102 ms to 11 ms for one call and
     218 ms to 30 ms for two calls, with exact behavior preserved.

4. `f2b6e8c perf: scope CTC rescoring to candidate terms`
   - Lexical gating returns exact candidate indices; collision and acoustic
     rescue policy still sees the complete vocabulary.
   - Representative fusion p50 fell 37.5→2.1 ms; total 119→83 ms.

Do not casually revert or duplicate these changes. Verify their tests before
building a new candidate.

## 5. Confirmed conclusions

### Proven and integrated

- Benchmark phase instrumentation is additive and shipping-disabled.
- Redundant TDT input clearing was a real short-path cost.
- CTC tensor boxing and rescoring unrelated vocabulary terms were the largest
  removable vocabulary-path costs.
- The persistent paired Handy harness is useful internally and records balanced
  order, canonical PCM, hashes, warmups, bootstrap intervals, and resume identity.

### Proven prototype, not production-safe yet

Exact closed-window precomputation is the strongest remaining optimization for
long dictation. It cached raw TokenWindow results only for provably closed
non-final windows and preserved transcript plus full token-timing hashes:

- 56.1 s: 174.248/185.886 → 57.755/58.961 ms p50/p95.
- 84.4 s: 233.775/238.552 → 67.210/68.706 ms.
- 60 s synthetic: 179.618/181.040 → 73.136/75.061 ms.
- 120 s: 300.806/303.585 → 54.511/54.862 ms.
- 300 s: 747.686/756.985 → 64.766/71.516 ms.

It was not integrated because an active non-preemptible Core ML operation on
the one execution lane can still delay final recognition at an unlucky Stop
boundary. At the first speculative job with concurrency four, the worst-case
wave arithmetic cannot guarantee that Stop is never slower. A logical cancel
does not preempt native Core ML. Any future design must solve that exact issue,
not merely show good median latency.

### Honest Handy conclusion

The fair backend-only n=50 real-fixture Handy/OpenRamble p50 ratios were roughly
1.87×, 1.52×, 6.60×, and 4.91×. Do not publish these as an app-to-app claim:
Handy was a pinned locally patched backend, model formats/settings differ, the
fixture count is small, and long-cache quality noninferiority failed. Current
reports deliberately set `public_claim_eligible=false`.

## 6. Rejected paths — do not repeat without a new falsifiable hypothesis

An archived failure is not an open TODO. Before revisiting one, write down the
new fact or design change that invalidates the old failure mechanism.

1. **Static 7.5-second encoder**: 32–40% encoder win, but product-names WER
   regressed from 16.04% to 30.19%; rejected.
2. **Static 10.0/12.5-second encoders**: both failed the sealed untouched
   holdout because at least one utterance gained two word errors. A post-hoc
   fallback added cost and did not create a useful Stop win.
3. **EnumeratedShapes**: runtime dynamic-tile error; patched version lost ANE,
   became hundreds of milliseconds, consumed about 3.11 GiB RSS, and failed
   parity. MultiFunction conversion also failed and raises the OS floor.
4. **Four-bit/int8 encoders**: smaller or different artifacts did not provide a
   parity-safe speed win.
5. **Lean JointDecision**: joint work improved about 38%, but end-to-end only
   about 6.16%, below the gate and not validated under full product settings.
6. **Fused Decoder+JointDecisionCached**: exact and replay-safe, including the
   final preallocated ping-pong variant, but A=45.379 ms and B=45.964 ms. Every
   fixture slowed. Permanently closed for this design.
7. **Decoder/joint placement changes**: stayed within or behind ~2% run drift.
8. **Same-process active speculation**: cannot satisfy a no-regression guarantee
   at every stop boundary on one non-preemptible Core ML lane.
9. **Endpoint snapshot cache**: raw transcript 11/14, token timing 0/14, word
   timing 0/14. TDT/CTC depends on exact sample count; rejected under current
   semantics.
10. **Dual-process cache falsifier**: CPU lifecycle harness was strong, but all
    authorized model attempts stopped on fail-closed harness/resource issues
    before the latency/parity matrix. It is inconclusive, not a negative model
    result, and does not prove exact PID-to-ANE routing.
11. **GPU speculation**: MPSGraph crash or about 2.3× slower plus parity defects.
12. **Current SlidingWindow preview**: not production-wired, not true streaming,
    different config, unbounded stream, and still executes the full frontend at
    finalization for short input.
13. **SenseVoice Small**: no supported Russian path in the released runtime/model
    contract; static hard no for EN+RU product use.
14. **Nemotron GGUF experiment**: harness falsely treated a missing emitted
    language tag as language fallback and then leaked the recognizer on teardown,
    causing a Metal assertion. Evidence is fail-closed/incomplete; no R13 run.
15. **Endpoint/VAD speculation**: the 204-utterance corpus lacks independent
    endpoint labels, and a 256 ms window plus hysteresis causally misses exact
    speech-boundary Stop. No inference was authorized.
16. **Apple SpeechTranscriber and other audited APIs/models**: no demonstrated
    path that meets offline EN/RU, exact semantics, distribution, and latency.

See `EXPERIMENTS.md` for exact numbers, paths, and hashes.

## 7. Best next candidate

The only current source-only candidate worth a bounded follow-up is
PengChengStarling streaming Zipformer through sherpa-onnx CPU:

- explicit English and Russian language tokens;
- genuine recurrent streaming caches rather than overlapping full-context
  pseudo-windows;
- Apache-2.0 source/runtime direction;
- published artifact metadata totals about 339,349,396 bytes;
- estimated persistent state about 2,999,808 bytes;
- no model weights were downloaded and no inference was run in this handoff.

Blockers before any download:

1. The model requires the EN/RU language token as the initial token. Upstream
   sherpa starts with blank token 0, while the observed author fork sets
   `lang_id` too late. Add or prove a minimal fail-closed initial-token API seam.
2. There is no published EN/RU WER for the exact artifact.
3. No proven Core ML/Metal acceleration route exists; the first experiment must
   honestly be CPU-only.
4. Verify artifact license, exact repository commit, model SHA, tokenizer,
   sample-rate/chunk contract, network behavior, and packaging size before load.

If those source checks pass, preregister a tiny smoke before downloading:

- 2 English and 2 Russian real public fixtures, including short and longer
  utterances, with frozen source/PCM/reference hashes;
- one cold load, two warmups, at least three deterministic repeats;
- explicit language selection and proof that the initial token is correct;
- stable text, language, final-event count, ordered word/token timings;
- no empty/catastrophic output, duplicate/missing final, crash, orphan, FD leak,
  network access, or RTF >= 1;
- hard stop immediately on a language or lifecycle failure;
- only after this passes, design a preregistered EN/RU quality and latency gate.

Do not use the untouched 204 corpus for an exploratory smoke. It is sealed for
a candidate that has already passed source, lifecycle, language, and tiny real
fixture gates.

## 8. Candidate acceptance gates

Before integrating any new ASR/model/cache design, require:

### Correctness

- Frozen canonical PCM and references.
- English and Russian evaluated separately and together.
- Deterministic duplicate runs.
- No catastrophic or entity regression.
- Predeclared aggregate/language confidence bounds.
- No utterance with two or more added word errors unless the preregistration
  explicitly justifies another safety rule before outputs are inspected.
- Exact token/timing/confidence/word/vocabulary parity for an “exact cache” claim.

### Latency

- Persistent-process measurement with warmups.
- Balanced AB/BA or OH/HO order and A/A drift bracket.
- p50, p95, p99, max, paired deltas, and bootstrap intervals.
- Stop latency must include all work causally required after Stop.
- Background precompute cost, speech duty, tail risk, and boundary behavior must
  be reported separately and never hidden.
- A product graph change should provide at least a stable 10% end-to-end win;
  smaller graph-local wins are not enough.

### Resources and lifecycle

- Physical memory/RSS, swap delta, pressure state, disk bytes, load time, FD and
  child-process counts.
- Bounded queues/tasks/caches and exact-generation cancellation.
- No orphan process; SIGKILL/waitpid semantics if a helper is used.
- Never claim PID-specific ANE attribution from a global trace without actual
  PID-bearing evidence.

### Privacy and distribution

- Recognition succeeds under OS-level network denial.
- No runtime model download/install API is reachable from the packaged worker
  protocol.
- Permissive and verified model/source licenses.
- Do not commit or redistribute audio/model weights merely because they were
  downloadable during research.

## 9. Core ML runner coordination

Only one accelerator/model lane may run at a time on this machine. Before a
model run:

```bash
ps -axo pid,etime,command | rg -i '[c]oreml|[a]sr-bench|OpenRambleASRWorker|[h]andy|[p]hase-bench'
pmset -g therm
```

Do not use `pkill` or `killall`. Stop only an exact verified PID and executable
path. Record pre/post process and thermal state. Shut persistent workers down
through their protocol, wait for exit, and confirm the lane is free. Keep the
installed OpenRamble UI stopped until the final verification. Relaunch only the
exact installed app at the true end if the current user state requires it.

## 10. Testing and benchmark commands

Start proportionally, then run the full checks before landing:

```bash
swift test --package-path Packages/ASRWorkerProtocol
swift test --package-path Packages/LocalASR
swift test --package-path Packages/DictationCore
python3 -m unittest scripts/tests/test_benchmark_local_asr.py
./scripts/check-network-surface.sh
./scripts/check.sh
git diff --check
```

For timing work, preserve the disabled shipping path. The structural proof must
show no new `Task`, `await`, yield, lock, callback, or reordered model operation
solely for instrumentation. Never require phase sums to equal total because CTC
may be scheduled parallel to TDT and orchestration is residual.

## 11. Git and evidence rules

- Preserve user changes and unrelated dirty files.
- Use `apply_patch` for source/document edits.
- Never use `git reset --hard`, broad checkout, or force push.
- Stage explicit named paths; inspect the staged diff before commit.
- Keep changes bisectable and tests attached to production changes.
- Update this research handoff when an experiment passes or fails.
- Record negative results with the same care as successful ones.
- Never commit credentials, release keys, private recordings, corpus audio,
  model weights, compiled Core ML bundles, build caches, or huge traces.
- For excluded artifacts, record provenance, size, SHA-256, exact command, and
  why the bytes are excluded.
- Push the feature branch and use a PR. Do not publish or release unless the
  user separately asks; release requires clean main, same-SHA CI, Developer ID,
  notarization, Sparkle signature, and the documented release workflow.

## 12. External consultation status

- Claude consultation artifacts were captured where available.
- Kimi consultation failed with HTTP 403 billing. Do not claim Kimi or broad
  cross-model validation.
- Two final Codex worker lanes exhausted usage after sealing their temp files;
  their work is preserved in the archive and manifests.

## 13. Immediate recommended sequence

1. Verify the handoff commit and archive hashes.
2. Run the branch’s existing focused tests before modifying anything.
3. Read the PengChengStarling source-only memo and patch/inventory records.
4. Resolve the initial-language-token contract in source and unit tests without
   downloading a model.
5. Write and seal the tiny smoke preregistration and fixture hashes.
6. Only then coordinate the single model runner, download to a temporary
   location, verify exact SHA/license, and run the tiny smoke.
7. Hard-stop on the first language, lifecycle, privacy, or deterministic-output
   failure. Do not broaden a failing candidate.
8. If the tiny smoke passes, run an untouched EN/RU quality/latency experiment.
9. If it fails, record the failure and conclude honestly that the current
   Parakeet full-context short path is already near its architecture floor;
   concentrate product work on long-form cache architecture and user-visible
   reliability rather than manufacturing a 10× claim.

Your first response after taking over should state the exact branch/HEAD you
found, whether the worktree is clean, which evidence files you read, and the one
bounded next hypothesis you intend to test. Do not start model inference in the
same response.

---
