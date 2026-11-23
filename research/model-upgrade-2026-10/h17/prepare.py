"""Prepare one language of FLEURS test speech on any system, for H17.

    python prepare.py <locale> <work directory>

The scorecard prepares its inputs with macOS's afconvert, so it cannot run on
a hosted Linux or Windows machine. This script writes the same bytes without
it: afconvert turns FLEURS's 32-bit float samples into 16-bit ones by
multiplying by 32,768 and rounding halves away from zero, and puts a 4,044
byte filler chunk before the samples. For English and Russian every file is
then checked against `research/scorecard/fleurs-full.json.gz`, and the script
stops if one differs, so the hosted machines recognize exactly the 1,422
files every earlier decision used.

For English and Russian it also builds the scorecard's long takes, and for
English the noise clips, with the scorecard's own functions, and checks them
against `research/scorecard/fixtures.json`.

Writes into the work directory:
    clips.tsv        id, path                     every utterance
    speed.tsv        id, path                     every 20th utterance
    memory.tsv       id, path                     the first 30 utterances
    extras.tsv       id, path                     takes and noise, when built
    references.tsv   id, language, reference text
    prepared.txt     what was checked
"""
import csv
import gzip
import hashlib
import json
import os
import struct
import subprocess
import sys
import tarfile
import wave
from pathlib import Path

import numpy

REPO = Path(__file__).resolve().parents[3]
REVISION = '70bb2e84b976b7e960aa89f1c648e09c59f894dd'
# SHA-256 of each language's test archive at that revision. English and
# Russian are the hashes research/product-benchmark-2026-10 pinned on 9 October.
ARCHIVES = {
    'en_us': 'd9c2e37b41aacd41bc283554a0a82b5476b36887049774ecb2819dcaaa55a356',
    'ru_ru': '8a0d6a0d23c3421f50c575bcf65d875cd19dadae2f7cabb415024f81b65178b1',
    'de_de': 'e86b42dfcdef749926cd92135045f87c25966c09e50d01c401adb04ee7d8628f',
    'es_419': '981802f6c828fd214fcf8bfc1036d80c9184b6eeb5650b3f7882f8affec046c9',
    'fr_fr': 'd23690e102f373554d1b544cd2ff1e76e4fedeb04953c0b72751a1b7c518cfdd',
    'uk_ua': '1c2a1bc5afafc576a68902f8dcc5f2c2313e454742674cfedc3a053be7418114',
}
# The October 9 selection of 100 files per language, which the takes are built from.
SELECTION_SEED = 'openramble-handy-product-cli-20261009-v1'


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def fetch(url, path):
    if not path.exists():
        subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3',
                        url, '-o', str(path) + '.part'], check=True)
        Path(str(path) + '.part').replace(path)


def float_samples(data):
    """The samples of a FLEURS file: 16 kHz, one channel, 32-bit float."""
    assert data[:4] == b'RIFF' and data[8:12] == b'WAVE'
    at, fmt, samples = 12, None, None
    while at + 8 <= len(data):
        name, size = data[at:at + 4], struct.unpack('<I', data[at + 4:at + 8])[0]
        if name == b'fmt ':
            fmt = struct.unpack('<HHIIHH', data[at + 8:at + 24])
        elif name == b'data':
            samples = numpy.frombuffer(data, dtype='<f4', count=size // 4, offset=at + 8)
        at += 8 + size + (size & 1)
    assert fmt is not None and (fmt[0], fmt[1], fmt[2], fmt[5]) == (3, 1, 16000, 32), fmt
    return samples


def as_afconvert(samples):
    """The bytes `afconvert -f WAVE -d LEI16 -r 16000 -c 1` writes for these samples."""
    scaled = samples.astype(numpy.float64) * 32768.0
    rounded = numpy.sign(scaled) * numpy.floor(numpy.abs(scaled) + 0.5)
    pcm = numpy.clip(rounded, -32768, 32767).astype('<i2').tobytes()
    header = (b'RIFF' + struct.pack('<I', 4088 + len(pcm)) + b'WAVE'
              + b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, 16000, 32000, 2, 16)
              + b'FLLR' + struct.pack('<I', 4044) + bytes(4044)
              + b'data' + struct.pack('<I', len(pcm)))
    assert len(header) == 4096
    return header + pcm


def main():
    locale, work = sys.argv[1], Path(sys.argv[2]).resolve()
    language = locale[:2]
    work.mkdir(parents=True, exist_ok=True)
    notes = []
    base = f'https://huggingface.co/datasets/google/fleurs/resolve/{REVISION}/data/{locale}/'
    fetch(base + 'test.tsv', work / 'test.tsv')
    fetch(base + 'audio/test.tar.gz', work / 'test.tar.gz')
    found = digest(work / 'test.tar.gz')
    if found != ARCHIVES[locale]:
        sys.exit(f'{locale}: the archive is {found}, expected {ARCHIVES[locale]}')
    notes.append(f'{locale}: archive SHA-256 {found} matches')

    rows = list(csv.reader((work / 'test.tsv').open(encoding='utf-8'), delimiter='\t'))
    lines = sum(1 for _ in (work / 'test.tsv').open(encoding='utf-8'))
    if len(rows) != lines or any(len(row) < 3 or not row[1].endswith('.wav') for row in rows):
        sys.exit(f'{locale}: test.tsv has {lines} lines and was read as {len(rows)} rows')
    wanted = {row[1] for row in rows}
    audio = work / 'pcm16'
    audio.mkdir(exist_ok=True)
    with tarfile.open(work / 'test.tar.gz', 'r|gz') as tar:
        for entry in tar:
            name = Path(entry.name).name
            if entry.isfile() and name in wanted:
                (audio / name).write_bytes(as_afconvert(float_samples(tar.extractfile(entry).read())))
    (work / 'test.tar.gz').unlink()

    fixtures = []
    for row in rows:
        path = audio / row[1]
        with wave.open(str(path)) as w:
            frames = w.getnframes()
        fixtures.append({'id': f'full-{locale}-{row[0]}-{row[1][:-4]}', 'language': language, 'path': str(path),
                         'file': row[1], 'audio_sha256': digest(path), 'duration_seconds': frames / 16000,
                         'reference': row[2], 'reference_sha256': hashlib.sha256(row[2].encode()).hexdigest()})
    seconds = sum(f['duration_seconds'] for f in fixtures)
    notes.append(f'{locale}: {len(fixtures)} utterances, {seconds / 3600:.2f} hours')

    if locale in ('en_us', 'ru_ru'):
        with gzip.open(REPO / 'research/scorecard/fleurs-full.json.gz', 'rt') as f:
            frozen = {x['id']: x for x in json.load(f)['fixtures'] if x['id'].startswith(f'full-{locale}-')}
        ours = {f['id']: f for f in fixtures}
        if ours.keys() != frozen.keys():
            sys.exit(f'{locale}: the utterance ids differ from fleurs-full.json.gz')
        wrong = [i for i in ours if (ours[i]['audio_sha256'], ours[i]['reference_sha256'])
                 != (frozen[i]['audio_sha256'], frozen[i]['reference_sha256'])]
        if wrong:
            sys.exit(f'{locale}: {len(wrong)} of {len(ours)} files differ from fleurs-full.json.gz, e.g. {wrong[:3]}')
        notes.append(f'{locale}: all {len(ours)} audio and reference hashes match research/scorecard/fleurs-full.json.gz')

    extras, references = [], [(f['id'], language, f['reference']) for f in fixtures]
    if locale in ('en_us', 'ru_ru'):
        os.environ['SCORECARD_ROOT'] = str(work / 'scorecard-root')
        sys.path.insert(0, str(REPO / 'scripts/scorecard'))
        import scorecard
        frozen = {x['id']: x for x in json.loads((REPO / 'research/scorecard/fixtures.json').read_text())['fixtures']}
        # The October 9 selection in its own order: 100 files ranked by a hash of their names.
        ranked = sorted(rows, key=lambda r: hashlib.sha256((SELECTION_SEED + '/' + locale + '/' + r[1]).encode()).hexdigest())
        by_file = {f['file']: f for f in fixtures}
        pool, cursor = [by_file[r[1]] for r in ranked[:100]], 0
        for target in (30, 60, 120):
            parts = []
            while sum(p['duration_seconds'] + 0.5 for p in parts) < target:
                parts.append(pool[cursor % len(pool)])
                cursor += 1
            name = f'take-{language}-{target}s'
            path = work / 'extras' / f'{name}.wav'
            scorecard.compose(parts, path)
            same = digest(path) == frozen[name]['audio_sha256']
            notes.append(f'{name}: {"matches" if same else "DIFFERS FROM"} research/scorecard/fixtures.json')
            if not same:
                sys.exit(notes[-1])
            extras.append((name, path))
            references.append((name, language, ' '.join(p['reference'] for p in parts)))
        if locale == 'en_us':
            for name, samples in scorecard.noise_clips():
                path = work / 'extras' / f'noise-{name}.wav'
                scorecard.write_wav(path, samples)
                same = digest(path) == frozen[f'noise-{name}']['audio_sha256']
                # Generated from a seed with this system's math library; a
                # last-bit difference does not make noise into speech.
                notes.append(f'noise-{name}: {"matches" if same else "differs from"} research/scorecard/fixtures.json')
                extras.append((f'noise-{name}', path))
                references.append((f'noise-{name}', 'noise', ''))

    def relative(path):
        return Path(path).relative_to(work).as_posix()

    def write(name, items):
        with (work / name).open('w', encoding='utf-8', newline='\n') as f:
            for row in items:
                f.write('\t'.join(row) + '\n')

    ordered = sorted(fixtures, key=lambda f: f['id'])
    write('clips.tsv', [(f['id'], relative(f['path'])) for f in ordered])
    write('speed.tsv', [(f['id'], relative(f['path'])) for f in ordered[::20]])
    write('memory.tsv', [(f['id'], relative(f['path'])) for f in ordered[:30]])
    write('extras.tsv', [(name, relative(path)) for name, path in extras])
    write('references.tsv', references)
    (work / 'prepared.txt').write_text('\n'.join(notes) + '\n', encoding='utf-8')
    print('\n'.join(notes))


if __name__ == '__main__':
    main()
