#!/usr/bin/env python3
"""CPU-only file/interface accounting for the frozen static-12.5 artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path


LINEAGE = Path("$TMP/openramble-intermediate-quality-gate/ARTIFACT_LINEAGE.json")
LINEAGE_SHA256 = "4b976c8be281ed945f0a84064f4c0965d65139c35723f847b72b4c81b89cbc29"
OVERLAY_MEMO = Path("$TMP/openramble-derived-overlay-installer-memo.md")
OVERLAY_MEMO_SHA256 = "045ded9e53a4dcfec6c571ed5106eaa4878dddf5c26dfb398c4d264b2130930a"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def schema(metadata_path: Path, direction: str, name: str) -> list[int]:
    value = json.loads(metadata_path.read_text(encoding="utf-8"))
    records = value[0][direction]
    for record in records:
        if record["name"] == name:
            return [int(item.strip()) for item in record["shape"].strip("[]").split(",")]
    raise RuntimeError(f"{metadata_path}: missing {direction}/{name}")


def exact_shared_bytes(candidate: dict, shipping: dict) -> tuple[int, list[str]]:
    baseline = {(item["path"], item["sha256"]): item["bytes"] for item in shipping["files"]}
    shared = [
        item for item in candidate["files"] if (item["path"], item["sha256"]) in baseline
    ]
    return sum(item["bytes"] for item in shared), [item["path"] for item in shared]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if sha256(LINEAGE) != LINEAGE_SHA256 or sha256(OVERLAY_MEMO) != OVERLAY_MEMO_SHA256:
        raise RuntimeError("sealed packaging input hash mismatch")
    lineage = json.loads(LINEAGE.read_text(encoding="utf-8"))
    candidate = lineage["candidates"]["12.5"]
    shipping = lineage["shipping"]
    candidate_encoder_meta = Path(candidate["encoder"]["path"]) / "metadata.json"
    candidate_preprocessor_meta = Path(candidate["preprocessor"]["path"]) / "metadata.json"
    shipping_encoder_meta = Path(shipping["encoder"]["path"]) / "metadata.json"
    shipping_preprocessor_meta = Path(shipping["preprocessor"]["path"]) / "metadata.json"
    for role, record, path in (
        ("candidate_encoder", candidate["encoder"], candidate_encoder_meta),
        ("candidate_preprocessor", candidate["preprocessor"], candidate_preprocessor_meta),
        ("shipping_encoder", shipping["encoder"], shipping_encoder_meta),
        ("shipping_preprocessor", shipping["preprocessor"], shipping_preprocessor_meta),
    ):
        expected = next(item["sha256"] for item in record["files"] if item["path"] == "metadata.json")
        if sha256(path) != expected:
            raise RuntimeError(f"{role} metadata hash mismatch")
    shared_model_bytes, shared_model_paths = exact_shared_bytes(candidate["model"], shipping["model"])
    shared_encoder_bytes, shared_encoder_paths = exact_shared_bytes(candidate["encoder"], shipping["encoder"])
    candidate_unique_model = candidate["model"]["logical_bytes"] - shared_model_bytes
    candidate_encoder_input = schema(candidate_encoder_meta, "inputSchema", "mel")
    shipping_preprocessor_output = schema(shipping_preprocessor_meta, "outputSchema", "mel")
    candidate_preprocessor_output = schema(candidate_preprocessor_meta, "outputSchema", "mel")
    result = {
        "schema_version": 1,
        "status": "cpu_only_sealed_artifact_audit",
        "inputs": {
            "artifact_lineage": {"path": str(LINEAGE), "sha256": LINEAGE_SHA256},
            "overlay_installer_memo": {"path": str(OVERLAY_MEMO), "sha256": OVERLAY_MEMO_SHA256},
        },
        "interfaces": {
            "candidate_encoder_mel_input": candidate_encoder_input,
            "candidate_encoder_output": schema(candidate_encoder_meta, "outputSchema", "encoder"),
            "shipping_encoder_mel_input": schema(shipping_encoder_meta, "inputSchema", "mel"),
            "shipping_preprocessor_mel_output": shipping_preprocessor_output,
            "candidate_preprocessor_mel_output": candidate_preprocessor_output,
            "shipping_preprocessor_to_candidate_encoder_exact_shape_compatible": shipping_preprocessor_output == candidate_encoder_input,
            "candidate_preprocessor_to_candidate_encoder_exact_shape_compatible": candidate_preprocessor_output == candidate_encoder_input,
        },
        "file_level_accounting": {
            "shipping_model_logical_bytes": shipping["model"]["logical_bytes"],
            "candidate_model_logical_bytes": candidate["model"]["logical_bytes"],
            "candidate_encoder_logical_bytes": candidate["encoder"]["logical_bytes"],
            "candidate_preprocessor_logical_bytes": candidate["preprocessor"]["logical_bytes"],
            "candidate_encoder_exact_shared_bytes_with_shipping_encoder": shared_encoder_bytes,
            "candidate_encoder_exact_shared_paths_with_shipping_encoder": shared_encoder_paths,
            "candidate_model_exact_shared_bytes_with_shipping_model": shared_model_bytes,
            "candidate_model_exact_shared_paths_with_shipping_model": shared_model_paths,
            "candidate_model_incremental_unique_bytes_after_exact_file_dedupe": candidate_unique_model,
            "shipping_plus_candidate_unique_logical_bytes": shipping["model"]["logical_bytes"] + candidate_unique_model,
            "encoder_only_incremental_fraction_of_shipping_encoder": candidate["encoder"]["logical_bytes"] / shipping["encoder"]["logical_bytes"],
            "full_candidate_incremental_fraction_of_shipping_model": candidate_unique_model / shipping["model"]["logical_bytes"],
            "standalone_source_export_bytes": candidate["source_export"]["logical_bytes"],
        },
        "weights": {
            "shipping_encoder_weight_bytes": next(item["bytes"] for item in shipping["encoder"]["files"] if item["path"] == "weights/weight.bin"),
            "shipping_encoder_weight_sha256": shipping["shared_encoder_weight_sha256"],
            "candidate_encoder_weight_bytes": next(item["bytes"] for item in candidate["encoder"]["files"] if item["path"] == "weights/weight.bin"),
            "candidate_encoder_weight_sha256": next(item["sha256"] for item in candidate["encoder"]["files"] if item["path"] == "weights/weight.bin"),
            "whole_file_weight_reuse": False,
        },
        "semantic_overlay": {
            "shipping_operation_count": lineage["hybrid_preflight_finding"]["shipping_operation_count"],
            "candidate_operation_count": lineage["hybrid_preflight_finding"]["candidate_12_5_operation_count"],
            "positional_index_zip_allowed": False,
            "required_mapping": "one-to-one semantic tensor/blob attestation",
            "required_reference_count": 614,
            "complete_12.5_attestation_present": False,
            "status": "blocked",
            "note": "The prior 4.68 MB payload is a different short artifact and cannot be claimed for 12.5s.",
        },
        "verdict": {
            "encoder_only_current_interface": "not_feasible_without_an_unproven_1501_to_1251_mel_adapter_or_a_static_12.5_preprocessor",
            "standalone_candidate_pair": "technically_loadable_but_requires_445432595_incremental_unique_bytes_after_exact_file_dedupe",
            "semantic_overlay": "not_packageable_until_the_complete_12.5_semantic_attestation_and_packed_graph_are_generated_and_verified",
            "integration_feasible_now": False,
        },
        "asr_or_coreml_run": False,
    }
    if args.output.exists():
        raise RuntimeError(f"refusing to overwrite {args.output}")
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, args.output)
    os.chmod(args.output, 0o444)
    print(json.dumps(result["verdict"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
