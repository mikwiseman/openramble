#!/usr/bin/env python3
"""Lines no model was shown, for the task r39-clipboard-gate.

The grader's own test plants one plain clearContents() in one file. The gate
that shipped stops more than that line: both calls that start a clipboard
write past .currentHostOnly, in every folder of shipping code. It also lets
through what the script says it must let through: a comment that explains the
rule, the allowed call, and test code.

The grader runs this file in the folder of a change that passed the tests. It
plants each line below in a file of its own, runs the gate, and holds the
answer against the answer of the gate that shipped. It prints one line and
exits 1 when any answer differs.
"""
import subprocess
import sys
from pathlib import Path

GATE = "./scripts/check-network-surface.sh"
CORE = "Packages/DictationCore/Sources/DictationCore"
AUDIO = "Packages/DictationCore/Sources/DictationAudio"
ASR = "Packages/LocalASR/Sources/LocalASR"
APP = "apps/macos/OpenRamble/System"
VIEWS = "apps/macos/OpenRamble/UI"
TESTS = "Packages/DictationCore/Tests/DictationCoreTests"

# What is planted, where, the line, and whether the gate that shipped stops it.
PLANTS = [
    ("clearContents()", CORE, "    NSPasteboard.general.clearContents()", True),
    ("clearContents()", ASR, "    NSPasteboard.general.clearContents()", True),
    ("clearContents()", APP, "        pasteboard.clearContents()", True),
    ("clearContents()", VIEWS, "    let count = board.clearContents() // start a new write", True),
    ("declareTypes(", CORE, "    pasteboard.declareTypes([.string], owner: nil)", True),
    ("declareTypes(", AUDIO, "    pasteboard.declareTypes([.string], owner: nil)", True),
    ("declareTypes(", ASR, "    NSPasteboard.general.declareTypes([.string, .rtf], owner: self)", True),
    ("declareTypes(", APP, "        _ = board.declareTypes([.string], owner: nil)", True),
    ("a network call", APP, "    let session = URLSession.shared", True),
    ("a logged transcript", CORE, '    logger.info("heard \\(transcript)")', True),
    ("a comment about the rule", APP, "    // A plain clearContents() would hand dictation to Universal Clipboard.", False),
    ("a comment about the rule", CORE, "    /// Never call declareTypes(_:owner:) here.", False),
    ("the allowed call", APP, "    pasteboard.prepareForNewContents(with: .currentHostOnly)", False),
    ("test code", TESTS, "    NSPasteboard.general.clearContents()", False),
]


def gate():
    done = subprocess.run(GATE, shell=True, capture_output=True, text=True)
    return done.returncode != 0, done.stdout + done.stderr


def main():
    stopped, said = gate()
    if stopped:
        print(said[-2000:])
        print("the gate is red before anything is planted")
        sys.exit(1)
    missed, alarms = [], []
    for number, (what, folder, line, shipped_stops) in enumerate(PLANTS):
        planted = Path(folder) / f"BenchUnseen{number}.swift"
        planted.write_text(f"import AppKit\n\nfunc benchUnseen{number}() {{\n{line}\n}}\n")
        try:
            stopped, said = gate()
        finally:
            planted.unlink()
        # Red for another reason is not an answer about this line.
        stopped = stopped and planted.name in said
        print(f"{'stopped' if stopped else 'let through'}  {planted}: {line.strip()}")
        if shipped_stops and not stopped:
            missed.append(what)
        if stopped and not shipped_stops:
            alarms.append(what)
    stops = sum(1 for plant in PLANTS if plant[3])
    parts = []
    if missed:
        parts.append(f"the gate lets through {', '.join(dict.fromkeys(missed))}: {len(missed)} of {stops} "
                     "planted lines that the shipped gate stops")
    if alarms:
        parts.append(f"the gate stops {', '.join(dict.fromkeys(alarms))}: {len(alarms)} of {len(PLANTS) - stops} "
                     "planted lines that the shipped gate lets through")
    print(", and ".join(parts) if parts else f"the gate answers all {len(PLANTS)} unseen planted lines as the shipped gate does")
    sys.exit(1 if parts else 0)


if __name__ == "__main__":
    main()
