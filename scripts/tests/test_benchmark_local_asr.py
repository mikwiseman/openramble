#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
RUNNER = REPOSITORY / "scripts/benchmark-local-asr.py"
SPEC = importlib.util.spec_from_file_location("benchmark_local_asr", RUNNER)
assert SPEC is not None and SPEC.loader is not None
BENCHMARK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCHMARK)


FAKE_SERVER = r'''#!/usr/bin/env python3
import hashlib
import json
import os
import struct
import sys

PROTOCOL = 1
HANDY = "--benchmark-jsonl" in sys.argv
MODEL_ID = sys.argv[sys.argv.index("--model") + 1] if HANDY else "openramble-model"
MODEL_PATH = os.environ["FAKE_HANDY_MODEL_PATH"] if HANDY else os.environ["FAKE_OPEN_MODEL_DIR"]
buffers = {}
loaded = False
prewarmed = False
runs = 0

def digest(data):
    return hashlib.sha256(data).hexdigest()

def emit(value):
    print(json.dumps(value, sort_keys=True, separators=(",", ":")), flush=True)

for line in sys.stdin:
    request = json.loads(line)
    request_id = request["id"]
    command = request["command"]
    base = {"id": request_id, "ok": True, "protocol_version": PROTOCOL, "command": command}
    if command == "load":
        loaded = True
        if HANDY:
            base.update({
                "load_ns": 20_000_000,
                "source_commit": "db003f38b1aef4eb967ac3419bebc851d680f71c",
                "model_id": MODEL_ID,
                "model_path": MODEL_PATH,
                "bound_backend": "FAKE0",
                "effective_settings": {"language": "auto"},
            })
        else:
            base.update({
                "load_ns": 10_000_000,
                "effective_settings": {
                    "vocabulary_enabled": os.environ.get("WAI_VOCAB") == "on",
                    "encoder_placement": os.environ.get("WAI_ASR_ENCODER_PLACEMENT", "automatic"),
                    "vocabulary_scheduling": os.environ.get("WAI_ASR_VOCAB_SCHEDULING", "candidateRegions"),
                    "language": os.environ.get("WAI_ASR_LANGUAGE"),
                },
                "model": {
                    "model_id": MODEL_ID,
                    "engine_directory": MODEL_PATH,
                    "manifest_sha256": "1" * 64,
                },
                "vocabulary_model": None,
            })
        emit(base)
    elif command == "prewarm":
        assert loaded
        prewarmed = True
        base["prewarm_ns"] = 5_000_000
        emit(base)
    elif command == "preload":
        assert loaded
        if HANDY:
            pcm = open(request["path"], "rb").read()
            if os.environ.get("FAKE_HANDY_MISMATCH_PCM") == "1":
                pcm += struct.pack("<f", 1.0)
        else:
            pcm = b"".join(struct.pack("<f", sample) for sample in (0.0, 0.25, -0.25, 0.5))
            with open(request["canonical_path"], "wb") as stream:
                stream.write(pcm)
        buffers[request["key"]] = pcm
        base.update({
            "key": request["key"],
            "format": request["format"],
            "sample_rate": 16_000,
            "sample_count": len(pcm) // 4,
            "audio_duration_ns": (len(pcm) // 4) * 1_000_000_000 // 16_000,
            "pcm_f32le_sha256": digest(pcm),
        })
        emit(base)
    elif command in ("run", "run-file"):
        assert loaded
        runs += 1
        pcm = buffers.get(request.get("key"), next(iter(buffers.values())))
        text = "Hello, world!"
        raw = digest(text.encode())
        normalized = digest("hello world".encode())
        elapsed = (2_000_000 if HANDY else 1_000_000) + runs * 1_000
        base.update({
            "elapsed_ns": elapsed,
            "sample_rate": 16_000,
            "sample_count": len(pcm) // 4,
            "pcm_f32le_sha256": digest(pcm),
            "raw_transcript_sha256": raw,
            "normalized_transcript_sha256": normalized,
            "text": text,
            "prewarmed": prewarmed,
            "language_override": (
                "mismatch" if os.environ.get("FAKE_HANDY_MISMATCH_LANGUAGE") == "1"
                else request.get("language")
            ) if HANDY else None,
            "peak_rss_bytes": 123_456,
        })
        if not HANDY:
            base["timing"] = {
                "schema_version": 1,
                "clock": "monotonic_uptime",
                "total_wall_ns": elapsed,
                "total_wall_scope": (
                    "predecoded_transcribe" if command == "run"
                    else "file_decode_plus_transcribe"
                ),
                "phases_may_overlap": False,
                "phases": {
                    "primary_tdt_inference_decode_ns": 600_000,
                    "lexical_candidate_gate_ns": 100_000,
                    "ctc_model_inference_ns": None,
                    "ctc_rescoring_fusion_ns": None,
                },
                "ctc_inference_invocations": 0,
                "vocabulary_outcome": "no_candidate",
            }
        emit(base)
    elif command == "shutdown":
        emit(base)
        break
    else:
        emit({"id": request_id, "ok": False, "protocol_version": PROTOCOL, "error": "unknown"})
'''


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class SchedulingTests(unittest.TestCase):
    def test_balanced_schedule_is_exact_and_deterministic(self) -> None:
        first = BENCHMARK.balanced_schedule(100, 17, "fixture", "measured")
        second = BENCHMARK.balanced_schedule(100, 17, "fixture", "measured")

        self.assertEqual(first, second)
        self.assertEqual(first.count("OH"), 50)
        self.assertEqual(first.count("HO"), 50)
        self.assertNotEqual(
            first,
            BENCHMARK.balanced_schedule(100, 18, "fixture", "measured"),
        )

    def test_paired_bootstrap_is_deterministic(self) -> None:
        first = BENCHMARK.paired_bootstrap(
            [10, 11, 12, 13], [20, 22, 24, 26], 200, 123
        )
        second = BENCHMARK.paired_bootstrap(
            [10, 11, 12, 13], [20, 22, 24, 26], 200, 123
        )

        self.assertEqual(first, second)
        self.assertEqual(first["handy_over_openramble_p50_ratio"], 2.0)
        self.assertEqual(first["handy_over_openramble_p50_ratio_ci"], [2.0, 2.0])

    def test_defaults_name_the_predecoded_lane(self) -> None:
        parsed = BENCHMARK.arguments(
            ["--manifest", "m.json", "--output", "out.json"]
        )

        self.assertEqual(parsed.lane, "predecoded-product-warm")
        self.assertEqual(parsed.repeats, 100)
        self.assertEqual(parsed.warmups, 6)


class TimingSchemaTests(unittest.TestCase):
    @staticmethod
    def timing(**overrides: object) -> dict[str, object]:
        value: dict[str, object] = {
            "schema_version": 1,
            "clock": "monotonic_uptime",
            "total_wall_ns": 1_000,
            "total_wall_scope": "predecoded_transcribe",
            "phases_may_overlap": False,
            "phases": {
                "primary_tdt_inference_decode_ns": 600,
                "lexical_candidate_gate_ns": 100,
                "ctc_model_inference_ns": None,
                "ctc_rescoring_fusion_ns": None,
            },
            "ctc_inference_invocations": 0,
            "vocabulary_outcome": "no_candidate",
        }
        value.update(overrides)
        return value

    def test_accepts_parallel_no_candidate_without_summing_phases(self) -> None:
        timing = self.timing(
            phases_may_overlap=True,
            phases={
                "primary_tdt_inference_decode_ns": 800,
                "lexical_candidate_gate_ns": 100,
                "ctc_model_inference_ns": 900,
                "ctc_rescoring_fusion_ns": None,
            },
            ctc_inference_invocations=1,
        )

        sanitized = BENCHMARK.sanitize_timing(
            timing, 1_000, "predecoded_transcribe", required=True
        )

        self.assertEqual(sanitized, timing)

    def test_rejects_bool_numbers_and_total_or_ctc_mismatches(self) -> None:
        invalid = [
            self.timing(schema_version=True),
            self.timing(
                phases={
                    "primary_tdt_inference_decode_ns": True,
                    "lexical_candidate_gate_ns": 100,
                    "ctc_model_inference_ns": None,
                    "ctc_rescoring_fusion_ns": None,
                }
            ),
            self.timing(total_wall_ns=999),
            self.timing(ctc_inference_invocations=1),
        ]

        for timing in invalid:
            with self.subTest(timing=timing):
                with self.assertRaises(RuntimeError):
                    BENCHMARK.sanitize_timing(
                        timing, 1_000, "predecoded_transcribe", required=True
                    )

    def test_rejects_phase_values_that_contradict_outcome(self) -> None:
        timing = self.timing(vocabulary_outcome="rescored_unmodified")

        with self.assertRaisesRegex(RuntimeError, "contradict"):
            BENCHMARK.sanitize_timing(
                timing, 1_000, "predecoded_transcribe", required=True
            )


class RunnerIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.open_binary = self.root / "fake-openramble"
        self.handy_binary = self.root / "fake-handy"
        for binary in (self.open_binary, self.handy_binary):
            binary.write_text(FAKE_SERVER, encoding="utf-8")
            binary.chmod(0o755)

        self.open_model = self.root / "open-model"
        self.open_model.mkdir()
        (self.open_model / "weights.bin").write_bytes(b"open-model")
        self.handy_model = self.root / "handy.gguf"
        self.handy_model.write_bytes(b"handy-model")
        self.patch = self.root / "adapter.patch"
        self.patch.write_text("fake adapter patch\n", encoding="utf-8")
        self.fixture = self.root / "fixture.wav"
        self.fixture.write_bytes(b"frozen fixture")
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(
            json.dumps(
                {
                    "sources": {"suite": "synthetic-test"},
                    "fixtures": [
                        {
                            "id": "short",
                            "path": str(self.fixture),
                            "sha256": file_sha256(self.fixture),
                            "reference": "Hello world",
                            "language": "en",
                            "source": "generated in test",
                            "license": "test-only",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        self.output = self.root / "report.json"
        self.environment = os.environ.copy()
        self.environment["FAKE_OPEN_MODEL_DIR"] = str(self.open_model)
        self.environment["FAKE_HANDY_MODEL_PATH"] = str(self.handy_model)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def command(self, *extra: str) -> list[str]:
        return [
            sys.executable,
            str(RUNNER),
            "--manifest",
            str(self.manifest),
            "--openramble-bin",
            str(self.open_binary),
            "--handy-bin",
            str(self.handy_binary),
            "--handy-model",
            "fake-model-id",
            "--handy-model-path",
            str(self.handy_model),
            "--handy-model-sha256",
            file_sha256(self.handy_model),
            "--handy-source-commit",
            "db003f38b1aef4eb967ac3419bebc851d680f71c",
            "--handy-patch",
            str(self.patch),
            "--repeats",
            "4",
            "--warmups",
            "2",
            "--bootstrap-samples",
            "100",
            "--output",
            str(self.output),
            *extra,
        ]

    def run_command(self, *extra: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
        completed = subprocess.run(
            self.command(*extra),
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
        )
        self.assertEqual(
            completed.returncode,
            expected,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )
        return completed

    def test_persistent_paired_run_and_resume(self) -> None:
        self.run_command()
        first = json.loads(self.output.read_text(encoding="utf-8"))
        fixture = first["fixtures"][0]

        self.assertEqual(first["schema_version"], 4)
        self.assertFalse(first["method"]["public_claim_eligible"])
        self.assertIn("remain alive", first["method"]["process_residency"])
        self.assertRegex(
            first["engines"]["openramble"]["effective_settings_sha256"],
            r"^[0-9a-f]{64}$",
        )
        self.assertRegex(
            first["engines"]["handy"]["effective_settings_sha256"],
            r"^[0-9a-f]{64}$",
        )
        self.assertEqual(fixture["measured_schedule"].count("OH"), 2)
        self.assertEqual(fixture["measured_schedule"].count("HO"), 2)
        self.assertEqual(len(fixture["pairs"]), 4)
        self.assertTrue(
            all("openramble" in pair and "handy" in pair for pair in fixture["pairs"])
        )
        self.assertTrue(
            all(
                pair["openramble"]["pcm_f32le_sha256"]
                == pair["handy"]["pcm_f32le_sha256"]
                == fixture["canonical_pcm"]["sha256"]
                for pair in fixture["pairs"]
            )
        )
        self.assertIn("p99_ns", fixture["summary"]["openramble"])
        self.assertEqual(
            fixture["pairs"][0]["openramble"]["timing"]["schema_version"],
            1,
        )
        self.assertEqual(
            fixture["summary"]["openramble"]["phase_timings"]
            ["primary_tdt_inference_decode_ns"]["p50_ns"],
            600_000,
        )
        self.assertEqual(
            fixture["summary"]["openramble"]["vocabulary_outcomes"],
            {"no_candidate": 4},
        )
        self.assertIn("maximum_ns", fixture["summary"]["handy"])
        self.assertIn(
            "handy_over_openramble_p50_ratio_ci",
            fixture["summary"]["paired_comparison"],
        )
        self.assertNotIn("Hello, world!", self.output.read_text(encoding="utf-8"))

        original_pairs = fixture["pairs"]
        self.run_command("--resume")
        resumed = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(resumed["fixtures"][0]["pairs"], original_pairs)
        self.assertEqual(len(resumed["sessions"]), 2)

    def test_resume_rejects_changed_binary(self) -> None:
        self.run_command()
        with self.open_binary.open("a", encoding="utf-8") as stream:
            stream.write("\n# changed identity\n")

        completed = self.run_command("--resume", expected=1)
        self.assertIn("resume refused: experiment identity changed", completed.stderr)

    def test_file_wall_is_a_separately_named_lane(self) -> None:
        self.run_command("--lane", "file-wall")

        report = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(report["method"]["lane"], "file-wall")
        self.assertFalse(report["method"]["public_claim_eligible"])
        self.assertTrue(
            all(
                pair["openramble"]["elapsed_ns"] > 0
                and pair["handy"]["elapsed_ns"] > 0
                for pair in report["fixtures"][0]["pairs"]
            )
        )

    def test_predecoded_lane_rejects_mismatched_pcm(self) -> None:
        self.environment["FAKE_HANDY_MISMATCH_PCM"] = "1"

        completed = self.run_command(expected=1)

        self.assertIn("engines did not preload identical PCM", completed.stderr)

    def test_handy_language_override_must_match_fixture(self) -> None:
        self.environment["FAKE_HANDY_MISMATCH_LANGUAGE"] = "1"

        completed = self.run_command(expected=1)

        self.assertIn(
            "Handy adapter did not apply the requested fixture language",
            completed.stderr,
        )


if __name__ == "__main__":
    unittest.main()
