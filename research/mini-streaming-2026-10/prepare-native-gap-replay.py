"""Convert complete frozen words/replays to the opt-in native verification input."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--run', type=Path, action='append', required=True)
parser.add_argument('--replay', type=Path, action='append', required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
assert len(args.run) == len(args.replay)
cases = []
for run, replay in zip(args.run, args.replay):
    for row in json.loads(replay.read_text()):
        assert row['shippingReplayExact']
        raw = json.loads((run / 'raw' / (row['id'] + '.json')).read_text())
        cases.append({'id': run.name + '/' + row['id'], 'audioSeconds': raw['audioSeconds'],
                      'chunks': [{k: c[k] for k in ('startFrame', 'boundaryFrame', 'endFrame', 'words')}
                                 for c in raw['chunks']],
                      'expectedWords': row['words'], 'expectedText': row['text']})
assert cases and len({c['id'] for c in cases}) == len(cases)
args.out.write_text(json.dumps(cases, ensure_ascii=False, separators=(',', ':')) + '\n')
print(json.dumps({'cases': len(cases), 'sha256': hashlib.sha256(args.out.read_bytes()).hexdigest()}))
