#!/usr/bin/env python3
"""Export and normalize the reviewed Core ML + Points of Interest trace.

All emitted timestamps come from numeric xctrace XML fields. Controller
monotonic values are used only for its own kill/wait/request invariants and are
never copied into or compared with this trace clock domain.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


SUBSYSTEM = "is.waiwai.dictation.dual-cache-preflight"
CATEGORY = "PointsOfInterest"
KILL_EVENTS = {"speculative_sigkill_waitpid", "replacement_prepare_sigkill_waitpid"}


class TraceNormalizationError(ValueError):
    pass


def _jsonl(path: Path) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise TraceNormalizationError(f"{path}:{line_number}: expected object")
        result.append(value)
    return result


class XMLResolver:
    def __init__(self, root: ET.Element) -> None:
        self.by_id = {
            element.attrib["id"]: element
            for element in root.iter()
            if "id" in element.attrib
        }

    def resolve(self, element: ET.Element) -> ET.Element:
        reference = element.attrib.get("ref")
        if reference is None:
            return element
        try:
            return self.by_id[reference]
        except KeyError as error:
            raise TraceNormalizationError(f"unresolved xctrace XML ref {reference}") from error

    def scalar(self, element: ET.Element) -> str:
        resolved = self.resolve(element)
        value = resolved.text
        if value is None:
            value = resolved.attrib.get("fmt", "")
        return value.strip()

    def direct(self, row: ET.Element, tag: str) -> ET.Element | None:
        for child in row:
            resolved = self.resolve(child)
            if resolved.tag == tag:
                return resolved
        return None

    def nested_scalar(self, element: ET.Element, tag: str) -> str | None:
        pending = [self.resolve(element)]
        seen: set[int] = set()
        while pending:
            candidate = pending.pop()
            identity = id(candidate)
            if identity in seen:
                continue
            seen.add(identity)
            if candidate.tag == tag:
                return self.scalar(candidate)
            pending.extend(self.resolve(child) for child in candidate)
        return None


def _parse_message_fields(message: str) -> dict[str, str | int]:
    result: dict[str, str | int] = {}
    pattern = re.compile(r"([a-z_]+)=\s*(.*?)(?=\s+[a-z_]+=|$)")
    for match in pattern.finditer(message):
        key = match.group(1)
        raw = match.group(2).strip()
        numeric = raw.replace(",", "")
        result[key] = int(numeric) if re.fullmatch(r"-?\d+", numeric) else raw
    return result


def parse_signposts(xml_path: Path) -> list[dict[str, Any]]:
    root = ET.parse(xml_path).getroot()
    resolver = XMLResolver(root)
    result: list[dict[str, Any]] = []
    for row in root.iter("row"):
        subsystem = resolver.direct(row, "subsystem")
        category = resolver.direct(row, "category")
        if subsystem is None or category is None:
            continue
        if resolver.scalar(subsystem) != SUBSYSTEM or resolver.scalar(category) != CATEGORY:
            continue
        time = resolver.direct(row, "event-time")
        process = resolver.direct(row, "process")
        name = resolver.direct(row, "signpost-name")
        message = resolver.direct(row, "os-log-metadata")
        if None in (time, process, name, message):
            raise TraceNormalizationError("preflight signpost row lacks required fields")
        assert time is not None and process is not None and name is not None and message is not None
        pid = resolver.nested_scalar(process, "pid")
        if pid is None:
            raise TraceNormalizationError("preflight signpost process lacks PID")
        fields = _parse_message_fields(message.attrib.get("fmt", resolver.scalar(message)))
        result.append(
            {
                "timestamp_trace_ns": int(resolver.scalar(time)),
                "pid": int(pid),
                "name": resolver.scalar(name),
                "fields": fields,
            }
        )
    return result


@dataclass(frozen=True)
class HardwareInterval:
    start_trace_ns: int
    end_trace_ns: int
    label: str


def parse_hardware_intervals(xml_path: Path) -> list[HardwareInterval]:
    root = ET.parse(xml_path).getroot()
    resolver = XMLResolver(root)
    result: list[HardwareInterval] = []
    for row in root.iter("row"):
        start = resolver.direct(row, "start-time")
        duration = resolver.direct(row, "duration")
        if start is None or duration is None:
            continue
        start_ns = int(resolver.scalar(start))
        duration_ns = int(resolver.scalar(duration))
        if duration_ns < 0:
            raise TraceNormalizationError("hardware interval has negative duration")
        label_element = next(
            (
                resolver.direct(row, tag)
                for tag in ("ane-event-name", "formatted-label", "string")
                if resolver.direct(row, tag) is not None
            ),
            None,
        )
        label = resolver.scalar(label_element) if label_element is not None else "unknown"
        result.append(HardwareInterval(start_ns, start_ns + duration_ns, label))
    return result


def _trace_clock_id(toc_root: ET.Element) -> str:
    run = toc_root.find("./run")
    if run is None or run.attrib.get("number") != "1":
        raise TraceNormalizationError("trace must contain exactly reviewed run 1")
    if toc_root.findall("./run") != [run]:
        raise TraceNormalizationError("trace contains multiple runs/time origins")
    template = run.findtext("./info/summary/template-name", default="")
    if template != "Core ML":
        raise TraceNormalizationError(f"unexpected xctrace template {template!r}")
    poi_tables = [
        table
        for table in run.findall("./data/table")
        if table.attrib.get("schema") == "os-signpost"
        and table.attrib.get("category") == CATEGORY
    ]
    if not poi_tables:
        raise TraceNormalizationError("trace lacks the Points of Interest instrument")
    schemas = {table.attrib.get("schema") for table in run.findall("./data/table")}
    if "ane-hw-intervals-internal" not in schemas:
        raise TraceNormalizationError("trace lacks ANE hardware intervals")
    device = run.find("./info/target/device")
    record = {
        "start_date": run.findtext("./info/summary/start-date", default=""),
        "end_date": run.findtext("./info/summary/end-date", default=""),
        "instruments_version": run.findtext(
            "./info/summary/instruments-version", default=""
        ),
        "template": template,
        "device_uuid": device.attrib.get("uuid", "") if device is not None else "",
        "device_os": device.attrib.get("os-version", "") if device is not None else "",
    }
    if any(not value for value in record.values()):
        raise TraceNormalizationError("trace clock identity metadata is incomplete")
    payload = json.dumps(record, sort_keys=True, separators=(",", ":")).encode()
    return "xctrace-sha256:" + hashlib.sha256(payload).hexdigest()


def _export(trace: Path, schema: str, output: Path) -> None:
    expression = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
    result = subprocess.run(
        [
            "/usr/bin/xcrun",
            "xctrace",
            "export",
            "--input",
            str(trace),
            "--xpath",
            expression,
            "--output",
            str(output),
        ],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0 or not output.is_file():
        raise TraceNormalizationError(
            f"xctrace export {schema} failed: {(result.stderr or result.stdout).strip()}"
        )


def _one_signpost(
    signposts: Iterable[dict[str, Any]],
    *,
    name: str,
    pid: int | None = None,
    trial_tag: int | None = None,
    speculative_pid: int | None = None,
) -> dict[str, Any]:
    matches = []
    for signpost in signposts:
        fields = signpost["fields"]
        if signpost["name"] != name:
            continue
        if pid is not None and int(signpost["pid"]) != pid:
            continue
        if trial_tag is not None and int(fields.get("trial_tag", -1)) != trial_tag:
            continue
        if speculative_pid is not None and int(fields.get("speculative_pid", -1)) != speculative_pid:
            continue
        matches.append(signpost)
    if len(matches) != 1:
        raise TraceNormalizationError(
            f"expected one {name} signpost, found {len(matches)}"
        )
    return matches[0]


def active_prediction_signpost(
    signposts: Iterable[dict[str, Any]],
    *,
    pid: int,
    trial_tag: int,
    expected_window_index: int,
    before_trace_ns: int,
) -> dict[str, Any]:
    """Find the exact started-but-not-completed window at process observation."""

    relevant = [
        item
        for item in signposts
        if int(item["pid"]) == pid
        and int(item["fields"].get("trial_tag", -1)) == trial_tag
        and int(item["timestamp_trace_ns"]) < before_trace_ns
        and item["name"] in ("prediction_started", "prediction_completed")
    ]
    starts: dict[int, dict[str, Any]] = {}
    completed: set[int] = set()
    for item in sorted(relevant, key=lambda value: int(value["timestamp_trace_ns"])):
        window = int(item["fields"].get("window", -1))
        if window < 0:
            raise TraceNormalizationError("prediction signpost lacks a window index")
        if item["name"] == "prediction_started":
            if window in starts:
                raise TraceNormalizationError("duplicate prediction_started window")
            starts[window] = item
        else:
            if window not in starts or window in completed:
                raise TraceNormalizationError("prediction_completed lacks one prior start")
            completed.add(window)
    if not starts:
        raise TraceNormalizationError(
            "exit observation has no preceding prediction_started signpost"
        )
    latest_window, latest = max(
        starts.items(), key=lambda item: int(item[1]["timestamp_trace_ns"])
    )
    if latest_window != expected_window_index:
        raise TraceNormalizationError(
            "controller active window does not match latest xctrace prediction start"
        )
    if latest_window in completed:
        raise TraceNormalizationError(
            "matching prediction_completed exists before exit observation"
        )
    older_uncompleted = [
        window for window in starts if window != latest_window and window not in completed
    ]
    if older_uncompleted:
        raise TraceNormalizationError("older prediction window lacks completion")
    return latest


def _overlaps(
    intervals: Iterable[HardwareInterval], lower: int, upper: int
) -> list[HardwareInterval]:
    return [
        interval
        for interval in intervals
        if interval.end_trace_ns > lower and interval.start_trace_ns < upper
    ]


def exclusive_accelerator_event(
    intervals: Iterable[HardwareInterval],
    *,
    role_bracket: str,
    trial_tag: int,
    bracket_owner_pid: int,
) -> dict[str, Any]:
    """Describe a global ANE interval without inventing process attribution."""

    values = list(intervals)
    if not values:
        raise TraceNormalizationError("cannot summarize an empty ANE bracket")
    return {
        "kind": "accelerator_activity",
        "role_bracket": role_bracket,
        "trial_tag": trial_tag,
        "bracket_owner_pid": bracket_owner_pid,
        "start_trace_ns": min(item.start_trace_ns for item in values),
        "end_trace_ns": max(item.end_trace_ns for item in values),
        "compute_route": "ane",
        "attribution_scope": "global_ane_activity_in_exclusive_signpost_bracket",
        "exact_process_attribution": False,
    }


def normalize(
    *,
    trace_path: Path,
    markers_path: Path,
    output_path: Path,
    dry_run: bool = False,
) -> dict[str, Any]:
    trace_path = trace_path.resolve(strict=True)
    markers = _jsonl(markers_path.resolve(strict=True))
    with tempfile.TemporaryDirectory(prefix="dchf-xctrace-export-") as directory:
        root = Path(directory)
        toc_path = root / "toc.xml"
        toc_result = subprocess.run(
            [
                "/usr/bin/xcrun",
                "xctrace",
                "export",
                "--input",
                str(trace_path),
                "--toc",
                "--output",
                str(toc_path),
            ],
            text=True,
            capture_output=True,
        )
        if toc_result.returncode != 0 or not toc_path.is_file():
            raise TraceNormalizationError("xctrace TOC export failed")
        toc_root = ET.parse(toc_path).getroot()
        clock_id = _trace_clock_id(toc_root)

        signpost_path = root / "signposts.xml"
        ane_path = root / "ane.xml"
        mps_path = root / "mps.xml"
        _export(trace_path, "os-signpost", signpost_path)
        _export(trace_path, "ane-hw-intervals-internal", ane_path)
        _export(trace_path, "mps-hw-intervals", mps_path)
        signposts = parse_signposts(signpost_path)
        ane = parse_hardware_intervals(ane_path)
        gpu = parse_hardware_intervals(mps_path)

    events: list[dict[str, Any]] = []
    if dry_run:
        dry_markers = [item for item in markers if item.get("event") == "trace_dry_sigkill_waitpid"]
        if len(dry_markers) != 1:
            raise TraceNormalizationError("dry trace requires one exact SIGKILL/waitpid marker")
        marker = dry_markers[0]
        if int(marker.get("process_return_code", 0)) != -9:
            raise TraceNormalizationError("dry S did not exit via SIGKILL")
        tag = int(marker["trial_tag"])
        speculative_pid = int(marker["speculative_pid"])
        observer_pid = int(marker["observer_pid"])
        start = _one_signpost(
            signposts,
            name="prediction_started",
            pid=speculative_pid,
            trial_tag=tag,
        )
        exit_event = _one_signpost(
            signposts,
            name="speculative_process_exit_observed",
            pid=observer_pid,
            trial_tag=tag,
            speculative_pid=speculative_pid,
        )
        foreground = _one_signpost(
            signposts,
            name="foreground_started",
            pid=observer_pid,
            trial_tag=tag,
        )
        completed = _one_signpost(
            signposts,
            name="foreground_completed",
            pid=observer_pid,
            trial_tag=tag,
        )
        ordered = [
            int(start["timestamp_trace_ns"]),
            int(exit_event["timestamp_trace_ns"]),
            int(foreground["timestamp_trace_ns"]),
            int(completed["timestamp_trace_ns"]),
        ]
        if ordered != sorted(ordered) or len(set(ordered)) != len(ordered):
            raise TraceNormalizationError("dry process-exit/signpost order is not strict")
        events.extend(
            [
                {
                    "kind": "process_exit_observation",
                    "pid": speculative_pid,
                    "signal": 9,
                    "trial_tag": tag,
                    "timestamp_trace_ns": ordered[1],
                    "observation_source": "dispatch_proc_exit",
                    "observer_pid": observer_pid,
                },
                {
                    "kind": "signpost",
                    "pid": observer_pid,
                    "trial_tag": tag,
                    "name": "foreground_started",
                    "timestamp_trace_ns": ordered[2],
                },
            ]
        )
    else:
        kills = [item for item in markers if item.get("event") in KILL_EVENTS]
        if not kills:
            raise TraceNormalizationError("model trace contains no reviewed active kill")
        requests = {
            str(item["trial_id"]): item
            for item in markers
            if item.get("event") == "foreground_request"
            and item.get("arm") in ("dual", "prepare_interruption")
        }
        for marker in kills:
            trial_id = str(marker["trial_id"])
            tag = int(marker["trial_tag"])
            speculative_pid = int(marker["pid"])
            request = requests.get(trial_id)
            if request is None:
                raise TraceNormalizationError(f"{trial_id}: missing F request marker")
            foreground_pid = int(request["pid"])
            start_name = (
                "prepare_started"
                if marker.get("event") == "replacement_prepare_sigkill_waitpid"
                else "prediction_started"
            )
            exit_event = _one_signpost(
                signposts,
                name="speculative_process_exit_observed",
                pid=foreground_pid,
                trial_tag=tag,
                speculative_pid=speculative_pid,
            )
            if start_name == "prediction_started":
                if "active_window_index" not in marker:
                    raise TraceNormalizationError(
                        f"{trial_id}: kill marker lacks exact active window index"
                    )
                speculative_start = active_prediction_signpost(
                    signposts,
                    pid=speculative_pid,
                    trial_tag=tag,
                    expected_window_index=int(marker["active_window_index"]),
                    before_trace_ns=int(exit_event["timestamp_trace_ns"]),
                )
            else:
                speculative_start = _one_signpost(
                    signposts,
                    name=start_name,
                    pid=speculative_pid,
                    trial_tag=tag,
                )
            foreground_start = _one_signpost(
                signposts,
                name="foreground_started",
                pid=foreground_pid,
                trial_tag=tag,
            )
            foreground_completed = _one_signpost(
                signposts,
                name="foreground_completed",
                pid=foreground_pid,
                trial_tag=tag,
            )
            s_lower = int(speculative_start["timestamp_trace_ns"])
            exit_time = int(exit_event["timestamp_trace_ns"])
            f_lower = int(foreground_start["timestamp_trace_ns"])
            f_upper = int(foreground_completed["timestamp_trace_ns"])
            if not s_lower < exit_time < f_lower < f_upper:
                raise TraceNormalizationError(f"{trial_id}: lifecycle signpost chain is not strict")

            is_protocol_containment = (
                marker.get("event") == "replacement_prepare_sigkill_waitpid"
                and marker.get("prepare_stage") == "protocol_containment"
                and marker.get("evidence_scope")
                == "protocol_containment_not_native_coreml_active"
            )
            speculative_ane = _overlaps(ane, s_lower, exit_time)
            ane_after_observation = _overlaps(ane, exit_time, f_lower)
            foreground_ane = _overlaps(ane, f_lower, f_upper)
            if is_protocol_containment:
                if speculative_ane:
                    raise TraceNormalizationError(
                        f"{trial_id}: protocol containment stage unexpectedly overlaps ANE"
                    )
            elif not speculative_ane:
                raise TraceNormalizationError(
                    f"{trial_id}: active speculative bracket contains no ANE activity"
                )
            if any(item.end_trace_ns > exit_time for item in speculative_ane):
                raise TraceNormalizationError(
                    f"{trial_id}: global ANE interval survives kernel exit observation"
                )
            if ane_after_observation:
                raise TraceNormalizationError(
                    f"{trial_id}: ANE activity exists between S exit observation and F"
                )
            if not foreground_ane:
                raise TraceNormalizationError(
                    f"{trial_id}: foreground bracket contains no ANE activity"
                )
            if _overlaps(gpu, s_lower, f_lower) or _overlaps(gpu, f_lower, f_upper):
                raise TraceNormalizationError(f"{trial_id}: MPS/GPU activity overlaps ASR lane")
            if speculative_ane:
                events.append(
                    exclusive_accelerator_event(
                        speculative_ane,
                        role_bracket="speculative",
                        trial_tag=tag,
                        bracket_owner_pid=speculative_pid,
                    )
                )
            events.extend(
                [
                    {
                        "kind": "process_exit_observation",
                        "pid": speculative_pid,
                        "signal": 9,
                        "trial_tag": tag,
                        "timestamp_trace_ns": exit_time,
                        "observation_source": "dispatch_proc_exit",
                        "observer_pid": foreground_pid,
                    },
                    {
                        "kind": "signpost",
                        "pid": foreground_pid,
                        "trial_tag": tag,
                        "name": "foreground_started",
                        "timestamp_trace_ns": f_lower,
                    },
                    exclusive_accelerator_event(
                        foreground_ane,
                        role_bracket="foreground",
                        trial_tag=tag,
                        bracket_owner_pid=foreground_pid,
                    ),
                    {
                        "kind": "prepare_evidence",
                        "trial_tag": tag,
                        "stage": (
                            "protocol_containment"
                            if is_protocol_containment
                            else "in_flight_prediction"
                        ),
                        "global_ane_activity_observed_in_exclusive_bracket": bool(
                            speculative_ane
                        ),
                        "native_coreml_active_proven": False,
                        "timestamp_trace_ns": s_lower,
                    },
                ]
            )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as stream:
        for event in events:
            event["trace_clock_id"] = clock_id
            stream.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
    return {
        "normalized_event_count": len(events),
        "trace_clock_id": clock_id,
        "dry_run": dry_run,
        "cross_clock_numeric_comparisons": 0,
        "process_exit_observation_source": "dispatch_proc_exit",
        "process_exit_timestamp_claim": "kernel_notification_observed_in_F_not_waitpid",
        "accelerator_attribution": "global_ane_activity_in_exclusive_signpost_bracket",
        "exact_process_compute_route_proven": False,
        "output": str(output_path),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--markers", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    try:
        report = normalize(
            trace_path=arguments.trace,
            markers_path=arguments.markers,
            output_path=arguments.output,
            dry_run=arguments.dry_run,
        )
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}, sort_keys=True))
        return 1
    print(json.dumps({"ok": True, "report": report}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
