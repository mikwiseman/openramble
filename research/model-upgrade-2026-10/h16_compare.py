"""H16 rule 1 and the transcript differences: python3 -I h16_compare.py [OUT.json]

Compares, suite by suite, the committed observations of three candidates:
runtime-0.4.1 against runtime-main-ultra-q4km (H15's upstream build; rule 1
wants every transcript identical) and app-0.34.0 against runtime-0.4.1 (what
changes for people). Texts are compared exactly, as returned by the engine.
"""
import gzip
import json
import sys
from pathlib import Path

RESULTS = Path(__file__).resolve().parents[1] / 'scorecard/results'
SUITES = ('fleurs', 'fleurs-full', 'noise', 'takes', 'hour')


def texts(candidate):
    by_suite = {}
    with gzip.open(RESULTS / f'{candidate}.observations.jsonl.gz', 'rt') as rows:
        for line in rows:
            row = json.loads(line)
            if row.get('suite') in SUITES and row.get('ok') and 'text' in row:
                by_suite.setdefault(row['suite'], {})[row['fixture']] = row['text']
    return by_suite


def compare(a, b):
    out = {}
    for suite in SUITES:
        left, right = a.get(suite, {}), b.get(suite, {})
        shared = sorted(left.keys() & right.keys())
        differ = [k for k in shared if left[k] != right[k]]
        out[suite] = {'compared': len(shared), 'identical': len(shared) - len(differ), 'differ': differ}
    return out


h15, after, before = texts('runtime-main-ultra-q4km'), texts('runtime-0.4.1'), texts('app-0.34.0')
report = {'rule_1_runtime_0_4_1_vs_h15_main': compare(after, h15), 'app_0_34_0_vs_runtime_0_4_1': compare(before, after)}
for name, rows in report.items():
    print(name)
    for suite, row in rows.items():
        print(f"  {suite:12} {row['identical']:5} of {row['compared']:5} identical")
if len(sys.argv) > 1:
    Path(sys.argv[1]).write_text(json.dumps(report, indent=1) + '\n')
