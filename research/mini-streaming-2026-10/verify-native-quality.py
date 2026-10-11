"""Compare three shipping-path outputs with the locked selected-policy words."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--run', type=Path, required=True)
parser.add_argument('--expected', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
expected = {r['fixture']: r for r in json.loads(args.expected.read_text())}
observations = [json.loads(line) for line in (args.run / 'observations.jsonl').read_text().splitlines()]
success = [r for r in observations if r['exit_code'] == 0 and 'hard_stop' not in r]
failed = [r for r in observations if r not in success]
assert len(success) == 3 and {r['fixture'] for r in success} == set(expected)
comparisons = []
for observation in success:
    raw = json.loads((args.run / 'raw' / (observation['id'] + '.json')).read_text())
    frozen = expected[observation['fixture']]
    comparisons.append({'fixture': observation['fixture'], 'mode': raw['mode'],
                         'exactText': raw['text'] == frozen['text'],
                         'exactWordTimings': raw['words'] == frozen['words'],
                         'validTimingBounds': raw['timingBoundsValid'],
                         'textSHA256': raw['textSHA256'], 'processingSeconds': raw['processingSeconds']})
passed = all(all(r[k] for k in ('exactText', 'exactWordTimings', 'validTimingBounds')) for r in comparisons)
memory = not any(r.get('hard_stop') == 'memory pressure' for r in failed)
result = {'nativeShippingParityPassed': passed, 'memoryGatePassed': memory, 'comparisons': comparisons,
          'failedAttempts': [{'id': r['id'], 'exitCode': r['exit_code'], 'hardStop': r.get('hard_stop')} for r in failed],
          'expectedSHA256': hashlib.sha256(args.expected.read_bytes()).hexdigest(),
          'identity': json.loads((args.run / 'identity.json').read_text()),
          'scope': 'Three shipping-path checks of the fixed selected policy. One pass per language; no new speed estimate.'}
args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'nativeShippingParityPassed': passed, 'memoryGatePassed': memory}))
