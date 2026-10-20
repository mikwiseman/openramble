"""Freeze the single registered threshold pair and deterministic negative PCM."""
import argparse
import hashlib
import json
from pathlib import Path
import wave
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument('--source-data', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
source = args.source_data / 'mini-inputs.json'
original = json.loads(source.read_text())
names = ['ru-60s', 'en-60s', 'ru-360s', 'en-360s']
fixtures = [next(f for f in original['fixtures'] if f['id'] == name) for name in names]
args.out.mkdir(parents=True, exist_ok=False)
rate, count, seed = 16000, 320000, 20261011
time = np.arange(count, dtype=np.float64) / rate
noise = np.random.Generator(np.random.PCG64(seed))
signals = [('silence', np.zeros(count)),
           ('uniform003', noise.uniform(-.003, .003, count)),
           ('uniform010', noise.uniform(-.01, .01, count)),
           ('sine50hz', .01 * np.sin(2 * np.pi * 50 * time))]
clicks = np.zeros(count)
for start in range(0, count, 2 * rate):
    clicks[start:start+16] = .3
signals.append(('clicks1ms', clicks))
for name, samples in signals:
    pcm = np.rint(samples * 32768).astype('<i2').tobytes()
    path = args.out / (name + '.wav')
    with wave.open(str(path), 'wb') as output:
        output.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
        output.writeframes(pcm)
    fixtures.append({'id': 'negative-' + name, 'path': str(path.resolve()),
                     'audio_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                     'pcm_sha256': hashlib.sha256(pcm).hexdigest(),
                     'duration_seconds': 20, 'language': 'none', 'reference': '',
                     'reference_sha256': hashlib.sha256(b'').hexdigest(),
                     'kind': 'synthetic-negative', 'role': 'no speech; count emitted words, no WER'})
jobs = []
for index, fixture in enumerate(fixtures):
    variants = [('threshold020', .02), ('threshold005', .005)]
    if index % 2:
        variants.reverse()
    for variant, peak in variants:
        jobs.append(dict(fixture=fixture['id'], mode='meeting', pacing='settled',
                         workers=1, condition='normal', repeat=0, variant=variant,
                         parameters=dict(meetingSpeechPeak=peak, meetingPreserveQuietAudio=False)))
manifest = {'source': original['source'], 'source_revision': original['source_revision'],
            'source_manifest_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'negativeGenerator': {'algorithm': 'NumPy PCG64; sequential draws for two uniform signals',
                                  'seed': seed, 'numpy': np.__version__, 'frames': count,
                                  'rounding': 'rint(signal * 32768), little-endian signed PCM16'},
            'fixtures': fixtures}
for name, data in [('mini-inputs.json', manifest), ('quiet-meeting.json', jobs)]:
    path = args.out / name
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    print(name, hashlib.sha256(path.read_bytes()).hexdigest())
assert len(fixtures) == 9 and len(jobs) == 18
