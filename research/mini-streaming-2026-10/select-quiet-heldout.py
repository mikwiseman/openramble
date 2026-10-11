"""Seal a second phrase-disjoint set using metadata only, without printing text."""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import unicodedata

parser = argparse.ArgumentParser()
parser.add_argument('--source-data', type=Path, required=True)
parser.add_argument('--first-selection', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
assert not args.out.exists(), 'Never replace a sealed selection'
first = json.loads(args.first_selection.read_text())
first_hash = hashlib.sha256(args.first_selection.read_bytes()).hexdigest()
assert first_hash == '6bdb237b31e1fdd75ff61b4d2c14c2d17d72235eb3479868f64702fcaa69968e'
development = json.loads((args.source_data / 'manifest.json').read_text())

def key(text):
    normalized = ' '.join(re.findall(r'[^\W_]+', unicodedata.normalize('NFC', text).lower().replace('ё', 'е')))
    return hashlib.sha256(normalized.encode()).hexdigest()

selected, audit = [], {}
for language, locale in [('ru', 'ru_ru'), ('en', 'en_us')]:
    excluded = [f for f in development['fixtures'] + first['fixtures'] if f['language'] == language]
    excluded_ids = {f['id'] for f in excluded}
    excluded_phrases = {key(f['reference']) for f in excluded}
    with (args.source_data / 'corpus' / locale / 'test.tsv').open() as handle:
        rows = list(csv.reader(handle, delimiter='\t'))
    rows.sort(key=lambda r: hashlib.sha256((first['selection_seed'] + '/' + locale + '/' + r[1]).encode()).hexdigest())
    seen = set(excluded_phrases)
    chosen = []
    for rank, row in enumerate(rows[100:], start=100):
        identifier, phrase = locale + '-' + row[1][:-4], key(row[2])
        if identifier in excluded_ids or phrase in seen:
            continue
        seen.add(phrase)
        chosen.append({'id': identifier, 'language': language, 'rank': rank,
                       'source_filename': row[1], 'source_row_id': row[0], 'reference': row[2],
                       'reference_sha256': hashlib.sha256(row[2].encode()).hexdigest(),
                       'normalized_reference_sha256': phrase, 'license': 'CC BY 4.0'})
        if len(chosen) == 50:
            break
    assert len(chosen) == 50
    assert not excluded_ids.intersection(f['id'] for f in chosen)
    assert not excluded_phrases.intersection(f['normalized_reference_sha256'] for f in chosen)
    audit[language] = {'recordings': 50, 'uniquePhrases': 50,
                       'firstRank': chosen[0]['rank'], 'lastRank': chosen[-1]['rank'],
                       'overlapWithDevelopmentOrFirstHoldout': 0}
    selected.extend(chosen)
document = {k: first[k] for k in ('source', 'source_revision', 'selection_seed', 'archive_sha256')}
document['split'] = development['split']
assert document['split'] == 'test'
document.update(created_utc=datetime.now(timezone.utc).isoformat(),
                selection='First 50 per language in the original rank order after excluding development, first holdout and duplicate normalized phrases. Metadata only; no audio or candidate output read.',
                excluded_first_holdout_sha256=first_hash,
                purpose='Fixed 0.005 versus 0.02 meeting-threshold validation, only after development/negative/echo gates pass',
                audio_hash_disjointness='Must be checked during conditional extraction', audit=audit, fixtures=selected)
args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n')
digest = hashlib.sha256(args.out.read_bytes()).hexdigest()
args.out.with_suffix('.sha256').write_text(digest + '  ' + args.out.name + '\n')
print(json.dumps({'sha256': digest, 'audit': audit}))
