"""Materialize the sealed quality holdout only after a development gate passes."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import wave

parser = argparse.ArgumentParser()
parser.add_argument('--decision', required=True, type=Path)
parser.add_argument('--source-data', type=Path, required=True)
parser.add_argument('--selection', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
decision = json.loads(args.decision.read_text())
assert decision['developmentGatePassed'] is True, 'do not open the holdout for tuning'
selection_path = args.selection.resolve()
selection = json.loads(selection_path.read_text())
assert hashlib.sha256(selection_path.read_bytes()).hexdigest() == '6bdb237b31e1fdd75ff61b4d2c14c2d17d72235eb3479868f64702fcaa69968e'
source_data = args.source_data.resolve()
development = json.loads((source_data / 'manifest.json').read_text())
old_ids = {f['id'] for f in development['fixtures']}
assert not old_ids.intersection(f['id'] for f in selection['fixtures'])
old_audio = {f['audio_sha256'] for f in development['fixtures']}
dest = args.out.resolve()
dest.mkdir(parents=True, exist_ok=True)

def digest(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()

clips = []
for language, code in [('ru', 'ru_ru'), ('en', 'en_us')]:
    archive = source_data / 'corpus' / code / 'test.tar.gz'
    assert digest(archive) == selection['archive_sha256'][code]
    target = dest / code
    target.mkdir(exist_ok=True)
    chosen = [f for f in selection['fixtures'] if f['language'] == language]
    assert len(chosen) == 50
    by_name = {f['source_filename']: f for f in chosen}
    assert len(by_name) == len(chosen)
    assert all(PurePosixPath(name).name == name for name in by_name)
    found = set()
    with tarfile.open(archive, 'r|gz') as tar:
        for member in tar:
            name = PurePosixPath(member.name).name
            if name not in by_name or not member.isfile():
                continue
            assert name not in found
            raw = target / ('source-' + name)
            with tar.extractfile(member) as source, raw.open('wb') as output:
                shutil.copyfileobj(source, output)
            pcm = target / name
            # Match the existing development corpus conversion exactly.
            with tempfile.TemporaryDirectory(prefix='convert-', dir=target) as temporary:
                converted = Path(temporary) / name
                subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16', '-r', '16000',
                                '-c', '1', str(raw), str(converted)], check=True, capture_output=True)
                converted.replace(pcm)
            with wave.open(str(pcm)) as audio:
                assert (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) == (1, 2, 16000)
                duration = audio.getnframes() / 16000
            item = by_name[name]
            assert hashlib.sha256(item['reference'].encode()).hexdigest() == item['reference_sha256']
            assert digest(pcm) not in old_audio, 'duplicate development audio under a new identifier'
            clips.append({**item, 'path': str(pcm), 'audio_sha256': digest(pcm),
                          'source_audio_sha256': digest(raw), 'duration_seconds': duration})
            found.add(name)
            if len(found) == len(chosen):
                break
    assert found == set(by_name), 'selected source audio missing from the pinned archive'

clips.sort(key=lambda f: (f['language'], f['rank']))
sets = {language: [f for f in clips if f['language'] == language] for language in ('ru', 'en')}
sets['mixed'] = [item for pair in zip(sets['ru'], sets['en']) for item in pair]
fixtures = []
for language, source in sets.items():
    path = dest / (language + '-3540s.wav')
    frames, references, components = 0, [], []
    with wave.open(str(path), 'wb') as output:
        output.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        while frames < 3540 * 16000:
            item = source[len(components) % len(source)]
            with wave.open(item['path']) as audio:
                pcm = audio.readframes(audio.getnframes())
            output.writeframes(pcm)
            output.writeframes(b'\0' * 16000)
            frames += len(pcm) // 2 + 8000
            references.append(item['reference'])
            components.append(item['id'])
    reference = ' '.join(references)
    fixtures.append({'id': language + '-3540s', 'role': '3540', 'language': language,
                     'path': str(path), 'audio_sha256': digest(path), 'reference': reference,
                     'reference_sha256': hashlib.sha256(reference.encode()).hexdigest(),
                     'duration_seconds': frames / 16000, 'components': components,
                     'license': 'CC BY 4.0', 'kind': 'composite-read-speech', 'holdout': True})

(dest / 'source-clips.json').write_text(json.dumps(clips, ensure_ascii=False, indent=2) + '\n')
document = {'source': selection['source'], 'source_revision': selection['source_revision'],
            'selection_sha256': digest(selection_path), 'development_decision_sha256': digest(args.decision),
            'conversion': 'afconvert -f WAVE -d LEI16 -r 16000 -c 1',
            'quality_scope': 'Held out from this experiment; no claim about model training data.',
            'fixtures': fixtures}
(dest / 'mini-inputs.json').write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'clips': len(clips), 'composites': [(f['id'], f['duration_seconds']) for f in fixtures]}))
