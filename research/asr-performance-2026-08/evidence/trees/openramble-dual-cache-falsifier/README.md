# Dual-process exact-cache falsifier (temporary, model-disabled)

This directory is intentionally outside both repositories. It is a CPU-only
controller and fake worker for falsifying the proposed two-process architecture;
it is not linked into OpenRamble.

The foreground worker owns ordinary concurrency-4 final ASR. A distinct
same-artifact speculative generation may emit only completed, non-final windows.
At stop the controller kills and `waitpid`-reaps that exact `Process` object,
then passes completed records to foreground. Any fault or validation mismatch
discards every record from that generation and invokes ordinary final exactly
once.

Acceptance is stronger than a PCM digest: every record carries its exact Float32
input bytes, and foreground directly compares the corresponding authoritative
final range. SHA-256 is only transport diagnostics and artifact identity. Owner
rebinding is legal only after exact identity equality, including executable
lineage/hash, code revision, every model/vocabulary file, canonical configuration,
language, vocabulary contents, configured `MLComputeUnits`/encoder placement,
hardware, architecture, OS build, and CoreML bundle build/binary hash.

CPU commands:

```sh
cd $TMP/openramble-dual-cache-falsifier
python3 -m unittest discover -s tests -v
python3 run.py fake-preflight --n-per-arm 2
python3 run.py fake-fault-soak --cycles 100
python3 run.py print-model-plan
```

`model-preflight` and `model-full` deliberately fail closed. They cannot launch
CoreML until a reviewed same-artifact Swift backend is implemented and an
explicit model-lane GO is received.

Proposed tiny preflight after that separate GO:

```sh
xcrun xctrace record --template 'Core ML' \
  --output $TMP/openramble-dual-cache-falsifier/results/preflight.trace \
  --launch -- \
  python3 $TMP/openramble-dual-cache-falsifier/run.py model-preflight \
    --worker $TMP/openramble-dual-cache-falsifier/build/dual-cache-worker \
    --fixture $TMP/openramble-dual-cache-falsifier/fixtures/long-real.f32le \
    --offsets 0,25,50,75,100 --n-per-arm 2
```

This is one frozen fixture and 10 observations per arm. Expected wall time is
6–10 minutes, dominated by speculative reload-per-trial. The full 5 ms/n=20
matrix is forbidden unless the trace proves no speculative CoreML event extends
past exact reap and all RSS/FD/process/parity gates pass.

The preflight also has two lifecycle controls. An idle S must keep the same PID
and generation across two stop boundaries and be reused without reload. An active
S emits a prediction-start signpost, then the trace records SIGKILL, `waitpid`,
the end of its last ANE event, and the later F request; any native ANE tail after
reap or reap over 250 ms rejects the architecture. After every active kill, the
unadjusted cold-reload-to-model-ready/prewarm wall time is reported (the earlier
11–14 s observation is not subtracted as “OS cache”) and compared with the next
session's planner-derived first wave-reducing eligibility (currently 51.84 s).
CPU/GPU speculation is not an accepted fallback: both processes must show the
same configured identity and actual ANE route in the Core ML trace.
