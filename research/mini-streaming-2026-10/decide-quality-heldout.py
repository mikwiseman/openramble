"""Evaluate one sealed candidate; never select or retune on validation outputs."""
import argparse
from collections import defaultdict
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics

parser = argparse.ArgumentParser()
parser.add_argument('--run', type=Path, required=True)
parser.add_argument('--replay', type=Path, required=True)
parser.add_argument('--registration', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
registration = json.loads(args.registration.read_text())
replays = {r['id']: r for r in json.loads(args.replay.read_text())}
assert len(replays) == 18 and all(r['shippingReplayExact'] for r in replays.values())
selected = registration['selectedPolicy']
observations = [json.loads(line) for line in (args.run / 'observations.jsonl').read_text().splitlines()]
failures = [r for r in observations if r['exit_code'] != 0 or 'hard_stop' in r]
rows = [r for r in observations if r['exit_code'] == 0 and 'hard_stop' not in r]
assert len(rows) == len({r['id'] for r in rows}) == 18
groups = defaultdict(list)
for row in rows:
    native = json.loads((args.run / 'raw' / (row['id'] + '.json')).read_text())
    groups[(row['fixture'], row['variant'])].append((row, native, replays[row['id']]))

def same_native(members):
    def comparable(raw):
        return {'text': raw['text'], 'words': raw['words'], 'chunks': [
            {k: c[k] for k in ('index', 'startFrame', 'boundaryFrame', 'endFrame', 'text', 'words')}
            for c in raw['chunks']]}
    first = comparable(members[0][1])
    return all(comparable(m[1]) == first for m in members)

comparisons = {}
repeat_parity = True
for language in ('ru', 'en', 'mixed'):
    cells = {}
    quality = {}
    for variant in ('control', 'selected'):
        members = groups[(language + '-3540s', variant)]
        assert len(members) == 3 and {m[0]['repeat'] for m in members} == {0, 1, 2}
        assert all(m[0]['workers'] == 1 and m[0]['condition'] == 'normal' for m in members)
        exact = same_native(members)
        repeat_parity &= exact
        branch = 'candidate' if variant == 'selected' and selected['preserveGap'] else 'shipping'
        assert all(m[2][branch] == members[0][2][branch] for m in members)
        quality[variant] = members[0][2][branch]
        times = [m[1]['processingSeconds'] for m in sorted(members, key=lambda m: m[0]['repeat'])]
        cells[variant] = {'n': 3, 'exactNativeRepeatParity': exact,
                          'processingSeconds': times, 'medianSeconds': statistics.median(times),
                          'quality': quality[variant],
                          'peakRSSBytes': [m[1]['peakRSSBytes'] for m in members]}
    cells['werDifferencePoints'] = 100 * (quality['selected']['wer'] - quality['control']['wer'])
    cells['deletionDifferencePoints'] = 100 * (quality['selected']['deletionRate'] - quality['control']['deletionRate'])
    cells['medianProcessingChangePercent'] = 100 * (cells['selected']['medianSeconds'] / cells['control']['medianSeconds'] - 1)
    comparisons[language] = cells
gates = registration['qualityGates']
quality_passed = (comparisons['mixed']['werDifferencePoints'] <= -gates['mixedWERImprovementPointsAtLeast']
                  and all(comparisons[lang]['werDifferencePoints'] <= gates['monoWERRegressionPointsAtMost']
                          and comparisons[lang]['deletionDifferencePoints'] <= gates['monoDeletionRegressionPointsAtMost']
                          for lang in ('ru', 'en')))
memory_passed = not any(row.get('hard_stop') == 'memory pressure' for row in failures)
result = {'selectedPolicy': selected, 'qualityGatePassed': quality_passed,
          'repeatParityPassed': repeat_parity, 'memoryGatePassed': memory_passed,
          'heldoutGatePassed': quality_passed and repeat_parity and memory_passed,
          'adoptionApproved': False, 'remainingGate': registration['nativeGate'],
          'comparisons': comparisons, 'failedAttempts': len(failures),
          'registrationSHA256': hashlib.sha256(args.registration.read_bytes()).hexdigest(),
          'replaySHA256': hashlib.sha256(args.replay.read_bytes()).hexdigest(),
          'timingScope': 'Native cap30 versus cap15 with the unchanged joiner; the gap-preserving quality is a replay on the same native words. Final shipping-path checks are separate.',
          'scope': '50 distinct heldout phrases per language, repeated into three long composites. Repeated runs are computational replicates, not extra language samples.'}
args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: result[k] for k in ('selectedPolicy', 'qualityGatePassed', 'repeatParityPassed', 'memoryGatePassed', 'heldoutGatePassed')}))
