#!/usr/bin/env python3
"""Fail-closed assessment of the normalized Core ML/xctrace export.

Controller monotonic values are compared only with other controller values.
Lifecycle and accelerator ordering use one xctrace clock. The Core ML template's
`ane-hw-intervals-internal` rows are global and carry no process identity, so
this assessor deliberately reports only ANE activity inside an exclusive
worker signpost bracket. It never upgrades that fact to an exact S/F route.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def rows(path: Path) -> list[dict[str, Any]]:
    result = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"{path}:{number}: row is not an object")
        value["_line"] = number
        result.append(value)
    return result


def _require_fields(row: dict[str, Any], fields: set[str]) -> None:
    missing = fields.difference(row)
    if missing:
        raise ValueError(f"trace row {row.get('_line')} missing {sorted(missing)}")


def assess(markers_path: Path, events_path: Path) -> dict[str, Any]:
    markers = rows(markers_path)
    events = rows(events_path)
    if not events:
        raise ValueError("trace contains no normalized events")
    clock_ids = {str(event.get("trace_clock_id", "")) for event in events}
    if len(clock_ids) != 1 or "" in clock_ids:
        raise ValueError("trace rows are not proven to share one xctrace clock domain")

    accelerator = [
        event for event in events if event.get("kind") == "accelerator_activity"
    ]
    observations = [
        event for event in events if event.get("kind") == "process_exit_observation"
    ]
    signposts = [event for event in events if event.get("kind") == "signpost"]
    evidence = [event for event in events if event.get("kind") == "prepare_evidence"]
    for event in accelerator:
        _require_fields(
            event,
            {
                "role_bracket",
                "trial_tag",
                "bracket_owner_pid",
                "start_trace_ns",
                "end_trace_ns",
                "compute_route",
                "attribution_scope",
                "exact_process_attribution",
            },
        )
        if int(event["end_trace_ns"]) < int(event["start_trace_ns"]):
            raise ValueError("trace accelerator interval has negative duration")
        if str(event["compute_route"]).lower() != "ane":
            raise ValueError("CPU/GPU/unknown accelerator activity is not accepted")
        if (
            event["attribution_scope"]
            != "global_ane_activity_in_exclusive_signpost_bracket"
            or bool(event["exact_process_attribution"])
        ):
            raise ValueError("unexpected or overstated accelerator attribution")
    for event in observations:
        _require_fields(
            event,
            {
                "pid",
                "signal",
                "trial_tag",
                "timestamp_trace_ns",
                "observation_source",
                "observer_pid",
            },
        )
        if event["observation_source"] != "dispatch_proc_exit":
            raise ValueError("process exit observation is not DISPATCH_PROC_EXIT-backed")
    for event in signposts:
        _require_fields(event, {"pid", "trial_tag", "name", "timestamp_trace_ns"})

    kills = [
        item
        for item in markers
        if item.get("event")
        in ("speculative_sigkill_waitpid", "replacement_prepare_sigkill_waitpid")
    ]
    requests = {
        str(item["trial_id"]): item
        for item in markers
        if item.get("event") == "foreground_request"
        and item.get("arm") in ("dual", "prepare_interruption")
    }
    exit_acks = {
        str(item["trial_id"]): item
        for item in markers
        if item.get("event") == "speculative_process_exit_observed"
    }
    if not kills:
        raise ValueError("marker stream contains no active speculative kill")

    checked = 0
    native_brackets = 0
    containment_brackets = 0
    for kill in kills:
        trial = str(kill["trial_id"])
        speculative_pid = int(kill["pid"])
        tag = int(kill["trial_tag"])
        sigkill = int(kill["sigkill_monotonic_ns"])
        waitpid = int(kill["waitpid_monotonic_ns"])
        duration = int(kill["reap_duration_ns"])
        observation_duration = int(kill.get("observation_wait_ns", 0))
        if kill.get("event") == "speculative_sigkill_waitpid":
            ack = exit_acks.get(trial)
            if ack is None:
                raise ValueError(f"{trial}: missing kernel exit-observation ACK marker")
            observation_duration = int(ack["observation_wait_ns"])
        if waitpid < sigkill or duration < 0 or duration > 250_000_000:
            raise ValueError(f"{trial}: SIGKILL→waitpid exceeds 250 ms")
        if observation_duration < 0 or duration + observation_duration > 250_000_000:
            raise ValueError(f"{trial}: SIGKILL→kernel observation exceeds 250 ms")
        if int(kill.get("process_return_code", 0)) != -9:
            raise ValueError(f"{trial}: exact child was not reaped as SIGKILL")

        request = requests.get(trial)
        if request is None:
            raise ValueError(f"{trial}: missing F request marker")
        # Safe: both are values from the controller's one monotonic clock.
        if int(request["request_monotonic_ns"]) < waitpid:
            raise ValueError(f"{trial}: F request precedes exact waitpid")
        if int(request["trial_tag"]) != tag:
            raise ValueError(f"{trial}: controller trial tag mismatch")
        foreground_pid = int(request["pid"])

        matching_observations = [
            event
            for event in observations
            if int(event["pid"]) == speculative_pid
            and int(event["signal"]) == 9
            and int(event["trial_tag"]) == tag
        ]
        if len(matching_observations) != 1:
            raise ValueError(f"{trial}: trace lacks one exact exit observation")
        observation = matching_observations[0]
        if int(observation["observer_pid"]) != foreground_pid:
            raise ValueError(f"{trial}: exit observer is not exact F")
        observation_time = int(observation["timestamp_trace_ns"])

        f_signposts = [
            event
            for event in signposts
            if event["name"] == "foreground_started"
            and int(event["pid"]) == foreground_pid
            and int(event["trial_tag"]) == tag
        ]
        if len(f_signposts) != 1:
            raise ValueError(f"{trial}: missing unique F foreground_started signpost")
        f_signpost_time = int(f_signposts[0]["timestamp_trace_ns"])
        if f_signpost_time <= observation_time:
            raise ValueError(f"{trial}: F signpost does not follow kernel observation")

        trial_evidence = [item for item in evidence if int(item["trial_tag"]) == tag]
        if len(trial_evidence) != 1:
            raise ValueError(f"{trial}: missing unique prepare/native evidence row")
        stage = str(trial_evidence[0].get("stage", ""))
        speculative_activity = [
            event
            for event in accelerator
            if event["role_bracket"] == "speculative"
            and int(event["bracket_owner_pid"]) == speculative_pid
            and int(event["trial_tag"]) == tag
        ]
        if stage == "protocol_containment":
            if kill.get("evidence_scope") != "protocol_containment_not_native_coreml_active":
                raise ValueError(f"{trial}: containment marker overstates native activity")
            if bool(trial_evidence[0].get("native_coreml_active_proven")):
                raise ValueError(f"{trial}: containment row claims native CoreML activity")
            if bool(
                trial_evidence[0].get(
                    "global_ane_activity_observed_in_exclusive_bracket"
                )
            ):
                raise ValueError(f"{trial}: containment evidence claims global ANE activity")
            if speculative_activity:
                raise ValueError(f"{trial}: containment bracket unexpectedly has ANE")
            containment_brackets += 1
        elif stage == "in_flight_prediction":
            if bool(trial_evidence[0].get("native_coreml_active_proven")):
                raise ValueError(f"{trial}: global ANE was mislabeled exact native activity")
            if not bool(
                trial_evidence[0].get(
                    "global_ane_activity_observed_in_exclusive_bracket"
                )
            ):
                raise ValueError(f"{trial}: prediction bracket lacks global ANE evidence")
            if not speculative_activity:
                raise ValueError(f"{trial}: native speculative bracket has no ANE activity")
            if max(int(item["end_trace_ns"]) for item in speculative_activity) > observation_time:
                raise ValueError(f"{trial}: global ANE activity survives kernel observation")
            native_brackets += 1
        else:
            raise ValueError(f"{trial}: unknown trace evidence stage {stage!r}")

        foreground_activity = [
            event
            for event in accelerator
            if event["role_bracket"] == "foreground"
            and int(event["bracket_owner_pid"]) == foreground_pid
            and int(event["trial_tag"]) == tag
        ]
        if not foreground_activity:
            raise ValueError(f"{trial}: F exclusive bracket has no ANE activity")
        if min(int(item["start_trace_ns"]) for item in foreground_activity) < f_signpost_time:
            raise ValueError(f"{trial}: F ANE bracket predates F start signpost")
        checked += 1

    return {
        "accepted": False,
        "lifecycle_and_global_ane_bracket_accepted": True,
        "production_exact_route_accepted": False,
        "production_blocker": (
            "xctrace ANE hardware rows have no exact process attribution; "
            "exclusive-bracket activity is not a per-process compute-route proof"
        ),
        "active_kills_checked": checked,
        "in_flight_prediction_signpost_brackets_checked": native_brackets,
        "protocol_containment_brackets_checked": containment_brackets,
        "speculative_global_ane_tail_after_kernel_observation": 0,
        "process_lifecycle_timestamp_claim": (
            "DISPATCH_PROC_EXIT notification observed in F; controller separately waits waitpid"
        ),
        "trace_clock_id": next(iter(clock_ids)),
        "cross_clock_numeric_comparisons": 0,
    }


# Compatibility name for callers/tests; this is an assessment, and `accepted`
# remains false until an exact PID-bearing CoreML route source exists.
accept = assess


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--markers", type=Path, required=True)
    parser.add_argument("--events", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        report = assess(arguments.markers, arguments.events)
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}, sort_keys=True))
        return 1
    print(json.dumps({"ok": False, "report": report}, indent=2, sort_keys=True))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
