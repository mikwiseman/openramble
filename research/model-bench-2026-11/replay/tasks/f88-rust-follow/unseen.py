#!/usr/bin/env python3
"""Sentences no model was shown, for the task r88-conjunction.

The change that shipped was held to more than its tests. Its authors generated
sentences of one shape, a clause, a joining word, a hesitation and a second
clause that says the object again ("We shipped it and, um, it works."), and
counted the ones that lost a word. That sweep lived outside the repository, in
cv-notes/conj/sweep.py, and no test holds it.

The grader runs this file in the folder of a change that passed the tests. It
prints one line, and it exits 1 when the Swift pipeline loses a real word in
any sentence or the Rust port writes something else for one.
"""
import itertools
import json
import re
import subprocess
import sys
from collections import Counter

FIXTURE = "core/conformance/fixtures/text/pipeline.json"
STRIP = ".,;:!?…\"'”’»)]([«“‘"
FILLERS = {"uh", "um", "er", "hmm", "э", "ээ", "эм"}

ENGLISH = (["We shipped {o}", "So we, uh, shipped {o}", "I asked {o}", "Okay, we tested {o}", "They moved {o}"],
           ["it", "them", "him", "you", "this", "that", "the server", "Sam", "the docs"],
           ["and", "or", "but", "so", "because", "if", "when", "that", "than", "then", "which", "who",
            "to", "of", "in", "on", "at", "for", "with", "from", "by", "into", "about"],
           ["{o} works.", "{o} is ready.", "{o} should be fine.", "{o} said yes."], ["um", "uh", "er"])
RUSSIAN = (["Мы сделали {o}", "Я проверил {o}", "Ну, мы купили {o}"], ["это", "его", "их", "ему", "сервер"],
           ["и", "или", "а", "но", "что", "чтобы", "если", "когда", "как", "в", "на", "с", "к", "по", "для"],
           ["{o} работает.", "{o} уже привезли."], ["э", "ээ", "эм"])
SHAPES = ["{j}, {f}, {t}", "{j} {f}, {t}", "{j}, {f} {t}", "{j} {f} {t}"]


def words(text):
    return [w.strip(STRIP).lower() for w in text.split()]


def sweep(restarts=False):
    """Every word of these sentences is real. The one exception is an object
    that is also the joining word ("shipped that that, um, that works"), which
    is a restart, so those 240 are left out unless asked for."""
    for heads, objects, joins, tails, fills in (ENGLISH, RUSSIAN):
        for h, o, j, t, f, s in itertools.product(heads, objects, joins, tails, fills, SHAPES):
            if restarts or o != j:
                yield h.format(o=o) + " " + s.format(j=j, f=f, t=t.format(o=o))


def lost_a_word(said, cleaned):
    return bool(Counter(w for w in words(said) if w not in FILLERS) - Counter(words(cleaned)))


def main():
    said = list(sweep())
    with open("unseen.json", "w") as corpus:
        json.dump([{"name": f"s{i}", "dictionary": [], "allowPressReturnCommand": False, "phoneticMatching": True,
                    "input": text} for i, text in enumerate(said)], corpus, ensure_ascii=False)
    subprocess.run("swift build --package-path core/conformance/generator && "
                   f"core/conformance/generator/.build/debug/GenerateFixtures unseen.json {FIXTURE}",
                   shell=True, check=True)
    with open(FIXTURE) as written:
        cleaned = {f["name"]: f["text"] for f in json.load(written)}
    lost = sum(lost_a_word(text, cleaned[f"s{i}"]) for i, text in enumerate(said))

    # The same sentences through the Rust port, which replays what Swift wrote.
    rust = subprocess.run("cargo test -p ramble-text --test conformance", shell=True, capture_output=True, text=True)
    print(rust.stdout[-3000:], rust.stderr[-3000:], sep="\n")
    differs = len(set(re.findall(r"^(s\d+): (?:text|command|afterDictionary|spans)$", rust.stdout + rust.stderr, re.M)))
    if (rust.returncode != 0) != (differs > 0):
        print("the Rust port did not run on the unseen sentences")
        sys.exit(1)

    said_it = (f"{lost:,} of {len(said):,} unseen sentences lost a real word" if lost
               else f"no real word lost in {len(said):,} unseen sentences")
    if differs:
        said_it += f", and the Rust port differs from Swift on {differs:,}"
    print(said_it)
    sys.exit(1 if lost or differs else 0)


if __name__ == "__main__":
    main()
