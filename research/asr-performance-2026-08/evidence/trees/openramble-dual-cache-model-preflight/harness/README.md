# Dual-process exact-cache model preflight (temporary, default-deny)

This tree is isolated from both repositories and is not wired into OpenRamble.
It contains a same-artifact Swift worker plus a Python falsification controller.
The CPU checkpoint does not load a model. Model execution remains impossible
unless the controller flag, a newly reviewed token, and the token SHA-256 pinned
in the generated spec all agree.

## Exact contract

F is a persistent ordinary foreground worker. S is a distinct process built
from the exact same executable. S can export only completed, non-final raw TDT
TokenWindows. Before owner rebinding, F requires exact equality of:

- executable SHA-256 plus device/inode and code identity;
- every main/vocabulary artifact byte, canonical configuration, exact developer
  vocabulary, language, `MLComputeUnits`, encoder placement, hardware,
  architecture, OS build, and CoreML bundle build/binary;
- the independently replanned full window descriptor;
- every authoritative Float32 input byte in the final recording range.

SHA-256 is transport/artifact identity only. PCM acceptance is direct byte
equality. One mismatch, duplicate, overflow, stale session/storage/generation,
or worker fault discards the entire imported set and calls ordinary audited ASR
exactly once. CTC candidateRegions, fusion and developer-vocabulary work remain
the existing LocalASR final path.

Wire v2 validates metadata/payload lengths before allocation. F retains at most
32 records/24 MiB. A fixture must expose at least four closed plans, the first
point where one completed cache can remove a concurrency-4 foreground wave.

## CPU-only checkpoint

```sh
cd $TMP/openramble-dual-cache-model-preflight/harness
python3 -m unittest discover -s tests -v
python3 run.py fake-preflight --n-per-arm 2
python3 run.py fake-fault-soak --cycles 100
python3 run.py print-model-plan

OPENRAMBLE_FLUIDAUDIO_PATH=$TMP/openramble-dual-cache-model-preflight/FluidAudio \
swift test \
  --package-path $TMP/openramble-dual-cache-model-preflight/OpenRamble/Packages/LocalASR \
  --filter DualCachePreflightSupportTests

OPENRAMBLE_FLUIDAUDIO_PATH=$TMP/openramble-dual-cache-model-preflight/FluidAudio \
swift build -c release \
  --package-path $TMP/openramble-dual-cache-model-preflight/OpenRamble/Packages/LocalASR \
  --scratch-path $TMP/openramble-dual-cache-model-preflight/harness/build \
  --product dual-cache-worker
```

The worker's `--print-developer-vocabulary` and `--print-identity` modes are
CPU-only. `PREPARE`, `SPECULATE`, and `TRANSCRIBE` all require the independent
model gate. The CPU checkpoint never sends them.

## Tiny real preflight, only after a new explicit GO

The frozen real source is
`ru-terms-full.f32le` (SHA-256
`2950881e84a4a8706a5e91f525ee604214f9f2e218c3544d1b4b72d4dee7699d`),
repeated eight times to 60.6225 s. Repetition is bit-exact and stays below the
five-minute product bound.

First create a one-use reviewed spec. Do not reuse an earlier token:

```sh
export DCHF_COREML_GO_TOKEN='<NEW_TOKEN_FROM_ROOT_REVIEW>'
python3 $TMP/openramble-dual-cache-model-preflight/harness/make_preflight_spec.py \
  --worker $TMP/openramble-dual-cache-model-preflight/harness/build/release/dual-cache-worker \
  --model-directory '$HOME/Library/Application Support/OpenRamble/Models/parakeet-tdt-0.6b-v3/aed02740059203c4a87495924f685de3722ae9ce/parakeet-tdt-0.6b-v3' \
  --vocabulary-directory '$HOME/Library/Application Support/OpenRamble/Models/parakeet-ctc-110m/accdafd8cf8a2ff1cabe3c11e54416b405d409aa/parakeet-ctc-110m' \
  --output $TMP/openramble-dual-cache-model-preflight/harness/results/reviewed-spec.json
```

Then run exactly one fixture, offsets 0/25/50/75/100 ms, n=2 per symmetric
arm (10 observations per arm). Use a Python 3.10+ absolute path; the system
`/usr/bin/python3` is 3.9 on this host and is not a valid harness interpreter.
The Points of Interest instrument is required in addition to the Core ML
template:

```sh
DCHF_PYTHON="$(command -v python3)"
xcrun xctrace record --template 'Core ML' --instrument 'Points of Interest' \
  --output $TMP/openramble-dual-cache-model-preflight/harness/results/tiny-preflight.trace \
  --launch -- \
  "$DCHF_PYTHON" $TMP/openramble-dual-cache-model-preflight/harness/run.py \
    model-preflight --allow-coreml-after-explicit-go \
    --worker $TMP/openramble-dual-cache-model-preflight/harness/build/release/dual-cache-worker \
    --spec $TMP/openramble-dual-cache-model-preflight/harness/results/reviewed-spec.json \
    --fixture $TMP/openramble-phase-breakdown-ee9a7f12/fixtures-product/ru-terms-full.f32le \
    --fixture-repeat 8 --offsets 0,25,50,75,100 --n-per-arm 2 \
    --markers $TMP/openramble-dual-cache-model-preflight/harness/results/preflight-markers.jsonl \
    --resources $TMP/openramble-dual-cache-model-preflight/harness/results/preflight-resources.jsonl
```

S uses reload-per-trial for the worst case. An idle prepared S has a separate
two-boundary control and must retain the exact PID/generation. For active S the
controller records prediction-start, sends SIGKILL to that exact `Process`,
waits for exact waitpid, waits for F's already-armed kernel exit notification,
and only then records/sends F. The notification signpost is after actual exit;
it is not claimed to be the literal kernel-exit or waitpid timestamp. The
controller separately proves F request time follows its `Process.wait()` in
the controller clock. It also measures the full
unadjusted replacement-S launch→model-ready/prewarm wall time; the previously
seen 11–14 s OS-cache reload is not subtracted.

The N+1 Stop case waits for an exact `PREPARE_STARTED` wire response. A
separately authorized, bounded `protocol_containment` hold begins immediately
after that response and before model creation; S is then killed/reaped before F.
This deterministically proves protocol/lifecycle containment. It intentionally
does **not** claim that native CoreML load/warm was active.

Resource sampling is every 10 ms against the exact live F/S PIDs, with explicit
`prediction_started`, `pre_kill`, and `post_complete` checkpoints. To avoid
racing `libproc` with PID teardown, S is retired from sampling immediately after
the pre-kill checkpoint; the gap is covered by exact SIGKILL/waitpid and the
already-armed kernel-notification signpost, not by a claim of sampling through
waitpid. Exact pre/post swap bytes come from the 32-byte Darwin `xsw_usage`
returned by `sysctlbyname("vm.swapusage")`; ABI size and internal invariants are
checked fail-closed. Rounded human `vm.swapusage`, `memory_pressure -Q`, and
`kern.memorystatus_vm_pressure_level` outputs are saved only as raw audit text
next to the resource series.

## Hard acceptance

The tiny run is rejected unless all of these pass:

- transcript, raw token ID/string/start/end/confidence bits, word timing bits,
  candidateRegions, vocabulary outcome, and audio-duration bits are identical;
- active SIGKILL→waitpid is at most 250 ms and every F request follows waitpid;
- replacement S is ready before the next 51.84 s eligibility point;
- dual p95 and max stop→result are both strictly below the symmetric ordinary
  baseline;
- combined F+S physical footprint stays below 12 GiB on the 16 GiB host at
  every periodic/checkpoint sample, F descriptor growth is at most 2, at most
  two children exist, and no S is orphaned;
- pre/post kernel memory-pressure level is exactly normal, swap used bytes do
  not increase, and all raw resource outputs parse successfully;
- global ANE activity in the exclusive S bracket ends no later than F's kernel
  exit-observation signpost, there is no ANE activity before F starts, and no
  MPS/GPU interval overlaps either bracket.

First prove the selected capture/export path without a model. This command must
export our two-process signposts and kernel notification in one xctrace clock:

```sh
DCHF_PYTHON="$(command -v python3)"
xcrun xctrace record --template 'Core ML' --instrument 'Points of Interest' \
  --output $TMP/openramble-dual-cache-model-preflight/harness/results/cpu-trace-dry.trace \
  --launch -- \
  "$DCHF_PYTHON" $TMP/openramble-dual-cache-model-preflight/harness/trace_dry_controller.py \
    --worker $TMP/openramble-dual-cache-model-preflight/harness/build/release/dual-cache-worker \
    --markers $TMP/openramble-dual-cache-model-preflight/harness/results/cpu-trace-dry-markers.jsonl

"$DCHF_PYTHON" $TMP/openramble-dual-cache-model-preflight/harness/normalize_xctrace.py \
  --dry-run \
  --trace $TMP/openramble-dual-cache-model-preflight/harness/results/cpu-trace-dry.trace \
  --markers $TMP/openramble-dual-cache-model-preflight/harness/results/cpu-trace-dry-markers.jsonl \
  --output $TMP/openramble-dual-cache-model-preflight/harness/results/cpu-trace-dry-events.jsonl
```

After a separately authorized model capture, normalize and assess it:

```sh
"$DCHF_PYTHON" $TMP/openramble-dual-cache-model-preflight/harness/normalize_xctrace.py \
  --trace $TMP/openramble-dual-cache-model-preflight/harness/results/tiny-preflight.trace \
  --markers $TMP/openramble-dual-cache-model-preflight/harness/results/preflight-markers.jsonl \
  --output $TMP/openramble-dual-cache-model-preflight/harness/results/coreml-events.jsonl

"$DCHF_PYTHON" $TMP/openramble-dual-cache-model-preflight/harness/trace_acceptance.py \
  --markers $TMP/openramble-dual-cache-model-preflight/harness/results/preflight-markers.jsonl \
  --events $TMP/openramble-dual-cache-model-preflight/harness/results/coreml-events.jsonl
```

`ane-hw-intervals-internal` is a global hardware table and contains no PID.
The normalizer therefore never assigns those rows to S or F; it reports only
"ANE activity in an exclusive signpost bracket." Current `trace_acceptance.py`
returns exit status 2 and `production_exact_route_accepted=false` even when the
lifecycle/bracket checks pass. Exact per-process compute-route equivalence is a
remaining P0 blocker, not something executable/artifact/config identity can
prove. Any CPU/GPU/unknown route, global ANE tail after the observation, or
missing PID-bearing route source is a hard architecture rejection. The 5 ms,
n=20, 100-fault, 3–4 hour matrix remains disabled.
