#!/usr/bin/env python3
"""Turn first-word-onset JSONL runs into the result tables (numbers only)."""

import json
import statistics
import sys
from collections import defaultdict


def quantile(values, q):
    values = sorted(values)
    if not values:
        return float("nan")
    position = (len(values) - 1) * q
    low = int(position)
    high = min(low + 1, len(values) - 1)
    return values[low] + (values[high] - values[low]) * (position - low)


def fmt(value, digits=0):
    return "–" if value != value else f"{value:.{digits}f}"


def gap_label(gap):
    return {0.5: "quick (0.5 s)", 3.0: "cold (3 s)", 15.0: "idle (15 s)"}.get(gap, f"{gap:g} s")


def main(paths):
    runs, trials, breakdown, profiles, rooms = [], [], [], [], []
    for path in paths:
        with open(path) as handle:
            for line in handle:
                row = json.loads(line)
                {"run": runs, "trial": trials, "breakdown": breakdown, "profile": profiles, "room": rooms}[row["kind"]].append(row)

    for run in runs:
        if "calibration_scores" not in run and run.get("mode") != "profile":
            continue
        print(
            f"Run: {run['device_class']} mic at {run['input_rate']:.0f} Hz, "
            f"speaker-to-mic latency {run['output_latency_ms']:.2f} ms "
            f"(spread {max(run['calibration_ms']) - min(run['calibration_ms']):.2f} ms), "
            f"input timestamp jitter {run['timestamp_jitter_ms']:.3f} ms."
        )
    print()

    played = [t for t in trials if t["playback"]]
    # Another process holding the microphone makes a start warm; those takes
    # measure that process, not this one.
    busy = [t for t in played if t.get("device_busy_at_rest")]
    played = [t for t in played if not t.get("device_busy_at_rest")]
    valid = [t for t in played if t.get("valid")]
    invalid = len(played) - len(valid)
    by_class = defaultdict(list)
    for t in valid:
        by_class[t["device_class"]].append(t)

    for device, rows in by_class.items():
        print(f"### First-word capture, {device} mic ({len(rows)} valid takes, {invalid} invalid)")
        print()
        if busy:
            print(f"{len(busy)} takes found the microphone already running in another process and are left out.")
            print()
        gaps = sorted({t["gap_s"] for t in rows})
        onsets = sorted({t["onset_ms"] for t in rows})
        print("| Speech starts after key-down | " + " | ".join(gap_label(g) for g in gaps) + " | Lost, median (max) |")
        print("|---|" + "---|" * (len(gaps) + 1))
        for onset in onsets:
            cells = []
            for gap in gaps:
                group = [t for t in rows if t["gap_s"] == gap and t["onset_ms"] == onset]
                if group:
                    captured = sum(t["captured"] for t in group)
                    cells.append(f"{captured}/{len(group)}")
                else:
                    cells.append("–")
            lost = [t["lost_ms"] for t in rows if t["onset_ms"] == onset]
            print(
                f"| {onset} ms | " + " | ".join(cells)
                + f" | {fmt(statistics.median(lost))} ms ({fmt(max(lost))} ms) |"
            )
        print()

        print("| Start | Takes | Key-down to first live sample p50 / p90 / max | Red dot (start returns) p50 | First frame delivered p50 |")
        print("|---|---|---|---|---|")
        for gap in gaps:
            group = [t for t in rows if t["gap_s"] == gap]
            dead = [t["dead_ms"] for t in group]
            print(
                f"| {gap_label(gap)} | {len(group)} | "
                f"{fmt(quantile(dead, .5))} / {fmt(quantile(dead, .9))} / {fmt(max(dead))} ms | "
                f"{fmt(quantile([t['start_return_ms'] for t in group], .5))} ms | "
                f"{fmt(quantile([t['first_frame_ms'] for t in group], .5))} ms |"
            )
        early = [t["dead_ms"] - t["start_return_ms"] for t in rows]
        print()
        print(
            f"Audio goes live {fmt(quantile(early, .5), 1)} ms after `startRecording` returns "
            f"(p10 {fmt(quantile(early, .1), 1)}, p90 {fmt(quantile(early, .9), 1)} ms); "
            "the red dot appears when it returns."
        )
        zeros = [t["zero_lead_ms"] for t in rows]
        print(f"Leading digital zeros in a take: median {fmt(statistics.median(zeros), 1)} ms, max {fmt(max(zeros), 1)} ms.")
        fades = [k for k in ("fade_db_0_25", "fade_db_25_50", "fade_db_50_100", "fade_db_100_200")
                 if any(k in t for t in rows)]
        if fades:
            print()
            print("Level just after the first live sample, against the rest of the captured speech (dB, both relative to the clean clip):")
            print()
            print("| Window after first live sample | Takes | Median | p10 | p90 |")
            print("|---|---|---|---|---|")
            for key in fades:
                values = [t[key] for t in rows if key in t]
                window = key.removeprefix("fade_db_").replace("_", "–")
                print(f"| {window} ms | {len(values)} | {fmt(statistics.median(values), 1)} | "
                      f"{fmt(quantile(values, .1), 1)} | {fmt(quantile(values, .9), 1)} |")
        print()

    silent = [t for t in trials if not t["playback"] and not t.get("device_busy_at_rest")]
    if silent:
        cold = [t for t in played if t["gap_s"] == 3.0]
        print("### Control: speakers stopped (no playback I/O)")
        print()
        print("| Condition | Takes | Red dot (start returns) p50 | First frame delivered p50 |")
        print("|---|---|---|---|")
        for label, group in (("speakers running, cold", cold), ("speakers stopped, cold", silent)):
            print(
                f"| {label} | {len(group)} | "
                f"{fmt(quantile([t['start_return_ms'] for t in group], .5))} ms | "
                f"{fmt(quantile([t['first_frame_ms'] for t in group], .5))} ms |"
            )
        print()

    if profiles:
        summarize_profiles(profiles)

    if rooms:
        busy = [r for r in rooms if r.get("device_busy_at_rest")]
        rows = [r for r in rooms if not r.get("device_busy_at_rest")]
        print("### Room level through MicrophoneCapture, no sound played")
        print()
        if busy:
            print(f"{len(busy)} takes found the microphone already running in another process and are left out.")
            print()
        print("| Start | Takes | startRecording returns p50 | Take's first sample to room level within 20 dB, p50 / p90 | Key-down to room level within 20 dB, p50 / p90 |")
        print("|---|---|---|---|---|")
        for gap in sorted({r["gap_s"] for r in rows}):
            g = [r for r in rows if r["gap_s"] == gap]
            a = [r["settled_20db_after_first_sample_ms"] for r in g]
            b = [r["settled_20db_ms"] for r in g]
            print(f"| {gap_label(gap)} | {len(g)} | {fmt(quantile([r['start_return_ms'] for r in g], .5))} ms | "
                  f"{fmt(quantile(a, .5))} / {fmt(quantile(a, .9))} ms | {fmt(quantile(b, .5))} / {fmt(quantile(b, .9))} ms |")
        print()
        print("Median level against the settled room level, 20 ms windows from the take's first sample (dB):")
        print()
        print("| " + " | ".join(str(t) for t in range(0, 300, 20)) + " |")
        print("|" + "---|" * 15)
        print("| " + " | ".join(fmt(statistics.median(r["level_db_from_first_sample"][t // 10] for r in rows)) for t in range(0, 300, 20)) + " |")
        print()

    if breakdown:
        # A start is cold only if nothing else held the device open. The
        # lingering path holds it open on purpose, so it is never excluded.
        busy = [r for r in breakdown if r.get("running_at_rest") and r["path"] != "avaudioengine-lingering"]
        cold = [r for r in breakdown if r not in busy]
        print("### Where the start-up time goes (ms after the start call, p50)")
        print()
        if busy:
            print(f"{len(busy)} starts found the device already running (another process) and are left out.")
            print()
        keys = [
            ("input_node_ms", "inputNode / unit"),
            ("tap_ms", "installTap"),
            ("prepare_ms", "prepare / initialize"),
            ("start_return_ms", "start returns"),
            ("first_live_ms", "first live sample"),
            ("first_callback_ms", "first callback"),
            ("settled_20db_ms", "room level within 20 dB"),
            ("settled_10db_ms", "within 10 dB"),
        ]
        groups = defaultdict(list)
        for row in cold:
            groups[(row["device_class"], row["path"], row["gap_s"])].append(row)
        print("| Mic | Path | Gap | n | " + " | ".join(label for _, label in keys) + " | first live p90 |")
        print("|---|---|---|---|" + "---|" * (len(keys) + 1))
        for (device, path, gap), group in sorted(groups.items()):
            cells = []
            for key, _ in keys:
                values = [r[key] for r in group if key in r and r[key] >= 0]
                cells.append(fmt(quantile(values, .5), 1) if values else "–")
            live = [r["first_live_ms"] for r in group if r["first_live_ms"] >= 0]
            print(f"| {device} | {path} | {gap:g} s | {len(group)} | " + " | ".join(cells)
                  + f" | {fmt(quantile(live, .9), 1)} |")
        print()
        idle = [r for r in cold if "idle_device_running" in r]
        if idle:
            print(
                f"A graph built before the key-down left the device running while idle in "
                f"{sum(r['idle_device_running'] for r in idle)} of {len(idle)} starts, and this process "
                f"reported input running while idle in {sum(r['idle_process_input'] for r in idle)} "
                f"(after start: {sum(r['live_process_input'] for r in idle)})."
            )
            print()


def summarize_profiles(profiles, label=""):
    busy = [p for p in profiles if p.get("device_busy_at_rest")]
    rows = [p for p in profiles if p.get("valid") and not p.get("device_busy_at_rest")]
    if not rows:
        return
    print(f"### When the take hears the room at full level{label} (ms after key-down)")
    print()
    if busy:
        print(f"{len(busy)} takes found the microphone already running in another process and are left out.")
        print()
    print("| Start | Takes | First non-zero sample p50 | Within 20 dB p50 / p90 | Within 10 dB p50 / p90 | Within 3 dB p50 / p90 |")
    print("|---|---|---|---|---|---|")
    for gap in sorted({p["gap_s"] for p in rows}):
        group = [p for p in rows if p["gap_s"] == gap]
        cells = []
        for key in ("settled_20db_ms", "settled_10db_ms", "settled_3db_ms"):
            values = [p[key] for p in group]
            cells.append(f"{fmt(quantile(values, .5))} / {fmt(quantile(values, .9))}")
        print(f"| {gap_label(gap)} | {len(group)} | {fmt(quantile([p['first_live_ms'] for p in group], .5))} | " + " | ".join(cells) + " |")
    print()
    print("Median level against the settled level, by 20 ms window after key-down (dB; -200 is nothing captured):")
    print()
    print("| " + " | ".join(f"{t}" for t in range(0, 400, 40)) + " |")
    print("|" + "---|" * 10)
    medians = []
    for t in range(0, 400, 40):
        i = t // 10
        medians.append(statistics.median(max(p["level_db"][i], p["level_db"][i + 1]) for p in rows))
    print("| " + " | ".join(fmt(m) for m in medians) + " |")
    print()


if __name__ == "__main__":
    main(sys.argv[1:])
