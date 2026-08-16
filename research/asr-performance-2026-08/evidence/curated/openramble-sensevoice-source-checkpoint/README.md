# Frozen SenseVoice source/CPU checkpoint

This directory is a temp-only, source/CPU checkpoint. The shared OpenRamble repository was not edited. The outcome is `HARD_NO_EN_RU`; model execution is neither needed nor authorized by this checkpoint.

## Reproduce the CPU checkpoint

```bash
cd $TMP/openramble-sensevoice-source-checkpoint
swift build -c release --build-path .build
python3 tests/test_checkpoint.py
python3 scripts/verify_cpu_checkpoint.py
```

These commands compile against CoreML but never instantiate `MLModel`, download weights, or run inference. Authorization tests intentionally terminate at token/manifest/missing-artifact gates before the local model-load call.

## Future diagnostic model command (sealed, do not run without a new explicit GO)

The current source verdict says not to spend this run. If a later request explicitly authorizes the already-rejected diagnostic, use a fresh destination and the exact two-stage flow below. Never reuse a prior token or artifact directory with uncertain lineage.

Download/install, once:

```bash
cd $TMP/openramble-sensevoice-source-checkpoint
export OPENRAMBLE_SENSEVOICE_WEIGHT_DOWNLOAD_GO=YES_EXACT_INT8_ONCE
./scripts/download_exact_int8.sh $TMP/openramble-sensevoice-model-cdea352-int8-ONE_USE_ID
unset OPENRAMBLE_SENSEVOICE_WEIGHT_DOWNLOAD_GO
```

Tiny candidate lane, once:

```bash
cd $TMP/openramble-sensevoice-source-checkpoint
MODEL_DIR=$TMP/openramble-sensevoice-model-cdea352-int8-ONE_USE_ID
OUTPUT=$TMP/openramble-sensevoice-tiny-candidate-ONE_USE_ID.jsonl
TIME_OUTPUT=$TMP/openramble-sensevoice-tiny-candidate-ONE_USE_ID.time.txt
TOKEN_FILE=$(mktemp $TMP/openramble-sensevoice-token.XXXXXX)
chmod 600 "$TOKEN_FILE"
/usr/bin/openssl rand 32 > "$TOKEN_FILE"
TOKEN_SHA=$(shasum -a 256 "$TOKEN_FILE" | awk '{ print $1 }')
env -u HF_TOKEN -u HUGGING_FACE_HUB_TOKEN -u HUGGINGFACEHUB_API_TOKEN \
  REGISTRY_URL=http://127.0.0.1:9 MODEL_REGISTRY_URL=http://127.0.0.1:9 \
  https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 \
  /usr/bin/time -l -o "$TIME_OUTPUT" \
  .build/release/sensevoice-probe server \
    --model-dir "$MODEL_DIR" \
    --artifact-manifest MODEL_ARTIFACTS.json \
    --token-file "$TOKEN_FILE" \
    --token-sha256 "$TOKEN_SHA" \
    < TINY_CANDIDATE_REQUESTS.jsonl > "$OUTPUT"
test ! -e "$TOKEN_FILE"
unset TOKEN_FILE TOKEN_SHA MODEL_DIR OUTPUT TIME_OUTPUT
```

Before and after this command, a controller must capture raw `sysctl vm.swapusage`, `memory_pressure -Q`, process/FD state, and thermal state; prove zero swap growth, normal pressure, clean child reap, and no inference-time network requests. It must run the pinned shipping schedule from `TINY_SMOKE_PREREG.json` symmetrically and apply every hard gate. The command above alone is not an A/B verdict.

The 204-corpus run remains forbidden by `CORPUS_204_PREREG.json`; there is intentionally no broad-run command.

## Contents

- `REPORT.md`: decision, evidence, gaps, costs, and fallback.
- `PINS.json`: source/model/license/network identities.
- `MODEL_ARTIFACTS.json`: exact nine-file int8 manifest.
- `TINY_SMOKE_PREREG.json`: frozen four-fixture design and hard gates.
- `TINY_CANDIDATE_REQUESTS.jsonl`: deterministic candidate request order.
- `CORPUS_204_PREREG.json`: frozen 204-fixture A/B and promotion rule.
- `Sources/SenseVoiceProbe/main.swift`: local-only, one-use-token, exact-manifest diagnostic worker.
- `scripts/download_exact_int8.sh`: inert-by-default exact installer.
- `scripts/verify_cpu_checkpoint.py`: full CPU/source verifier.
- `tests/test_checkpoint.py`: adversarial manifest, schedule, static-gate, and token tests.
