#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "verify_cpu_checkpoint", ROOT / "scripts/verify_cpu_checkpoint.py"
)
assert SPEC is not None and SPEC.loader is not None
verify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify)


class StrictJSONTests(unittest.TestCase):
    def test_duplicate_key_rejected(self) -> None:
        with self.assertRaisesRegex(verify.CheckFailure, "duplicate JSON key"):
            verify.strict_json_bytes(b'{"revision":"a","revision":"b"}')

    def test_invalid_json_rejected(self) -> None:
        with self.assertRaisesRegex(verify.CheckFailure, "invalid JSON"):
            verify.strict_json_bytes(b'{"revision":')


class ArtifactManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = verify.strict_json_file(ROOT / "MODEL_ARTIFACTS.json")

    def assert_rejected(self, mutation, message: str) -> None:
        candidate = copy.deepcopy(self.manifest)
        mutation(candidate)
        with self.assertRaisesRegex(verify.CheckFailure, message):
            verify.validate_manifest_structure(candidate)

    def test_sealed_manifest_is_valid(self) -> None:
        verify.validate_manifest_structure(self.manifest)

    def test_parent_path_rejected(self) -> None:
        self.assert_rejected(
            lambda value: value["artifacts"][0].__setitem__("path", "../weight.bin"),
            "unsafe artifact path",
        )

    def test_absolute_path_rejected(self) -> None:
        self.assert_rejected(
            lambda value: value["artifacts"][0].__setitem__("path", "/tmp/weight.bin"),
            "unsafe artifact path",
        )

    def test_duplicate_path_rejected(self) -> None:
        self.assert_rejected(
            lambda value: value["artifacts"][1].__setitem__(
                "path", value["artifacts"][0]["path"]
            ),
            "duplicate artifact path",
        )

    def test_boolean_size_rejected(self) -> None:
        self.assert_rejected(
            lambda value: value["artifacts"][0].__setitem__("byte_count", True),
            "invalid byte count",
        )

    def test_negative_size_rejected(self) -> None:
        self.assert_rejected(
            lambda value: value["artifacts"][0].__setitem__("byte_count", -1),
            "invalid byte count",
        )

    def test_malformed_sha_rejected(self) -> None:
        self.assert_rejected(
            lambda value: value["artifacts"][0].__setitem__("sha256", "ABC"),
            "invalid SHA",
        )

    def test_total_mismatch_rejected(self) -> None:
        self.assert_rejected(
            lambda value: value.__setitem__("total_byte_count", 1),
            "declared artifact total mismatch",
        )

    def test_compute_route_mismatch_rejected(self) -> None:
        self.assert_rejected(
            lambda value: value.__setitem__("compute_units", "all"),
            "unexpected compute route",
        )


class FrozenSemanticsTests(unittest.TestCase):
    def test_static_russian_gate_is_hard_no(self) -> None:
        result = verify.verify_static_ru_gate()
        self.assertEqual(result["decision"], "HARD_NO_EN_RU")

    def test_runner_has_local_identity_and_offline_gates(self) -> None:
        result = verify.verify_source_semantics()
        self.assertTrue(result["runner_manifest_hard_pin"])
        self.assertTrue(result["runner_offline_before_local_load"])

    def test_tiny_schedule_verifies_inputs_before_load(self) -> None:
        result = verify.verify_tiny()
        self.assertTrue(result["fixtures_verified_before_model_load"])
        self.assertEqual(result["measured_candidate_runs"], 16)

    def test_probe_authorization_failures_never_reach_model_load(self) -> None:
        result = verify.verify_probe_authorization()
        self.assertTrue(result["accepted_token_consumed"])
        self.assertTrue(result["accepted_token_stopped_at_missing_artifact_before_model_load"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
