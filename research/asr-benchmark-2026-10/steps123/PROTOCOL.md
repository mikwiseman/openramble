# Steps 1–3: execution on 7 October

Base: `63b25fb`, shipping Parakeet v3 Q8 model SHA256
`5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7`.
Host: MacBook Pro M4 Pro, 24 GiB, macOS 27.0.1. The September
Mac mini corpus host did not resolve over SSH at the start of this run.

1. Build release `asr-bench` twice with only the pinned XCFramework changed:
   0.2.3 (`944be4d…b9c9`) and 0.3.1 (`9fbd7fa…287ca`). One decoder thread,
   same weights, same file/chunk/text paths. Reuse the existing preparation
   and quality scripts and the same SHA-ranked 100 RU + 100 EN CV19 dev
   examples. Restore them from pinned public archives on this host. Use the
   existing eight cached system-voice E2E fixtures separately; intended scripts
   are not independently verified spoken gold.
2. Inspect raw versus app outputs and replay specific text changes using the
   current Rust pipeline. Keep ordinary-word controls. Do not adopt an alias
   with only a development-set gain, or reinterpret missing negations as
   spelling mistakes. Preserve rejected candidates and reasons.
3. Repeat the existing ready-PCM controller latency test and its opt-in Stop
   distribution. Attribute time with existing engine/queue/return measurements.
   Trace actual long-file chunk inputs, native outputs and the join separately
   before changing segmentation. Reuse existing fictional long scripts only
   if their original audio cannot be reached; label any local re-render and
   verify its hash rather than treating it as the same audio.

Initial speed screen: six existing short WAVs, 20 measured repeats after warm-up,
fresh processes in ABBA order (0.2.3, 0.3.1, 0.3.1, 0.2.3). The input paths and
hashes were frozen in `timing-plan.json` before inference. This measures warmed
ready-PCM engine latency and process high-water RSS, not GUI latency. The
installed app and other desktop applications remain open: do not claim an
otherwise idle lane. A noisy result is inconclusive, not a speed win. Loading
and first Metal shader compilation are excluded and must be reported separately.

Runtime acceptance needs a repeatable benefit, no material RU/EN regression,
no new critical number/negation/omission failure, and valid timestamps. Existing
holdout is a validation step for a surviving frozen candidate, not a reason to
repeat all corpora after a candidate already fails its first gate. Product
changes require a failing regression test first and the repository checks.
Do not weaken latency thresholds, broaden dictionary matches, add another
model, or add production logging for this investigation.

Raw WAVs, scripts, individual transcripts, binary hashes and run logs were kept
outside Git under `/tmp/openramble-asr-audit-20261007/steps123` during execution.
They are now retained in `~/Documents/Code/openramble-evaluation/2026-10-07-steps123`,
with the old location as a symlink so sealed manifest paths still resolve.
Eight external E2E WAVs are additionally retained with an original-path map.
The exact two release products, including their native frameworks, are retained.
Only aggregate results, reproducible research source and decisions are committed.
