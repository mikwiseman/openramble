"""Takes that lost device audio, by how the capture handed cycles over.

    python3 -I losses.py

Every run in data/, grouped by design: the dispatch queue the HAL waited on
(0.33.1, and the warm-up-only build), or the ring the real-time thread copies
into. explore-1 kept only its last conditions' rows (its journal was truncated
per run; its full tables are in explore-1/run-log.txt).
"""
import json, pathlib

designs = {
    "queue": ["explore-1/main", "explore-1/branch-1", "explore-2/main-b", "explore-3/main-c", "final/0.33.1"],
    "ring": ["explore-2/ring-b", "explore-3/primed-c", "final/fixed"],
}
root = pathlib.Path(__file__).parent / "data"
print("| Capture | Condition | Takes | Takes with lost audio | Audio lost, ms | Gap between device cycles on those takes, ms | Hand-off delay, ms | Load |")
print("|---|---|---:|---:|---:|---:|---:|---:|")
for design, runs in designs.items():
    rows = []
    for run in runs:
        path = root / f"{run}-takes.jsonl"
        if path.exists():
            rows += [json.loads(line) for line in path.open()]
    for condition in ("quiet", "cpu", "memory", "both", "idle"):
        group = [r for r in rows if r["condition"] == condition]
        if not group:
            continue
        losing = [r for r in group if r.get("deviceFramesLost")]
        lost_ms = sum(r["deviceFramesLost"] for r in losing) / 48
        gaps = ", ".join(f"{r['deviceLongestCallbackGap']:.0f}" for r in losing if r.get("deviceLongestCallbackGap"))
        delays = ", ".join(f"{r['deviceLongestDelivery']:.0f}" for r in losing if r.get("deviceLongestDelivery"))
        loads = ", ".join(f"{r['loadAverage']:.0f}" for r in losing)
        print(f"| {design} | {condition} | {len(group)} | {len(losing)} | {lost_ms:.0f} | {gaps or '–'} | {delays or '–'} | {loads or '–'} |")

# One skipped cycle — the device waited 22-26 ms instead of 10.7 — is the
# signature of the queue being late; a longer gap is the device's own
# real-time thread being late, which no hand-off can prevent.
print()
print("| Capture | Losses of one cycle (gap < 30 ms) | Longer losses (gap ≥ 30 ms) | Losses in the first 100 ms of a take |")
print("|---|---:|---:|---:|")
for design, runs in designs.items():
    rows = []
    for run in runs:
        path = root / f"{run}-takes.jsonl"
        if path.exists():
            rows += [json.loads(line) for line in path.open()]
    losing = [r for r in rows if r.get("deviceFramesLost") and r.get("deviceLongestCallbackGap")]
    short = sum(1 for r in losing if r["deviceLongestCallbackGap"] < 30)
    early = sum(1 for r in losing if (r.get("deviceFirstLossAt") or 1e9) < 100)
    print(f"| {design} | {short} | {len(losing) - short} | {early} |")
