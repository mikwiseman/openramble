"""Choose one predeclared cap/joiner policy before examining held-out results."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('replay', type=Path, nargs='+')
parser.add_argument('--out', required=True, type=Path)
args = parser.parse_args()
rows = [row for path in args.replay for row in json.loads(path.read_text())]
assert len(rows) in (9, 12, 18) and all(r['shippingReplayExact'] is True for r in rows)

def row(language, cap, minimum=15, overlap=2000):
    found = [r for r in rows if r['fixture'] == language + '-3540s' and r['segmentSeconds'] == cap
             and r.get('minimumSegmentSeconds', 15) == minimum
             and r.get('overlapMilliseconds', 2000) == overlap]
    assert len(found) == 1
    return found[0]

policies = []
settings = sorted({(r['segmentSeconds'], r.get('minimumSegmentSeconds', 15), r.get('overlapMilliseconds', 2000)) for r in rows})
base_settings = {(15, 15, 2000), (30, 15, 2000), (60, 15, 2000)}
early_settings = base_settings | {(30, 4, 2000)}
assert set(settings) in (base_settings, early_settings, early_settings | {(30, 4, 250), (30, 15, 250)})
for cap, minimum, overlap in settings:
    for preserve_gap in (False, True):
        differences = {}
        for language in ('ru', 'en', 'mixed'):
            control = row(language, 30)['shipping']
            candidate = row(language, cap, minimum, overlap)['candidate' if preserve_gap else 'shipping']
            differences[language] = {
                'controlWER': control['wer'], 'candidateWER': candidate['wer'],
                'werDifferencePoints': 100 * (candidate['wer'] - control['wer']),
                'controlDeletionRate': control['deletionRate'], 'candidateDeletionRate': candidate['deletionRate'],
                'deletionDifferencePoints': 100 * (candidate['deletionRate'] - control['deletionRate']),
                'changedSeams': len(row(language, cap, minimum, overlap)['changedSeams']) if preserve_gap else 0,
            }
        passed = (differences['mixed']['werDifferencePoints'] <= -2
                  and all(differences[language][metric] <= .5 for language in ('ru', 'en')
                          for metric in ('werDifferencePoints', 'deletionDifferencePoints')))
        policies.append({'segmentSeconds': cap, 'minimumSegmentSeconds': minimum, 'overlapMilliseconds': overlap, 'preserveGap': preserve_gap,
                         'developmentGatePassed': passed, 'comparisons': differences})

eligible = [p for p in policies if p['developmentGatePassed']]
eligible.sort(key=lambda p: (p['comparisons']['mixed']['candidateWER'],
                            sum(p['comparisons'][lang]['candidateWER'] for lang in ('ru', 'en')),
                            int(p['segmentSeconds'] != 30) + int(p['minimumSegmentSeconds'] != 15) + int(p['overlapMilliseconds'] != 2000) + int(p['preserveGap']),
                            p['segmentSeconds'], p['minimumSegmentSeconds'], -p['overlapMilliseconds']))
selected = ({key: eligible[0][key] for key in ('segmentSeconds', 'minimumSegmentSeconds', 'overlapMilliseconds', 'preserveGap')} if eligible else None)
decision = {'developmentGatePassed': bool(eligible), 'selectedPolicy': selected,
            'adoptionApproved': False, 'requiresHeldout': bool(eligible),
            'replaySHA256': [hashlib.sha256(path.read_bytes()).hexdigest() for path in args.replay], 'policies': policies}
args.out.write_text(json.dumps(decision, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'developmentGatePassed': bool(eligible), 'selectedPolicy': selected}))
