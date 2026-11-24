#!/usr/bin/env python3
"""Presses no model was shown, for the task r97-handsfree-stop.

The real change's storm runs 200 seeds, and whether a press falls inside a
finishing paste is left to timing. unseen.swift, which lies beside this file,
places every run of up to three presses inside one finishing paste on purpose,
400 in all, and runs 300 storms with seeds and lengths nobody ran. Each must
keep what the storm promises: the microphone off, and the next dictation
working.

The grader runs this file in the folder of a change that passed the tests. It
prints one line and exits 1 when any sequence or storm fails. A storm depends
on timing, so red storms are run once more and count when both runs are red.
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

TARGET = Path("Packages/DictationCore/Tests/DictationCoreTests/BenchUnseenTests.swift")


def run(test, name):
    """How many of the cases failed, how many ran, and the first failure."""
    done = subprocess.run(f"swift test --package-path Packages/DictationCore --filter 'BenchUnseenTests/{test}'",
                          shell=True, capture_output=True, text=True)
    said = done.stdout + done.stderr
    print(said[-4000:])
    count = re.search(rf"^UNSEEN {name} (\d+) of (\d+)$", said, re.M)
    if not count:
        print("the unseen presses did not run")
        sys.exit(1)
    first = re.search(rf"^UNSEEN-FAIL {name} (.*)$", said, re.M)
    return int(count[1]), int(count[2]), first[1] if first else ""


def main():
    shutil.copy(Path(__file__).with_suffix(".swift"), TARGET)
    parts = []
    failed, total, first = run("testPressesInsideAFinishingPaste", "paste")
    if failed:
        parts.append(f"{failed} of {total} unseen press sequences inside a finishing paste failed, first {first}")
    failed, total, first = run("testStormsWithSeedsNobodyRan", "storm")
    if failed and run("testStormsWithSeedsNobodyRan", "storm")[0]:
        parts.append(f"{failed} of {total} unseen gesture storms failed, first {first}")
    print(", and ".join(parts) if parts else "every unseen press sequence and storm leaves the microphone off")
    sys.exit(1 if parts else 0)


if __name__ == "__main__":
    main()
