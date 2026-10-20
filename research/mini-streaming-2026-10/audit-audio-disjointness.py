"""Check audio payloads as well as WAV-file hashes and normalized phrases."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import unicodedata
import wave

parser = argparse.ArgumentParser()
parser.add_argument('--development', type=Path, required=True)
parser.add_argument('--heldout', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()

def read(path):
    value = json.loads(path.read_text())
    return value['fixtures'] if isinstance(value, dict) else value

def audit(rows):
    result = []
    for row in rows:
        path = Path(row['path'])
        file_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        assert file_hash == row['audio_sha256']
        with wave.open(str(path)) as source:
            assert (source.getnchannels(), source.getsampwidth(), source.getframerate()) == (1, 2, 16000)
            pcm_hash = hashlib.sha256(source.readframes(source.getnframes())).hexdigest()
        normalized = ' '.join(re.findall(r'[^\W_]+', unicodedata.normalize('NFC', row['reference']).lower().replace('ё', 'е')))
        result.append({'id': row['id'], 'language': row['language'], 'waveFileSHA256': file_hash,
                       'pcmSHA256': pcm_hash, 'normalizedReferenceSHA256': hashlib.sha256(normalized.encode()).hexdigest()})
    return result

development, heldout = audit(read(args.development)), audit(read(args.heldout))
overlaps = {key: sorted({r[key] for r in development} & {r[key] for r in heldout})
            for key in ('id', 'waveFileSHA256', 'pcmSHA256', 'normalizedReferenceSHA256')}
assert all(not value for value in overlaps.values()), overlaps
assert len({r['pcmSHA256'] for r in heldout}) == len(heldout)
assert len({r['normalizedReferenceSHA256'] for r in heldout}) == len(heldout)
result = {'checkedUTC': datetime.now(timezone.utc).isoformat(), 'developmentCount': len(development),
          'heldoutCount': len(heldout), 'overlapCounts': {k: len(v) for k, v in overlaps.items()},
          'development': development, 'heldout': heldout,
          'scope': 'PCM payload excludes WAV container headers. This verifies experiment separation, not absence from model training data.'}
args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({k: result[k] for k in ('developmentCount', 'heldoutCount', 'overlapCounts')}))
