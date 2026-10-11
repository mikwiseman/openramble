"""Replay the shipping joiner, then one frozen gap-preserving candidate."""
import argparse
import importlib.util
import json
from pathlib import Path

scorer_path = Path(__file__).with_name('analyze.py')
if not scorer_path.exists():
    scorer_path = Path(__file__).parent / 'prototypes/analyze.py'
spec = importlib.util.spec_from_file_location('scorer', scorer_path)
scorer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scorer)


def key(text):
    return ''.join(c for c in text.lower() if c.isalnum())


def join(raw, preserve_gap):
    words, changes = [], []
    for chunk in raw['chunks']:
        assert 'words' in chunk, 'requires the new harness with native per-chunk word times'
        offset = chunk['startFrame'] / 16_000
        boundary = chunk['boundaryFrame'] / 16_000
        incoming = [{'text': w['text'], 'start': min(raw['audioSeconds'], offset + w['start']),
                     'end': min(raw['audioSeconds'], offset + w['end'])} for w in chunk['words']]
        if not words:
            words = incoming
            continue
        previous_start = next((i for i, w in enumerate(words) if w['end'] >= offset), len(words))
        match = None
        if len(incoming) >= 2 and len(words) >= 2:
            for old in range(previous_start, max(previous_start, len(words) - 1)):
                for new in range(len(incoming) - 1):
                    if (incoming[new]['start'] <= boundary + 2
                            and abs(words[old]['start'] - incoming[new]['start']) < .6
                            and key(words[old]['text']) == key(incoming[new]['text'])
                            and key(words[old]['text'])
                            and key(words[old + 1]['text']) == key(incoming[new + 1]['text'])):
                        distance = abs(incoming[new]['start'] - boundary)
                        if match is None or distance < match[2]:
                            match = old, new, distance
        if match is not None:
            words = words[:match[0] + 1] + incoming[match[1] + 1:]
        elif preserve_gap and incoming and incoming[0]['start'] - words[-1]['end'] >= .6:
            changes.append({'chunk': chunk['index'], 'boundarySeconds': boundary,
                            'oldLastEnd': words[-1]['end'], 'newFirstStart': incoming[0]['start']})
            words += incoming
        else:
            words = [w for w in words if (w['start'] + w['end']) / 2 < boundary]
            words += [w for w in incoming if (w['start'] + w['end']) / 2 >= boundary]
        previous = 0.0
        for word in words:
            word['start'] = max(previous, word['start'])
            previous = word['start']
            word['end'] = max(word['start'], word['end'])
    return words, changes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('run', type=Path)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--all-caps', action='store_true', help='replay every predeclared cap as a joint exploratory map')
    args = parser.parse_args()
    fixtures = {f['id']: f for f in json.loads((args.data / 'mini-inputs.json').read_text())['fixtures']}
    observations = [json.loads(line) for line in (args.run / 'observations.jsonl').read_text().splitlines()]
    assignments = {row['id']: row['fixture'] for row in observations}
    rows = []
    for path in sorted((args.run / 'raw').glob('*.json')):
        raw = json.loads(path.read_text())
        if raw['mode'] != 'file' or (not args.all_caps and raw.get('segmentSeconds', 30) != 30):
            continue
        fixture = fixtures[assignments[raw['id']]]
        baseline, _ = join(raw, False)
        assert baseline == raw['words'], f'shipping replay mismatch: {raw["id"]}'
        candidate, changes = join(raw, True)
        text = ' '.join(w['text'] for w in candidate)
        row = {'id': raw['id'], 'fixture': fixture['id'], 'segmentSeconds': raw.get('segmentSeconds', 30),
               'minimumSegmentSeconds': raw.get('minimumSegmentSeconds', 15),
               'overlapMilliseconds': raw.get('overlapMilliseconds', 2000),
               'shippingReplayExact': True,
               'shipping': scorer.score(fixture['reference'], raw['text']),
               'candidate': scorer.score(fixture['reference'], text),
               'changedSeams': changes, 'text': text, 'words': candidate}
        rows.append(row)
        print(json.dumps({'fixture': row['fixture'], 'segmentSeconds': row['segmentSeconds'], 'changedSeams': len(changes),
                          'shippingWER': row['shipping']['wer'], 'candidateWER': row['candidate']['wer'],
                          'shippingDeletions': row['shipping']['deletionRate'],
                          'candidateDeletions': row['candidate']['deletionRate']}))
    assert rows, 'no complete matching file runs found'
    args.out.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
