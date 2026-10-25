"""Turn repro.py output into the tables in README.md.

    python3 -I summarize.py data/pressure.jsonl
"""
import json, statistics, sys

rows = []
for line in open(sys.argv[1]):
    trial = json.loads(line)
    if trial["aborted"]:
        print("aborted trial at", trial["start"], "-", trial["aborted"])
        continue
    for position, take in enumerate(trial["takes"], 1):
        lane = take["lane"]
        steady = trial[lane + "Steady"]["diskReadBytes"]
        warmed = take.get("warmed") or {}
        idle = take["warmReply"]["idleSeconds"] if "warmReply" in take else take["take"]["idleSeconds"]
        rows.append({
            "trial": trial["start"], "position": position, "lane": lane,
            "after": lane.startswith("after"),
            "idle": idle,
            "rssMB": take["rssMBBefore"],
            "wait": take["take"]["wallSeconds"],
            "engine": take["take"]["engineSeconds"],
            "readMB": (take["take"]["diskReadBytes"] - steady) / 1e6,
            "warm": warmed.get("seconds"),
            "warmMB": (warmed["diskReadBytes"] - take["warmReply"]["diskReadBytes"]) / 1e6 if warmed else None,
        })

fmt = lambda v, d=2: "–" if v is None else f"{v:.{d}f}"
print("| Trial | # | Lane | Idle s | RSS MB | Warm-up s | Key-up → text s | Take engine s | Read during take MB |")
print("|---|---:|---|---:|---:|---:|---:|---:|---:|")
for r in rows:
    print(f"| {r['trial']} | {r['position']} | {r['lane']} | {r['idle']:.0f} | {r['rssMB']} | {fmt(r['warm'])} "
          f"| {r['wait']:.2f} | {r['engine']:.2f} | {r['readMB']:.0f} |")

print()
print("| Condition | Takes | Median key-up → text s | Max s | Median read MB |")
print("|---|---:|---:|---:|---:|")
for name, after in (("0.33.1: page-in after key-up", False), ("This change: warm-up at key-down", True)):
    group = [r for r in rows if r["after"] == after]
    if not group:
        continue
    waits = [r["wait"] for r in group]
    print(f"| {name} | {len(group)} | {statistics.median(waits):.2f} | {max(waits):.2f} "
          f"| {statistics.median(r['readMB'] for r in group):.0f} |")
