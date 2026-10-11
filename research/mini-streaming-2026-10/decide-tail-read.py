"""Evaluate the predeclared suffix-read benchmark gate without changing defaults."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('summary', type=Path)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
summary = json.loads(args.summary.read_text())
assert summary['completedRuns'] == 40
assert len(summary['tailParity']) == 40
parity = all(all(row[key] for key in ('exactText', 'sameFinalSamples', 'sameDecodeSizes'))
             for row in summary['tailParity'])
with gzip.open(args.summary.with_name('public-runs.jsonl.gz'), 'rt') as handle:
    runs = [json.loads(line) for line in handle]
comparisons = []
for fixture in ('ru-360s', 'en-360s', 'ru-3540s', 'en-3540s'):
    for condition in ('normal', 'cpu10'):
        pair = [g for g in summary['groups'] if g['fixture'] == fixture and g['condition'] == condition]
        assert len(pair) == 2
        base = next(g for g in pair if not g['tailRead'])
        candidate = next(g for g in pair if g['tailRead'])
        expected_n = 1 if condition == 'cpu10' and '3540s' in fixture else 3
        assert base['seconds']['n'] == candidate['seconds']['n'] == expected_n
        paired = []
        for repeat in range(expected_n):
            rows = [r for r in runs if r['fixture'] == fixture and r['condition'] == condition and r['repeat'] == repeat]
            assert len(rows) == 2
            a = next(r for r in rows if not r['tailRead'])
            b = next(r for r in rows if r['tailRead'])
            paired.append({'repeat': repeat, 'fullSeconds': a['stopSeconds'], 'tailSeconds': b['stopSeconds'],
                           'differenceSeconds': b['stopSeconds'] - a['stopSeconds']})
        comparisons.append({'fixture': fixture, 'condition': condition, 'n': expected_n,
                            'full': base['seconds'], 'tail': candidate['seconds'],
                            'medianGainPercent': 100 * (1 - candidate['seconds']['p50'] / base['seconds']['p50']),
                            'fullPeakFootprintBytes': base['sampledPeakPhysicalFootprintBytes'],
                            'tailPeakFootprintBytes': candidate['sampledPeakPhysicalFootprintBytes'],
                            'pairs': paired})
normal_long = [r for r in comparisons if '3540s' in r['fixture'] and r['condition'] == 'normal']
assert len(normal_long) == 2
pressure_failures = [r for r in summary['failures'] if r['hardStop'] == 'memory pressure']
result = {'summarySHA256': hashlib.sha256(args.summary.read_bytes()).hexdigest(),
          'exactParityPassed': parity, 'memoryGatePassed': not pressure_failures,
          'longMedianGatePassed': all(r['medianGainPercent'] >= 10 for r in normal_long),
          'comparisons': comparisons, 'failedAttempts': len(summary['failures']),
          'adoptionApproved': False,
          'remainingGate': 'Require green lifecycle, reader and application wiring checks before adoption.'}
result['benchmarkGatePassed'] = all(result[key] for key in ('exactParityPassed', 'memoryGatePassed', 'longMedianGatePassed'))
args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({key: result[key] for key in ('exactParityPassed', 'memoryGatePassed', 'longMedianGatePassed', 'benchmarkGatePassed')}))
