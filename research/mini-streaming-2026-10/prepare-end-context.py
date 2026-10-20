"""Prepare the registered synthetic localization pair, never a public-speech score."""
import argparse
import hashlib
import json
from pathlib import Path
import wave

parser = argparse.ArgumentParser()
parser.add_argument('--source-wav', required=True, type=Path)
parser.add_argument('--out', required=True, type=Path)
args = parser.parse_args()
expected = 'b0d44e74fd9b91db9e6f4ddd787764d656ea617936996d64a37b76c0bd6601ea'
assert hashlib.sha256(args.source_wav.read_bytes()).hexdigest() == expected, 'Different system-voice audio; register a separate cohort'
args.out.mkdir(parents=True, exist_ok=True)
assert not (args.out / 'mini-inputs.json').exists(), 'Do not overwrite a registered cohort'
with wave.open(str(args.source_wav), 'rb') as source:
    assert (source.getnchannels(), source.getframerate(), source.getsampwidth()) == (1, 16000, 2)
    pcm = source.readframes(source.getnframes())
reference = 'Please review my pull request send it'
fixtures = []
for label, added in [('original', 0), ('pad500', 8000)]:
    target = args.out / f'synthetic-en-{label}.wav'
    with wave.open(str(target), 'wb') as dest:
        dest.setnchannels(1)
        dest.setsampwidth(2)
        dest.setframerate(16000)
        dest.writeframes(pcm + b'\0\0' * added)
    fixtures.append({'id': f'synthetic-en-{label}', 'language': 'en',
        'path': str(target.resolve()), 'audio_sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
        'duration_seconds': (len(pcm) // 2 + added) / 16000,
        'reference': reference, 'reference_sha256': hashlib.sha256(reference.encode()).hexdigest(),
        'original_audio_sha256': expected, 'original_pcm_sha256': hashlib.sha256(pcm).hexdigest(),
        'trailingZeroFrames': added, 'role': 'synthetic E2E localization; not FLEURS'})
manifest = {'source': 'macOS say Samantha; existing synthetic E2E phrase',
    'source_revision': 'macOS26.4-25E246; exact cached audio, voice binary not pinned',
    'source_manifest_sha256': hashlib.sha256((reference + expected).encode()).hexdigest(),
    'fixtures': fixtures}
(args.out / 'mini-inputs.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Prepared two synthetic localization inputs; no inference')
