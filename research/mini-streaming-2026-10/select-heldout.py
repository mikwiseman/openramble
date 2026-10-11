"""Select unseen recordings and normalized phrases without displaying their text."""
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
parser.add_argument('--plan-dir', type=Path, required=True)
args = parser.parse_args()
plan = args.plan_dir / 'heldout-selection.json'
original = args.plan_dir / 'heldout-selection-v1-unrun.json'
if original.exists() and plan.exists() and 'supersedes_unrun_selection_sha256' in json.loads(plan.read_text()):
    expected = (plan.parent / 'heldout-selection.sha256').read_text().split()[0]
    assert hashlib.sha256(plan.read_bytes()).hexdigest() == expected, 'sealed selection changed'
    raise SystemExit('The revised selection is already sealed; no file changed.')
if not original.exists():
    original.write_bytes(plan.read_bytes())
base = json.loads(original.read_text())
development = json.loads((args.source_data / 'manifest.json').read_text())

def reference_key(text):
    normalized = ' '.join(re.findall(r'[^\W_]+', unicodedata.normalize('NFC', text).lower().replace('ё', 'е')))
    return hashlib.sha256(normalized.encode()).hexdigest()

selected, audit = [], {}
for language, locale in [('ru', 'ru_ru'), ('en', 'en_us')]:
    old = [f for f in development['fixtures'] if f['language'] == language]
    old_ids = {f['id'] for f in old}
    old_references = {reference_key(f['reference']) for f in old}
    with (args.source_data / 'corpus' / locale / 'test.tsv').open() as handle:
        rows = list(csv.reader(handle, delimiter='\t'))
    rows.sort(key=lambda r: hashlib.sha256((base['selection_seed'] + '/' + locale + '/' + r[1]).encode()).hexdigest())
    assert {locale + '-' + r[1][:-4] for r in rows[:100]} == old_ids
    seen = set(old_references)
    chosen, skipped = [], 0
    for rank, row in enumerate(rows[100:], start=100):
        key = reference_key(row[2])
        if key in seen:
            skipped += 1
            continue
        seen.add(key)
        chosen.append({'id': locale + '-' + row[1][:-4], 'language': language, 'rank': rank,
                       'source_filename': row[1], 'source_row_id': row[0], 'reference': row[2],
                       'reference_sha256': hashlib.sha256(row[2].encode()).hexdigest(),
                       'normalized_reference_sha256': key, 'license': 'CC BY 4.0'})
        if len(chosen) == 50:
            break
    assert len(chosen) == 50
    assert not old_ids.intersection(f['id'] for f in chosen)
    assert not old_references.intersection(f['normalized_reference_sha256'] for f in chosen)
    audit[language] = {'selected': 50, 'lastRank': chosen[-1]['rank'], 'skippedDuplicatePhrases': skipped,
                       'recordingOverlap': 0, 'normalizedPhraseOverlap': 0, 'uniqueHeldoutPhrases': 50}
    selected.extend(chosen)

document = {**{k: v for k, v in base.items() if k not in ('fixtures', 'selection', 'created_utc')},
            'created_utc': datetime.now(timezone.utc).isoformat(),
            'selection': 'Starting at rank 100 in the original SHA-256 filename order, select 50 per language, excluding development and within-holdout normalized phrase duplicates. No audio or candidate inference examined.',
            'supersedes_unrun_selection_sha256': hashlib.sha256(original.read_bytes()).hexdigest(),
            'amendment_reason': 'Metadata-only audit found different recordings of repeated phrases in the original selection, before any candidate or heldout inference.',
            'normalization': 'Unicode NFC, lowercase, ё to е, Unicode word tokens, no numeral expansion',
            'audit': audit, 'fixtures': selected}
plan.write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n')
digest = hashlib.sha256(plan.read_bytes()).hexdigest()
(plan.parent / 'heldout-selection.sha256').write_text(digest + '  heldout-selection.json\n')
print(json.dumps({'sha256': digest, 'audit': audit}))
