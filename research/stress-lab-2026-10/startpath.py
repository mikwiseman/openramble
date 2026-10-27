"""Where key-down → first audio went, take by take.

    python3 -I startpath.py data/first-take/main-takes.jsonl data/first-take/fixed-takes.jsonl

Each column is milliseconds after the key went down: when the key-down's own
main-thread work returned, when the start lane began and finished opening the
device, when the device start began and returned, and when the first buffer
reached the capture. Words spoken before "device started" are lost; the
built-in microphone then needs about 180 ms more before the room is audible.
"""
import json, statistics, sys

fields = ["mainThread", "openBegan", "openEnded", "startBegan", "startEnded", "firstBuffer"]
print("| Build | Condition | # | Main thread returned | Open began | Open ended | Start began | Device started | First buffer | Words missed | Load |")
print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
groups = {}
for path in sys.argv[1:]:
    for line in open(path):
        r = json.loads(line)
        p = r.get("startPath") or {}
        cells = " | ".join("–" if p.get(f) is None else f"{p[f]:.0f}" for f in fields)
        print(f"| {r['label']} | {r['condition']} | {r['index']} | {cells} | {r.get('wordsMissed')} | {r['loadAverage']:.0f} |")
        if p.get("startEnded") is not None:
            groups.setdefault((r["label"], r["condition"]), []).append(p["startEnded"])

print()
print("| Build | Condition | Takes | Key-down → device started, median | Max |")
print("|---|---|---:|---:|---:|")
for (label, condition), values in groups.items():
    print(f"| {label} | {condition} | {len(values)} | {statistics.median(values):.0f} | {max(values):.0f} |")
