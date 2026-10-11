"""Open the second sealed set only after development, noise and echo gates."""
import argparse
import hashlib
import json
import re
import unicodedata
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import wave

parser = argparse.ArgumentParser()
parser.add_argument('--decision', type=Path, required=True)
parser.add_argument('--echo-evidence', type=Path, required=True)
parser.add_argument('--source-data', type=Path, required=True)
parser.add_argument('--first-heldout', type=Path, required=True)
parser.add_argument('--selection', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--system-only-registration', type=Path)
args = parser.parse_args()

def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()

assert json.loads(args.decision.read_text())['nativeDevelopmentGatePassed'] is True
echo = json.loads(args.echo_evidence.read_text())
assert echo['candidateEchoGatePassed'] is True
if args.system_only_registration:
    registered = json.loads(args.system_only_registration.read_text())
    assert registered['protocolSHA256'] == '3733f95940aed9d05b73aff97a746969150526a237ebd6648bf260766e27575c'
    assert echo['candidateScope'] == 'system-only'
    assert registered['quietNativeOutputsInspected'] is False
else:
    assert echo.get('candidateScope', 'global') == 'global'
assert digest(args.selection) == '91c79d513cbdac78ffc213e8f75e260385722fe8cb53b9bdc960d4a7b52ff24c'
selection = json.loads(args.selection.read_text())
development = json.loads((args.source_data / 'manifest.json').read_text())['fixtures']
first = json.loads((args.first_heldout / 'source-clips.json').read_text())
excluded = development + first
assert not {r['id'] for r in excluded}.intersection(r['id'] for r in selection['fixtures'])

def normalized(text):
    return ' '.join(re.findall(r'[^\W_]+', unicodedata.normalize('NFC', text).lower().replace('ё', 'е')))

new_references = [normalized(r['reference']) for r in selection['fixtures']]
assert len(new_references) == len(set(new_references)) == 100
assert not set(new_references).intersection(normalized(r['reference']) for r in excluded)

def pcm_hash(path):
    with wave.open(str(path)) as source:
        assert (source.getnchannels(), source.getsampwidth(), source.getframerate()) == (1, 2, 16000)
        return hashlib.sha256(source.readframes(source.getnframes())).hexdigest()

excluded_pcm = {pcm_hash(Path(r['path'])) for r in excluded}
excluded_files = {r['audio_sha256'] for r in excluded}
dest = args.out.resolve()
dest.mkdir(parents=True, exist_ok=False)
clips = []
for language, code in [('ru', 'ru_ru'), ('en', 'en_us')]:
    archive = args.source_data / 'corpus' / code / 'test.tar.gz'
    assert digest(archive) == selection['archive_sha256'][code]
    target = dest / code
    target.mkdir()
    chosen = [r for r in selection['fixtures'] if r['language'] == language]
    assert len(chosen) == 50
    by_name = {r['source_filename']: r for r in chosen}
    assert len(by_name) == 50 and all(PurePosixPath(n).name == n for n in by_name)
    found = set()
    with tarfile.open(archive, 'r|gz') as tar:
        for member in tar:
            name = PurePosixPath(member.name).name
            if name not in by_name or not member.isfile():
                continue
            assert name not in found
            raw, pcm = target / ('source-' + name), target / name
            with tar.extractfile(member) as source, raw.open('wb') as output:
                shutil.copyfileobj(source, output)
            with tempfile.TemporaryDirectory(prefix='convert-', dir=target) as temporary:
                converted = Path(temporary) / name
                subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16', '-r', '16000', '-c', '1',
                                str(raw), str(converted)], check=True, capture_output=True)
                converted.replace(pcm)
            payload = pcm_hash(pcm)
            assert payload not in excluded_pcm and digest(pcm) not in excluded_files
            assert payload not in {r['pcm_sha256'] for r in clips}
            with wave.open(str(pcm)) as audio:
                seconds = audio.getnframes() / 16000
            row = by_name[name]
            assert hashlib.sha256(row['reference'].encode()).hexdigest() == row['reference_sha256']
            clips.append({**row, 'path': str(pcm), 'audio_sha256': digest(pcm),
                          'pcm_sha256': payload, 'source_audio_sha256': digest(raw), 'duration_seconds': seconds})
            found.add(name)
            if len(found) == 50:
                break
    assert found == set(by_name)

clips.sort(key=lambda r: (r['language'], r['rank']))
fixtures = []
for language in ('ru', 'en'):
    path = dest / (language + '-quiet-heldout.wav')
    parts = [r for r in clips if r['language'] == language]
    frames = 0
    with wave.open(str(path), 'wb') as output:
        output.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        for item in parts:
            with wave.open(item['path']) as source:
                pcm = source.readframes(source.getnframes())
            output.writeframes(pcm + b'\0' * 16000)
            frames += len(pcm) // 2 + 8000
    reference = ' '.join(r['reference'] for r in parts)
    fixtures.append({'id': language + '-quiet-heldout', 'language': language, 'path': str(path),
                     'audio_sha256': digest(path), 'duration_seconds': frames / 16000, 'reference': reference,
                     'reference_sha256': hashlib.sha256(reference.encode()).hexdigest(),
                     'components': [r['id'] for r in parts], 'license': 'CC BY 4.0',
                     'kind': 'composite-read-speech', 'role': 'each of 50 whole phrases once; no repeats'})
jobs = []
for index, fixture in enumerate(fixtures):
    variants = [('threshold020', .02), ('threshold005', .005)]
    if index:
        variants.reverse()
    for variant, peak in variants:
        jobs.append(dict(fixture=fixture['id'], mode='meeting', pacing='settled', workers=1,
                         condition='normal', repeat=0, variant=variant,
                         parameters=dict(meetingSpeechPeak=peak, meetingPreserveQuietAudio=False)))
if args.system_only_registration:
    for job in jobs:
        job['parameters']['meetingChannel'] = 'system'
        if job['parameters']['meetingSpeechPeak'] == .005:
            del job['parameters']['meetingSpeechPeak']  # exercise the actual selected default

manifest = {'source': selection['source'], 'source_revision': selection['source_revision'],
            'selection_sha256': digest(args.selection), 'development_decision_sha256': digest(args.decision),
            'echo_evidence_sha256': digest(args.echo_evidence), 'fixtures': fixtures,
            'candidateScope': 'system-only' if args.system_only_registration else 'global',
            'systemOnlyRegistrationSHA256': digest(args.system_only_registration) if args.system_only_registration else None}
for name, data in [('source-clips.json', clips), ('mini-inputs.json', manifest), ('quiet-heldout.json', jobs)]:
    (dest / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'clips': len(clips), 'composites': [(f['id'], f['duration_seconds']) for f in fixtures]}))
