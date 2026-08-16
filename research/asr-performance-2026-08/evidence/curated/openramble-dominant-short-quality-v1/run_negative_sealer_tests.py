#!/usr/bin/env python3
"""Prove the frozen sealer rejects representative corpus corruptions."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path


ROOT = Path("$TMP/openramble-dominant-short-quality-v1")
MANIFEST = ROOT / "final-corpus" / "manifest.json"
SEALER = ROOT / "seal_final_preregistration.py"
TEST_ROOT = ROOT / "negative-sealer-tests"
REPORT = ROOT / "NEGATIVE_SEALER_TESTS.json"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def main() -> None:
    if REPORT.exists() or TEST_ROOT.exists():
        raise RuntimeError("negative test outputs already exist")
    TEST_ROOT.mkdir(parents=True)
    base = json.loads(MANIFEST.read_text(encoding="utf-8"))
    cv_indices = [
        index for index, fixture in enumerate(base["fixtures"])
        if fixture.get("mirror_is_unofficial") is True
    ]
    if len(cv_indices) != 180:
        raise RuntimeError("unexpected Common Voice fixture count")
    first, second = cv_indices[:2]

    def missing(value: dict) -> None:
        value["fixtures"][first]["source_path"] = str(TEST_ROOT / "does-not-exist.mp3")

    def duplicate(value: dict) -> None:
        source = value["fixtures"][first]
        target = value["fixtures"][second]
        target["pcm_path"] = source["pcm_path"]
        target["pcm_f32le_sha256"] = source["pcm_f32le_sha256"]

    def bad_hash(value: dict) -> None:
        value["fixtures"][first]["source_sha256"] = "0" * 64

    def bad_locale(value: dict) -> None:
        value["fixtures"][first]["language"] = "xx"

    def bad_bin(value: dict) -> None:
        current = value["fixtures"][first]["duration_bin"]
        value["fixtures"][first]["duration_bin"] = "2-3" if current != "2-3" else "1-2"

    cases = [
        ("missing_source", missing, "missing canonical/source bytes or wrong sample rate"),
        ("duplicate_pcm", duplicate, "duplicate PCM within final corpus"),
        ("source_hash", bad_hash, "source SHA mismatch"),
        ("locale", bad_locale, "not in frozen Common Voice selection"),
        ("duration_bin", bad_bin, "Common Voice duration/reference mismatch"),
    ]
    results = []
    for name, mutate, expected in cases:
        value = json.loads(json.dumps(base, ensure_ascii=False))
        mutate(value)
        variant = TEST_ROOT / f"{name}.manifest.json"
        output = TEST_ROOT / f"{name}.armed.json"
        stdout = TEST_ROOT / f"{name}.stdout"
        stderr = TEST_ROOT / f"{name}.stderr"
        atomic_json(variant, value)
        completed = subprocess.run(
            [
                "python3",
                str(SEALER),
                "--final-manifest",
                str(variant),
                "--output",
                str(output),
            ],
            check=False,
            text=True,
            capture_output=True,
        )
        stdout.write_text(completed.stdout, encoding="utf-8")
        stderr.write_text(completed.stderr, encoding="utf-8")
        if completed.returncode == 0 or output.exists() or expected not in completed.stderr:
            raise RuntimeError(
                f"{name}: sealer did not fail closed as expected: rc={completed.returncode}"
            )
        results.append(
            {
                "case": name,
                "passed": True,
                "exit_code": completed.returncode,
                "expected_diagnostic": expected,
                "variant": str(variant),
                "variant_sha256": sha256_file(variant),
                "stdout": str(stdout),
                "stdout_sha256": sha256_file(stdout),
                "stderr": str(stderr),
                "stderr_sha256": sha256_file(stderr),
                "armed_output_absent": True,
            }
        )
    report = {
        "schema_version": 1,
        "status": "passed",
        "passed": True,
        "sealer": str(SEALER),
        "sealer_sha256": sha256_file(SEALER),
        "sealed_manifest": str(MANIFEST),
        "sealed_manifest_sha256": sha256_file(MANIFEST),
        "cases_passed": len(results),
        "cases": results,
        "sealed_manifest_mutated": False,
        "asr_or_coreml_runs": 0,
    }
    atomic_json(REPORT, report)
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    print(f"negative_tests_sha256={sha256_file(REPORT)}")


if __name__ == "__main__":
    main()
