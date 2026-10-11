"""Seal the single selected file policy and its matching validation controls."""
import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--decision', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
decision = json.loads(args.decision.read_text())
assert decision['developmentGatePassed'] is True
assert len(decision['policies']) == 12, 'finish both registered conditional families'
selected = decision['selectedPolicy']
settings = {key: selected[key] for key in (
    'segmentSeconds', 'minimumSegmentSeconds', 'overlapMilliseconds')}
control = dict(segmentSeconds=30, minimumSegmentSeconds=15, overlapMilliseconds=2000)
jobs = []
for repeat in range(3):
    languages = ['ru', 'en', 'mixed']
    languages = languages[repeat:] + languages[:repeat]
    for index, language in enumerate(languages):
        variants = [('control', control), ('selected', settings)]
        if (index + repeat) % 2:
            variants.reverse()
        for variant, parameters in variants:
            jobs.append(dict(fixture=language+'-3540s', mode='file', pacing='settled',
                             workers=1, condition='normal', repeat=repeat,
                             variant=variant, parameters=parameters))
assert len(jobs) == 18
args.out.mkdir(parents=True, exist_ok=False)
plan = args.out / 'file-heldout.json'
plan.write_text(json.dumps(jobs, indent=2) + '\n')
record = {
    'registeredUTC': datetime.now(timezone.utc).isoformat(),
    'developmentDecisionSHA256': hashlib.sha256(args.decision.read_bytes()).hexdigest(),
    'selectionSHA256': '6bdb237b31e1fdd75ff61b4d2c14c2d17d72235eb3479868f64702fcaa69968e',
    'planSHA256': hashlib.sha256(plan.read_bytes()).hexdigest(),
    'selectedPolicy': selected,
    'qualityGates': {'mixedWERImprovementPointsAtLeast': 2,
                     'monoWERRegressionPointsAtMost': .5,
                     'monoDeletionRegressionPointsAtMost': .5},
    'repeatGates': 'Exact words, text and chunk boundaries across each three-repeat native cell; exact unchanged-joiner replay in every row.',
    'resourceGate': 'No new memory-pressure failure. Compiler interruptions stay visible and may resume only after a quiet gate.',
    'timingScope': 'Three observations per cell; report medians and all values, no tail-percentile or speed-winner claim. Quality acceptance does not imply a speed improvement.',
    'nativeGate': 'No adoption before failing/green regression tests, native candidate agreement with frozen replay and lifecycle checks.',
    'selectionLock': 'One fixed candidate only. A failed heldout gate rejects this candidate; do not pick another policy on these outputs.'
}
(args.out / 'registration.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record, indent=2))
