"""Score the fixed threshold pair, including work and hallucinations on silence."""
import argparse
from collections import defaultdict
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--run', type=Path, required=True)
parser.add_argument('--data', type=Path, required=True)
parser.add_argument('--scorer', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--heldout', action='store_true', help='two unseen composites, one pass per threshold')
parser.add_argument('--channel', choices=('microphone', 'system'))
args = parser.parse_args()
spec = importlib.util.spec_from_file_location('scorer', args.scorer)
scorer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scorer)
manifest = json.loads((args.data / 'mini-inputs.json').read_text())
fixtures = {f['id']: f for f in manifest['fixtures']}
observations = [json.loads(line) for line in (args.run / 'observations.jsonl').read_text().splitlines()]
rows, failures, system = [], [], []
for observation in observations:
    if observation['exit_code'] != 0 or 'hard_stop' in observation:
        failures.append({k: observation.get(k) for k in ('id', 'fixture', 'exit_code', 'hard_stop', 'pressure')})
        continue
    raw = json.loads((args.run / 'raw' / (observation['id'] + '.json')).read_text())
    assert raw['meetingPreserveQuietAudio'] is False
    if args.channel:
        assert raw.get('meetingChannel', 'microphone') == args.channel
    measured_peak = raw['meetingSpeechPeak']
    canonical_peak = min((.02, .005), key=lambda peak: abs(peak - measured_peak))
    assert abs(measured_peak - canonical_peak) < 1e-8
    raw['meetingSpeechPeak'] = canonical_peak
    fixture = fixtures[observation['fixture']]
    row = {**raw, 'fixture': fixture['id'], 'condition': observation['condition'],
           'repeat': observation['repeat'], 'normalizedWords': len(scorer.normalized(raw['text']).split())}
    if fixture['reference']:
        row['quality'] = scorer.score(fixture['reference'], raw['text'])
    else:
        assert fixture['kind'] == 'synthetic-negative'
        row['quality'] = None
    calls = raw['calls']
    assert len(calls) == raw['segments']
    row['decodeWork'] = {'calls': len(calls),
                         'totalSeconds': sum(c['wallSeconds'] for c in calls),
                         'maxCallSeconds': max((c['wallSeconds'] for c in calls), default=0),
                         'decodedAudioSeconds': sum(c['samples'] for c in calls) / 16000}
    rows.append(row)
    clean = {k: observation[k] for k in ('id', 'fixture', 'condition', 'repeat', 'exit_code', 'process_seconds', 'pressure')}
    for stage in ('before', 'under_condition', 'after'):
        clean[stage] = {k: v for k, v in observation[stage].items() if k != 'processes'}
    system.append(clean)
assert len(rows) == len({r['id'] for r in rows}) == (4 if args.heldout else 18)
comparisons = []
for fixture in fixtures.values():
    pair = [r for r in rows if r['fixture'] == fixture['id']]
    assert len(pair) == 2
    control = next(r for r in pair if r['meetingSpeechPeak'] == .02)
    candidate = next(r for r in pair if r['meetingSpeechPeak'] == .005)
    row = {'fixture': fixture['id'], 'language': fixture['language'], 'audioSeconds': control['audioSeconds'],
           'control': {k: control[k] for k in ('quality', 'normalizedWords', 'decodeWork', 'submittedFrames', 'unsubmittedFrames')},
           'candidate': {k: candidate[k] for k in ('quality', 'normalizedWords', 'decodeWork', 'submittedFrames', 'unsubmittedFrames')}}
    if control['quality']:
        row['werDifferencePoints'] = 100 * (candidate['quality']['wer'] - control['quality']['wer'])
        row['deletionDifferencePoints'] = 100 * (candidate['quality']['deletionRate'] - control['quality']['deletionRate'])
    comparisons.append(row)
speech = [r for r in comparisons if r['control']['quality'] is not None]
negative = [r for r in comparisons if r['control']['quality'] is None]
assert (len(speech), len(negative)) == ((2, 0) if args.heldout else (4, 5))
assert {r['language'] for r in speech} == {'ru', 'en'}
gates = {
    'englishGainPassed': all(r['werDifferencePoints'] <= -10 and r['deletionDifferencePoints'] <= 0 for r in speech if r['language'] == 'en'),
    'russianPreservationPassed': all(r['werDifferencePoints'] <= .5 and r['deletionDifferencePoints'] <= .5 for r in speech if r['language'] == 'ru'),
    'negativeInputsPassed': all(r['candidate']['normalizedWords'] == 0 for r in negative),
    'decodeBudgetPassed': max(r['decodeWork']['maxCallSeconds'] for r in rows if r['meetingSpeechPeak'] == .005) <= 2,
    'memoryGatePassed': not any(r['hard_stop'] == 'memory pressure' for r in failures),
}
if args.heldout:
    del gates['negativeInputsPassed']
result = {'completedRuns': len(rows), 'gates': gates,
          ('nativeHeldoutGatePassed' if args.heldout else 'nativeDevelopmentGatePassed'): all(gates.values()),
          'echoGatePassed': None, 'heldoutGatePassed': None, 'adoptionApproved': False,
          'comparisons': comparisons, 'failedAttempts': failures,
          'identity': json.loads((args.run / 'identity.json').read_text()),
          'scope': ('Two unseen composites, all 50 distinct phrases of each language exactly once, one pass per threshold; fixed development candidate.' if args.heldout else 'Four fixed public speech composites and five synthetic negatives, one pass per threshold; separate echo tests and disjoint validation required.')}
args.out.mkdir(parents=True, exist_ok=True)
(args.out / 'decision.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
(args.out / 'fixtures.json').write_text(json.dumps([{k: v for k, v in f.items() if k != 'path'} for f in fixtures.values()], ensure_ascii=False, indent=2) + '\n')
for name, data in [('public-runs.jsonl.gz', rows), ('system-observations.jsonl.gz', system)]:
    with gzip.open(args.out / name, 'wt') as output:
        for row in data:
            output.write(json.dumps(row, ensure_ascii=False) + '\n')
print(json.dumps(gates))
