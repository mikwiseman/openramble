#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path("$TMP/openramble-static12_5-no-vocab-fallback-v1")
MANIFEST = Path(
    "$TMP/openramble-dominant-short-quality-v1/final-corpus/manifest.json"
)
RAW = ROOT / "raw"


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def rows(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def write_jsonl(path: Path, values: list[dict]) -> None:
    if path.exists():
        raise RuntimeError(f"refusing to overwrite {path}")
    temp = path.with_suffix(".tmp")
    with temp.open("x", encoding="utf-8") as handle:
        for value in values:
            handle.write(json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n")
    os.replace(temp, path)
    os.chmod(path, 0o444)


def main() -> None:
    preregistration = json.loads((ROOT / "PREREGISTRATION.json").read_text())
    if preregistration.get("inference_allowed") is not True:
        raise RuntimeError("inference_allowed=false; no run artifacts may be sealed")
    manifest = json.loads(MANIFEST.read_text())
    fixture_ids = sorted(f["id"] for f in manifest["fixtures"])
    if len(fixture_ids) != 204 or len(set(fixture_ids)) != 204:
        raise RuntimeError("expected exactly 204 unique fixtures")
    for name in ("shipping", "candidate-12.5"):
        receipt = json.loads((ROOT / f"run-metadata/{name}.completion.json").read_text())
        if (
            not receipt.get("complete")
            or receipt["completed"]["primary"] != 204
            or receipt["completed"]["duplicate"] != 204
            or not receipt.get("shutdown_ok")
            or receipt.get("process_return_code") != 0
        ):
            raise RuntimeError(f"incomplete receipt: {name}")
    expected = [
        "shipping.primary.jsonl",
        "shipping.duplicate.jsonl",
        "candidate-12.5.primary.jsonl",
        "candidate-12.5.duplicate.jsonl",
    ]
    for name in expected:
        actual = rows(RAW / name)
        actual_ids = [x.get("fixture_id") for x in actual]
        if actual_ids != fixture_ids or len(set(actual_ids)) != len(fixture_ids):
            raise RuntimeError(f"evaluator input fixture order/set mismatch: {name}")
    for path in sorted(RAW.glob("*.jsonl")):
        os.chmod(path, 0o444)
    for path in sorted((ROOT / "logs").glob("*.log")):
        os.chmod(path, 0o444)
    artifacts = []
    for directory in (RAW, ROOT / "logs", ROOT / "run-metadata"):
        for path in sorted(directory.glob("*")):
            if path.is_file():
                artifacts.append(
                    {
                        "path": str(path),
                        "bytes": path.stat().st_size,
                        "sha256": sha(path),
                        "line_count": len(path.read_text(errors="replace").splitlines()),
                    }
                )
    index = {
        "schema_version": 1,
        "status": "sealed_after_all_protocol_shutdown_and_before_frozen_evaluation",
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "cohort_counts": {"dominant_short_204": len(fixture_ids)},
        "manifest_path": str(MANIFEST),
        "manifest_sha256": sha(MANIFEST),
        "artifacts": artifacts,
    }
    output = ROOT / "RAW_ARTIFACT_INDEX.json"
    if output.exists():
        raise RuntimeError(f"refusing to overwrite {output}")
    temp = output.with_suffix(".tmp")
    temp.write_text(json.dumps(index, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    os.replace(temp, output)
    os.chmod(output, 0o444)
    print(f"index_sha256={sha(output)}")
    print("eval_inputs_complete=true")


if __name__ == "__main__":
    main()
