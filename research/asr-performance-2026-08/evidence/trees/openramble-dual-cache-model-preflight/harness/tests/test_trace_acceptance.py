from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from trace_acceptance import accept


class TraceAcceptanceTests(unittest.TestCase):
    def write_rows(self, path: Path, rows: list[dict]) -> None:
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))

    def fixture(self, *, trace_offset: int = 1_000_000_000_000_000):
        markers = [
            {
                "event": "speculative_sigkill_waitpid",
                "trial_id": "t",
                "trial_tag": 77,
                "pid": 10,
                "sigkill_monotonic_ns": 200,
                "waitpid_monotonic_ns": 220,
                "reap_duration_ns": 20,
                "process_return_code": -9,
                "active_window_index": 1,
            },
            {
                "event": "foreground_request",
                "arm": "dual",
                "trial_id": "t",
                "trial_tag": 77,
                "pid": 20,
                "request_monotonic_ns": 230,
            },
            {
                "event": "speculative_process_exit_observed",
                "trial_id": "t",
                "observation_wait_ns": 5,
            },
        ]
        common = {"trace_clock_id": "xctrace-run-uuid"}
        events = [
            {
                **common,
                "kind": "accelerator_activity",
                "role_bracket": "speculative",
                "trial_tag": 77,
                "bracket_owner_pid": 10,
                "start_trace_ns": trace_offset + 10,
                "end_trace_ns": trace_offset + 90,
                "compute_route": "ane",
                "attribution_scope": "global_ane_activity_in_exclusive_signpost_bracket",
                "exact_process_attribution": False,
            },
            {
                **common,
                "kind": "process_exit_observation",
                "pid": 10,
                "signal": 9,
                "trial_tag": 77,
                "timestamp_trace_ns": trace_offset + 100,
                "observation_source": "dispatch_proc_exit",
                "observer_pid": 20,
            },
            {
                **common,
                "kind": "signpost",
                "name": "foreground_started",
                "trial_tag": 77,
                "pid": 20,
                "timestamp_trace_ns": trace_offset + 110,
            },
            {
                **common,
                "kind": "accelerator_activity",
                "role_bracket": "foreground",
                "trial_tag": 77,
                "bracket_owner_pid": 20,
                "start_trace_ns": trace_offset + 120,
                "end_trace_ns": trace_offset + 180,
                "compute_route": "ane",
                "attribution_scope": "global_ane_activity_in_exclusive_signpost_bracket",
                "exact_process_attribution": False,
            },
            {
                **common,
                "kind": "prepare_evidence",
                "trial_tag": 77,
                "stage": "in_flight_prediction",
                "global_ane_activity_observed_in_exclusive_bracket": True,
                "native_coreml_active_proven": False,
                "timestamp_trace_ns": trace_offset + 5,
            },
        ]
        return markers, events

    def run_accept(self, markers: list[dict], events: list[dict]):
        with tempfile.TemporaryDirectory() as directory:
            marker_path = Path(directory) / "markers.jsonl"
            event_path = Path(directory) / "events.jsonl"
            self.write_rows(marker_path, markers)
            self.write_rows(event_path, events)
            return accept(marker_path, event_path)

    def test_accepts_trace_chain_with_arbitrary_clock_offset(self) -> None:
        markers, events = self.fixture(trace_offset=9_000_000_000_000_000)
        report = self.run_accept(markers, events)
        self.assertFalse(report["accepted"])
        self.assertTrue(report["lifecycle_and_global_ane_bracket_accepted"])
        self.assertFalse(report["production_exact_route_accepted"])
        self.assertEqual(report["cross_clock_numeric_comparisons"], 0)

    def test_adversarial_offset_cannot_hide_ane_tail_after_process_exit(self) -> None:
        # Controller times are around 10^15 while trace times are around 100.
        # The removed implementation would accept `S end 130 <= waitpid 10^15`.
        # The one-trace-domain proof correctly compares end 130 to exit 100.
        markers, events = self.fixture(trace_offset=0)
        markers[0]["sigkill_monotonic_ns"] = 1_000_000_000_000_000
        markers[0]["waitpid_monotonic_ns"] = 1_000_000_000_000_020
        markers[1]["request_monotonic_ns"] = 1_000_000_000_000_030
        events[0]["end_trace_ns"] = 130
        with self.assertRaisesRegex(ValueError, "survives kernel observation"):
            self.run_accept(markers, events)

    def test_rejects_cpu_or_gpu_route(self) -> None:
        markers, events = self.fixture()
        events[0]["compute_route"] = "gpu"
        with self.assertRaisesRegex(ValueError, "CPU/GPU/unknown"):
            self.run_accept(markers, events)

    def test_containment_stage_is_not_mislabeled_native_coreml(self) -> None:
        markers, events = self.fixture()
        markers[0]["event"] = "replacement_prepare_sigkill_waitpid"
        markers[0]["evidence_scope"] = "protocol_containment_not_native_coreml_active"
        markers[1]["arm"] = "prepare_interruption"
        events = [event for event in events if event.get("role_bracket") != "speculative"]
        evidence = next(event for event in events if event.get("kind") == "prepare_evidence")
        evidence["stage"] = "protocol_containment"
        evidence["global_ane_activity_observed_in_exclusive_bracket"] = False
        evidence["native_coreml_active_proven"] = False
        report = self.run_accept(markers, events)
        self.assertEqual(report["protocol_containment_brackets_checked"], 1)
        self.assertEqual(report["in_flight_prediction_signpost_brackets_checked"], 0)

    def test_rejects_mixed_trace_clock_domains(self) -> None:
        markers, events = self.fixture()
        events[-1]["trace_clock_id"] = "different-run"
        with self.assertRaisesRegex(ValueError, "one xctrace clock domain"):
            self.run_accept(markers, events)


if __name__ == "__main__":
    unittest.main()
