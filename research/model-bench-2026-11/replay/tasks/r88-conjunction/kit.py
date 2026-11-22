#!/usr/bin/env python3
"""The whole kit the shipped change was measured on, for r88-conjunction.

The kit lives outside the repository, in cv-notes: 720 judged sentences, 62
traps, a probe of 28, and the sweep. The grader holds a change to the sweep
alone, with unseen.py, because the sweep is the one part that needs no file
from outside. This runs the rest once, to see what the rest can tell apart:
the parent, the change that shipped and every graded change, in the Swift
pipeline and in the Rust port.

    replay/tasks/r88-conjunction/kit.py     writes results/replay/_tasks/r88-conjunction/kit.json
"""
import importlib.machinery
import importlib.util
import json
import os
import re
import sys
import time
from collections import Counter
from difflib import SequenceMatcher
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from unseen import FIXTURE, lost_a_word, sweep, words  # noqa: E402

loader = importlib.machinery.SourceFileLoader("bench", str(HERE.parents[2] / "bench"))
bench = importlib.util.module_from_spec(importlib.util.spec_from_loader("bench", loader))
loader.exec_module(bench)

KIT = Path(os.environ.get("BENCH_CV_NOTES", Path.home() / "Documents/Code/openramble-worktrees/cv-notes"))
TASK = bench.Task(HERE.name)
OUT = bench.RESULTS / "replay/_tasks" / TASK.id / "kit.json"


def sentences():
    """Every sentence as (set, what was said, what a judge wants or None, corrections)."""
    found = []
    for name in ("gold", "fresh", "holdout2"):
        for item in json.loads((KIT / f"gold/{name}.json").read_text())["kept"]:
            found.append(("judged", item["input"], item["gold"], True))
    for name in ("r9", "r9b"):
        found += [("traps", said, want, True) for said, want in json.loads((KIT / f"adversarial/{name}.json").read_text())]
    probe = json.loads((KIT / "conj/probe.json").read_text())
    found += [("probe", said, want, True) for said, want in probe]
    found += [("probe, corrections off", said, want, False) for said, want in probe]
    # With the 240 restarts, as its authors ran it.
    found += [("sweep", said, None, True) for said in sweep(restarts=True)]
    return found


def run(patch, cases, log):
    """What the Swift pipeline writes for every sentence, and the names of the
    sentences where the Rust port writes something else."""
    folder, _, problem = bench.materialize(TASK, patch, "kit")
    if problem:
        sys.exit(problem)
    (folder / "kit.json").write_text(json.dumps(cases, ensure_ascii=False))
    built = bench.sh("swift build --package-path core/conformance/generator && "
                     f"core/conformance/generator/.build/debug/GenerateFixtures kit.json {FIXTURE}", folder, log)
    if not built["ok"]:
        sys.exit(f"the Swift pipeline did not run, see {log}")
    swift = {f["name"]: f["text"] for f in json.loads((folder / FIXTURE).read_text())}
    if len(swift) != len(cases):
        sys.exit(f"{len(swift)} answers for {len(cases)} sentences")
    before = log.stat().st_size
    ported = bench.sh("cargo test -p ramble-text --test conformance", folder, log)
    with open(log, "rb") as text:
        text.seek(before)
        said = text.read().decode(errors="replace")
    differs = sorted(set(re.findall(r"^(s\d+): (?:text|command|afterDictionary|spans)$", said, re.M)))
    if ported["ok"] == bool(differs) or (ported["ok"] and "1 passed" not in said):
        sys.exit(f"the Rust port did not run, see {log}")
    return swift, differs


def main():
    found = sentences()
    cases = [{"name": f"s{i}", "dictionary": [], "allowPressReturnCommand": False, "phoneticMatching": True,
              "spokenCorrections": corrections, "input": said}
             for i, (_, said, _, corrections) in enumerate(found)]
    patches = {"parent": b"", "shipped": TASK.reference_patch()}
    for folder in sorted((bench.RESULTS / "replay").glob(f"{TASK.id}.*")):
        if json.loads((folder / "grade.json").read_text()).get("state") in ("pass", "partial"):
            patches[folder.name.split(".")[1]] = (folder / "change.patch").read_bytes()
    log = bench.WORK / "kit.log"
    log.unlink(missing_ok=True)
    answers, ported = {}, {}
    for who, patch in patches.items():
        started = time.monotonic()
        answers[who], ported[who] = run(patch, cases, log)
        bench.say(f"[kit] {who}: {len(answers[who])} sentences in {time.monotonic() - started:.0f} s")

    result = {"date": time.strftime("%Y-%m-%d %H:%M"), "kit": "cv-notes: gold, fresh, holdout2, adversarial r9 and r9b, "
              "conj/probe.json, and the generator of conj/sweep.py", "sets": dict(Counter(s for s, *_ in found)),
              "changes": {}}
    for who in patches:
        sets, differs = {}, []
        for i, (name, said, want, _) in enumerate(found):
            got = answers[who][f"s{i}"]
            row = sets.setdefault(name, Counter(n=0))
            row["n"] += 1
            if want is None:
                row["lost_a_word"] += lost_a_word(said, got)
            else:
                row["as_judged"] += " ".join(got.split()) == " ".join(want.split())
                moves = SequenceMatcher(a=words(want), b=words(got), autojunk=False).get_opcodes()
                lost = sum(i2 - i1 for tag, i1, i2, _, _ in moves if tag in ("delete", "replace"))
                row["lost_a_word"] += lost > 0
                row["words_lost"] += lost
            if got != answers["shipped"][f"s{i}"]:
                differs.append({"set": name, "said": said, "shipped": answers["shipped"][f"s{i}"], "this": got,
                                **({"judge": want} if want else {})})
        result["changes"][who] = {
            "sets": {name: dict(row) for name, row in sets.items()},
            "differs_from_shipped": dict(Counter(d["set"] for d in differs)),
            # The sweep's differences number in the thousands and repeat one shape.
            "differences": [d for d in differs if d["set"] != "sweep"] + [d for d in differs if d["set"] == "sweep"][:12],
            "rust_differs_from_swift": len(ported[who]),
        }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n")

    for who, change in result["changes"].items():
        sets = change["sets"]
        judged = ", ".join(f"{name} {row.get('as_judged', 0)}/{row['n']} ({row.get('lost_a_word', 0)} lost a word)"
                           for name, row in sets.items() if name != "sweep")
        bench.say(f"{who:8s} {judged}, sweep {sets['sweep'].get('lost_a_word', 0)}/{sets['sweep']['n']} lost a word, "
                  f"differs from shipped {sum(change['differs_from_shipped'].values())}, "
                  f"Rust differs from Swift {change['rust_differs_from_swift']}")


if __name__ == "__main__":
    main()
