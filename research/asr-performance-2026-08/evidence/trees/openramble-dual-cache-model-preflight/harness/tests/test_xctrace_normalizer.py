from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from normalize_xctrace import (
    HardwareInterval,
    TraceNormalizationError,
    active_prediction_signpost,
    exclusive_accelerator_event,
    parse_hardware_intervals,
    parse_signposts,
)


class XctraceNormalizerTests(unittest.TestCase):
    def test_multi_start_selects_pinned_latest_in_flight_window(self) -> None:
        def event(name: str, window: int, timestamp: int) -> dict:
            return {
                "name": name,
                "pid": 41,
                "timestamp_trace_ns": timestamp,
                "fields": {"trial_tag": 7, "window": window},
            }

        rows = [
            event("prediction_started", 0, 10),
            event("prediction_completed", 0, 20),
            event("prediction_started", 1, 30),
        ]
        active = active_prediction_signpost(
            rows,
            pid=41,
            trial_tag=7,
            expected_window_index=1,
            before_trace_ns=40,
        )
        self.assertEqual(active["fields"]["window"], 1)

    def test_latest_matching_completion_rejects_between_window_kill(self) -> None:
        def event(name: str, window: int, timestamp: int) -> dict:
            return {
                "name": name,
                "pid": 41,
                "timestamp_trace_ns": timestamp,
                "fields": {"trial_tag": 7, "window": window},
            }

        rows = [
            event("prediction_started", 0, 10),
            event("prediction_completed", 0, 20),
            event("prediction_started", 1, 30),
            event("prediction_completed", 1, 35),
        ]
        with self.assertRaisesRegex(TraceNormalizationError, "matching prediction_completed"):
            active_prediction_signpost(
                rows,
                pid=41,
                trial_tag=7,
                expected_window_index=1,
                before_trace_ns=40,
            )

    def test_unread_pipe_marker_cannot_hide_newer_xctrace_window(self) -> None:
        def event(name: str, window: int, timestamp: int) -> dict:
            return {
                "name": name,
                "pid": 41,
                "timestamp_trace_ns": timestamp,
                "fields": {"trial_tag": 7, "window": window},
            }

        # Controller still believes window 1 is active, but xctrace proves its
        # completion and the start of window 2 before exit observation.
        rows = [
            event("prediction_started", 1, 30),
            event("prediction_completed", 1, 35),
            event("prediction_started", 2, 36),
        ]
        with self.assertRaisesRegex(TraceNormalizationError, "does not match latest"):
            active_prediction_signpost(
                rows,
                pid=41,
                trial_tag=7,
                expected_window_index=1,
                before_trace_ns=40,
            )

    def test_older_uncompleted_window_is_rejected(self) -> None:
        def event(name: str, window: int, timestamp: int) -> dict:
            return {
                "name": name,
                "pid": 41,
                "timestamp_trace_ns": timestamp,
                "fields": {"trial_tag": 7, "window": window},
            }

        rows = [event("prediction_started", 0, 10), event("prediction_started", 1, 30)]
        with self.assertRaisesRegex(TraceNormalizationError, "older prediction"):
            active_prediction_signpost(
                rows,
                pid=41,
                trial_tag=7,
                expected_window_index=1,
                before_trace_ns=40,
            )

    def test_resolves_xctrace_refs_and_exact_signpost_fields(self) -> None:
        xml = """<?xml version="1.0"?>
<trace-query-result><node><row>
<event-time id="1">123</event-time>
<thread id="2"><tid>7</tid><process id="3"><pid id="4">42</pid></process></thread>
<process ref="3"/><event-type>Event</event-type><string>Process</string>
<os-signpost-identifier>1</os-signpost-identifier>
<signpost-name id="5">speculative_process_exit_observed</signpost-name>
<format-string>observer_pid=%d speculative_pid=%d trial_tag=%llu</format-string>
<sentinel/><subsystem id="6">is.waiwai.dictation.dual-cache-preflight</subsystem>
<category id="7">PointsOfInterest</category>
<os-log-metadata id="8" fmt="observer_pid= 42  speculative_pid= 41  trial_tag= 4,923">ignored</os-log-metadata>
<sentinel/>
</row><row>
<event-time id="9">124</event-time><thread ref="2"/><process ref="3"/>
<event-type>Event</event-type><string>Process</string><os-signpost-identifier>1</os-signpost-identifier>
<signpost-name ref="5"/><format-string>same</format-string><sentinel/>
<subsystem ref="6"/><category ref="7"/><os-log-metadata ref="8"/><sentinel/>
</row></node></trace-query-result>"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "signposts.xml"
            path.write_text(xml)
            rows = parse_signposts(path)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["timestamp_trace_ns"], 123)
        self.assertEqual(rows[0]["pid"], 42)
        self.assertEqual(rows[0]["fields"]["speculative_pid"], 41)
        self.assertEqual(rows[0]["fields"]["trial_tag"], 4923)
        self.assertEqual(rows[1]["name"], "speculative_process_exit_observed")

    def test_hardware_intervals_preserve_numeric_trace_time(self) -> None:
        xml = """<?xml version="1.0"?>
<trace-query-result><node><row>
<start-time id="1">9000000000000000</start-time><duration id="2">75</duration>
<ane-event-name id="3">ANE channel 2</ane-event-name>
</row><row><start-time ref="1"/><duration ref="2"/><ane-event-name ref="3"/></row>
</node></trace-query-result>"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ane.xml"
            path.write_text(xml)
            intervals = parse_hardware_intervals(path)
        self.assertEqual(len(intervals), 2)
        self.assertEqual(intervals[0].start_trace_ns, 9_000_000_000_000_000)
        self.assertEqual(intervals[0].end_trace_ns, 9_000_000_000_000_075)
        self.assertEqual(intervals[0].label, "ANE channel 2")

    def test_global_ane_interval_never_becomes_exact_pid_attribution(self) -> None:
        event = exclusive_accelerator_event(
            [HardwareInterval(10, 20, "ANE channel")],
            role_bracket="speculative",
            trial_tag=7,
            bracket_owner_pid=41,
        )
        self.assertNotIn("pid", event)
        self.assertEqual(event["bracket_owner_pid"], 41)
        self.assertFalse(event["exact_process_attribution"])
        self.assertEqual(
            event["attribution_scope"],
            "global_ane_activity_in_exclusive_signpost_bracket",
        )


if __name__ == "__main__":
    unittest.main()
