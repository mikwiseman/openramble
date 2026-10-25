"""Side-by-side tables from stress-lab take journals.

    python3 -I summarize.py data/main-takes.jsonl data/fixed-takes.jsonl

One row per label, condition and take shape. Times are milliseconds; p50 and
p95 interpolate between takes. "Lost frames" are device cycles the capture
never received; "stalls" are main-thread gaps over 100 ms between key-down
and the text landing.
"""
import json, sys


def percentile(values, p):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    rank = p * (len(values) - 1)
    low, high = int(rank), min(int(rank) + 1, len(values) - 1)
    return values[low] + (values[high] - values[low]) * (rank - low)


def fmt(value):
    return "–" if value is None else f"{value:.0f}"


def pair(values):
    return f"{fmt(percentile(values, 0.5))} / {fmt(percentile(values, 0.95))}"


rows = []
for path in sys.argv[1:]:
    rows += [json.loads(line) for line in open(path)]

conditions = []
for r in rows:
    if r["condition"] not in conditions:
        conditions.append(r["condition"])

print("| Condition | Take | Build | n | Landed | Words missed | Release → paste p50 / p95 | Release → target read p50 / p95 "
      "| Key-down → first audio p50 / p95 | Engine p50 / p95 | Lost frames (takes) | Stalls > 100 ms | Longest stall |")
print("|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for condition in conditions:
    for take in ("short", "long"):
        for label in dict.fromkeys(r["label"] for r in rows):
            group = [r for r in rows if r["condition"] == condition and r["take"] == take and r["label"] == label]
            if not group:
                continue
            lost = [r.get("deviceFramesLost") or 0 for r in group]
            print(f"| {condition} | {take} | {label} | {len(group)} | {sum(r['landed'] for r in group)} "
                  f"| {sum(r.get('wordsMissed') or 0 for r in group)} "
                  f"| {pair([r.get('releaseToPaste') for r in group])} "
                  f"| {pair([r.get('releaseToRead') for r in group])} "
                  f"| {pair([r.get('keyDownToFirstAudio') for r in group])} "
                  f"| {pair([r.get('engine') for r in group])} "
                  f"| {sum(lost)} ({sum(1 for x in lost if x)}) "
                  f"| {sum(r['mainThreadStallsOver100'] for r in group)} "
                  f"| {fmt(max(r['mainThreadLongestStall'] for r in group))} |")
