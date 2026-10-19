"""OpenRamble scorecard: one command, one JSON and one HTML page per candidate.

The successor of research/product-benchmark-2026-10, not a second harness. It
keeps that study's frozen FLEURS manifest (verified hash for hash), its word
normalization, its network-denied process lane and its CPU-pressure condition,
and adds the metrics the plan's scorecard names. Read research/scorecard/README.md
for definitions, hooks and limits.

    python3 scripts/scorecard/scorecard.py prepare [--freeze]
    python3 scripts/scorecard/scorecard.py run <candidate>... [--suite NAME]...
    python3 scripts/scorecard/scorecard.py score <candidate>
    python3 scripts/scorecard/scorecard.py html
    python3 scripts/scorecard/scorecard.py compare <baseline> <candidate>

Scoring needs jiwer 4.0.0 (the Oct 9 aligner); scripts/scorecard.sh provides it.
"""
from __future__ import annotations

import argparse
import collections
import datetime
import gzip
import hashlib
import html
import json
import math
import os
import platform
import queue
import random
import re
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import threading
import time
import unicodedata
import wave
from contextlib import contextmanager
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RESEARCH = REPO / 'research/scorecard'
PRODUCT_BENCHMARK = REPO / 'research/product-benchmark-2026-10'
ROOT = Path(os.environ.get('SCORECARD_ROOT', '~/Library/Caches/OpenRambleScorecard')).expanduser()
PRIVATE = Path(os.environ.get('SCORECARD_PRIVATE', '~/.openramble')).expanduser()
PROFILE = '(version 1) (allow default) (deny network*)'
SCHEMA = 'openramble-scorecard/1'
SEED = 20261019
SHORT_TAKE_SECONDS = 15.0
QUIET_IDLE = float(os.environ.get('SCORECARD_QUIET_IDLE', '0.85'))

# ---------------------------------------------------------------------------
# Text measures. Pure functions; the unit tests pin them.

WORD = re.compile(r'[^\W_]+')


def norm(text: str) -> str:
    """The Oct 9 normalization, unchanged: NFC, lowercase, ё→е, alphanumeric runs."""
    return ' '.join(WORD.findall(unicodedata.normalize('NFC', text).lower().replace('ё', 'е')))


def mark_after(gap: str) -> str | None:
    """The sentence punctuation a gap between two words carries, if any."""
    if '?' in gap:
        return 'question'
    if any(c in gap for c in '.!…'):
        return 'period'
    if ',' in gap:
        return 'comma'
    return None


def marked_words(text: str):
    """Words in `norm` order, each with its case and the mark that follows it.

    Returns None when a word's lowercase form changes the word boundaries, so a
    caller never aligns marks against the wrong word.
    """
    source = unicodedata.normalize('NFC', text)
    matches = list(WORD.finditer(source))
    words = []
    for index, match in enumerate(matches):
        following = matches[index + 1] if index + 1 < len(matches) else None
        gap = source[match.end():following.start() if following else len(source)]
        numeric = following and gap in '.,' and match.group()[-1].isdigit() and following.group()[0].isdigit()
        words.append((match.group().lower().replace('ё', 'е'), match.group()[0].isupper(),
                      None if numeric else mark_after(gap)))
    if ' '.join(w for w, _, _ in words) != norm(text):
        return None
    return words


def script_counts(text: str) -> tuple[int, int]:
    latin = cyrillic = 0
    for ch in text:
        if ch.isalpha():
            name = unicodedata.name(ch, '')
            latin += name.startswith('LATIN')
            cyrillic += name.startswith('CYRILLIC')
    return latin, cyrillic


def wrong_script(latin: int, cyrillic: int, language: str) -> bool | None:
    """True when most letters are in the other script; None when there are none."""
    letters = latin + cyrillic
    if not letters:
        return None
    expected = latin if language == 'en' else cyrillic
    return expected / letters < 0.5


def pct(values, p):
    """The Oct 9 percentile: linear interpolation between closest ranks."""
    x = sorted(values)
    if not x:
        return None
    at = (len(x) - 1) * p
    lo, hi = int(at), math.ceil(at)
    return x[lo] + (x[hi] - x[lo]) * (at - lo)


def distribution(values):
    values = [v for v in values if v is not None]
    if not values:
        return {'n': 0}
    return {'n': len(values), 'p50': pct(values, .5), 'p95': pct(values, .95), 'p99': pct(values, .99),
            'max': max(values), 'mean': statistics.fmean(values)}


def wer_counts(pairs):
    """WER over (reference, hypothesis) pairs with jiwer 4.0.0, as on Oct 9."""
    import jiwer
    if not pairs:
        return None
    refs, hyps = [norm(r) for r, _ in pairs], [norm(h) for _, h in pairs]
    out = jiwer.process_words(refs, hyps)
    words = out.hits + out.substitutions + out.deletions
    return {'n': len(pairs), 'reference_words': words, 'wer': out.wer, 'substitutions': out.substitutions,
            'deletions': out.deletions, 'insertions': out.insertions,
            'deletion_rate': out.deletions / words if words else None,
            'insertion_rate': out.insertions / words if words else None}


def punctuation_and_case(pairs):
    """Punctuation F1 (comma, period, question) and capitalization on aligned words.

    Words are aligned exactly as WER aligns them. A reference mark on a deleted
    word is missed, a mark on an inserted word is spurious, and on an aligned
    pair a differing mark counts against both classes. Capitalization compares
    the first letter of words both sides recognized identically.
    """
    import jiwer
    classes = ('comma', 'period', 'question')
    tp, fp, fn = collections.Counter(), collections.Counter(), collections.Counter()
    case = collections.Counter()
    skipped = 0
    for reference, hypothesis in pairs:
        ref, hyp = marked_words(reference), marked_words(hypothesis)
        if ref is None or hyp is None:
            skipped += 1
            continue
        if not ref:
            continue
        if not hyp:
            chunks = [jiwer.AlignmentChunk('delete', 0, len(ref), 0, 0)]
        else:
            chunks = jiwer.process_words(' '.join(w for w, _, _ in ref), ' '.join(w for w, _, _ in hyp)).alignments[0]
        for chunk in chunks:
            if chunk.type == 'delete':
                for _, _, mark in ref[chunk.ref_start_idx:chunk.ref_end_idx]:
                    fn[mark] += bool(mark)
            elif chunk.type == 'insert':
                for _, _, mark in hyp[chunk.hyp_start_idx:chunk.hyp_end_idx]:
                    fp[mark] += bool(mark)
            else:
                for r, h in zip(ref[chunk.ref_start_idx:chunk.ref_end_idx], hyp[chunk.hyp_start_idx:chunk.hyp_end_idx]):
                    if r[2] and r[2] == h[2]:
                        tp[r[2]] += 1
                    else:
                        fn[r[2]] += bool(r[2])
                        fp[h[2]] += bool(h[2])
                    if chunk.type == 'equal':
                        case[(r[1], h[1])] += 1
    for counter in (tp, fp, fn):
        counter.pop(None, None)

    def f1(t, p, n):
        precision = t / (t + p) if t + p else None
        recall = t / (t + n) if t + n else None
        score = 2 * precision * recall / (precision + recall) if precision and recall else 0.0 if (t + p + n) else None
        return {'tp': t, 'fp': p, 'fn': n, 'precision': precision, 'recall': recall, 'f1': score}

    per_class = {c: f1(tp[c], fp[c], fn[c]) for c in classes}
    micro = f1(sum(tp.values()), sum(fp.values()), sum(fn.values()))
    macro = [per_class[c]['f1'] for c in classes if per_class[c]['f1'] is not None]
    hits = sum(case.values())
    capital = f1(case[(True, True)], case[(False, True)], case[(True, False)])
    return {'punctuation': {**per_class, 'micro_f1': micro['f1'], 'macro_f1': statistics.fmean(macro) if macro else None,
                            'skipped_pairs': skipped},
            'capitalization': {'aligned_words': hits, 'accuracy': (case[(True, True)] + case[(False, False)]) / hits if hits else None,
                               **{k: capital[k] for k in ('precision', 'recall', 'f1', 'tp', 'fp', 'fn')}}}


ANNOTATION = re.compile(r'\[[^\]]*\]|\([^)]*\)|\*[^*]*\*')


def invented_words(text: str) -> tuple[int, int]:
    """Words recognized from no speech, and bracketed annotations such as [BLANK_AUDIO].

    Annotations are counted apart: a product built on that engine strips them,
    so they are not words a person would see pasted.
    """
    annotations = len(ANNOTATION.findall(text))
    return len(norm(ANNOTATION.sub(' ', text)).split()), annotations


def edge_words(reference: str, hypothesis: str) -> tuple[bool, bool]:
    """Whether the first and the last reference word survive at the edges."""
    ref, hyp = norm(reference).split(), norm(hypothesis).split()
    if not ref:
        return True, True
    return bool(hyp) and hyp[0] == ref[0], bool(hyp) and hyp[-1] == ref[-1]


def term_recall(rows):
    """Share of expected terms found as whole normalized phrases in the output."""
    found = expected = 0
    for row in rows:
        hypothesis = f" {norm(row['text'])} "
        for term in row.get('terms', []):
            expected += 1
            found += f' {norm(term)} ' in hypothesis
    return {'terms': expected, 'found': found, 'recall': found / expected if expected else None}


# ---------------------------------------------------------------------------
# Inputs. Everything a run reads is frozen and verified before it is used.

def digest(path: Path) -> str:
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def write_wav(path: Path, samples):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(16000)
        out.writeframes(b''.join(struct.pack('<h', max(-32768, min(32767, round(s * 32767)))) for s in samples))


def scaled(samples, dbfs):
    rms = math.sqrt(sum(s * s for s in samples) / len(samples)) or 1.0
    gain = 10 ** (dbfs / 20) / rms
    return [s * gain for s in samples]


def noise_clips():
    """Clips with nothing to transcribe. Any word recognized here is invented."""
    rng = random.Random(SEED)

    def white(seconds):
        return [rng.gauss(0, 1) for _ in range(int(seconds * 16000))]

    def pink(seconds):  # Paul Kellet's economy filter
        b0 = b1 = b2 = 0.0
        out = []
        for w in white(seconds):
            b0 = 0.99765 * b0 + w * 0.0990460
            b1 = 0.96300 * b1 + w * 0.2965164
            b2 = 0.57000 * b2 + w * 1.0526913
            out.append(b0 + b1 + b2 + w * 0.1848)
        return out

    def brown(seconds):
        level, out = 0.0, []
        for w in white(seconds):
            level = 0.998 * level + w
            out.append(level)
        return out

    def hum(seconds):
        return [sum(math.sin(2 * math.pi * 50 * k * n / 16000) / k for k in (1, 2, 3, 5)) for n in range(int(seconds * 16000))]

    def clicks(seconds):
        out = [0.0] * int(seconds * 16000)
        at = 0
        while True:
            at += int(rng.uniform(0.08, 0.35) * 16000)
            if at >= len(out) - 400:
                return out
            for n in range(400):
                out[at + n] += rng.gauss(0, 1) * math.exp(-n / 60)

    return [('silence-02s', [0.0] * 32000), ('silence-10s', [0.0] * 160000), ('silence-45s', [0.0] * 720000),
            ('white-60dbfs-10s', scaled(white(10), -60)), ('white-40dbfs-10s', scaled(white(10), -40)),
            ('white-30dbfs-10s', scaled(white(10), -30)), ('white-40dbfs-45s', scaled(white(45), -40)),
            ('pink-40dbfs-10s', scaled(pink(10), -40)), ('brown-35dbfs-10s', scaled(brown(10), -35)),
            ('hum50-40dbfs-10s', scaled(hum(10), -40)), ('clicks-30dbfs-10s', scaled(clicks(10), -30))]


def compose(parts, path: Path):
    """Concatenate whole utterances with 0.5 s of silence, as the Oct 9 composites do."""
    frames = 0
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(16000)
        for part in parts:
            with wave.open(part['path']) as source:
                data = source.readframes(source.getnframes())
            out.writeframes(data)
            out.writeframes(b'\0' * 16000)
            frames += len(data) // 2 + 8000
    return frames / 16000


def generated_fixtures(fleurs):
    """Noise clips and long dictation takes, built deterministically."""
    fixtures = []
    for name, samples in noise_clips():
        path = ROOT / 'corpus/scorecard/noise' / f'{name}.wav'
        if not path.exists():
            write_wav(path, samples)
        fixtures.append({'id': f'noise-{name}', 'suite': 'noise', 'path': str(path), 'audio_sha256': digest(path),
                         'duration_seconds': len(samples) / 16000, 'reference': ''})
    for language in ('en', 'ru'):
        pool = [f for f in fleurs if f['language'] == language]
        cursor = 0
        for target in (30, 60, 120):
            parts = []
            while sum(p['duration_seconds'] + 0.5 for p in parts) < target:
                parts.append(pool[cursor % len(pool)])
                cursor += 1
            path = ROOT / 'corpus/scorecard/takes' / f'{language}-{target}s.wav'
            duration = compose(parts, path)
            fixtures.append({'id': f'take-{language}-{target}s', 'suite': 'takes', 'language': language,
                             'path': str(path), 'audio_sha256': digest(path), 'duration_seconds': duration,
                             'reference': ' '.join(p['reference'] for p in parts),
                             'components': [p['id'] for p in parts]})
    return fixtures


def fleurs_full():
    """Every FLEURS test utterance in English and Russian, for decisions that need more speech.

    Read from the same pinned archives the frozen selection came from; the
    archive hashes were checked when those were first downloaded.
    """
    import csv
    import tarfile
    fixtures = []
    for locale in ('en_us', 'ru_ru'):
        folder = ROOT / 'corpus' / locale
        rows = list(csv.reader((folder / 'test.tsv').open(), delimiter='\t'))
        source, target = folder / 'source-full', folder / 'pcm16-full'
        target.mkdir(parents=True, exist_ok=True)
        if not source.exists():
            source.mkdir()
            with tarfile.open(folder / 'test.tar.gz', 'r|gz') as tar:
                for entry in tar:
                    if entry.isfile() and entry.name.endswith('.wav'):
                        with tar.extractfile(entry) as data, (source / Path(entry.name).name).open('wb') as out:
                            out.write(data.read())
        for row in rows:
            wav = target / row[1]
            if not wav.exists():
                subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16', '-r', '16000', '-c', '1',
                                str(source / row[1]), str(wav)], check=True, capture_output=True)
            with wave.open(str(wav)) as w:
                frames = w.getnframes()
            fixtures.append({'id': f"full-{locale}-{row[0]}-{row[1][:-4]}", 'language': locale[:2], 'path': str(wav),
                             'audio_sha256': digest(wav), 'duration_seconds': frames / 16000,
                             'reference': row[2], 'reference_sha256': hashlib.sha256(row[2].encode()).hexdigest()})
    return fixtures


TERMS = REPO / 'research/term-biasing-2026-10'


def term_fixtures(freeze=False):
    """Synthetic term sentences read by the Mac's own voices. Public, so text is kept."""
    corpus = json.loads((TERMS / 'corpus.json').read_text())
    voices = corpus['voices']
    fixtures, counters = [], collections.Counter()
    for index, row in enumerate(corpus['rows']):
        language = row['language']
        voice = voices[language][counters[language] % len(voices[language])]
        counters[language] += 1
        path = ROOT / 'corpus/terms' / f'{index:03d}-{language}-{voice}.wav'
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['say', '-v', voice, '-o', str(path), '--file-format=WAVE', '--data-format=LEI16@16000',
                            row['spoken']], check=True)
        with wave.open(str(path)) as w:
            duration = w.getnframes() / w.getframerate()
        fixtures.append({'id': f'term-{index:03d}', 'language': language, 'voice': voice,
                         'split': 'dev' if index % 2 == 0 else 'test', 'path': str(path),
                         'audio_sha256': digest(path), 'duration_seconds': duration,
                         'reference': row.get('reference', row['spoken']), 'terms': row['terms']})
    frozen = TERMS / 'fixtures.json'
    public = [{k: v for k, v in f.items() if k != 'path'} for f in fixtures]
    if freeze or not frozen.exists():
        frozen.write_text(json.dumps({'note': 'Hashes of the synthetic speech on the Mac that generated it; another macOS '
                                              'voice build may produce different audio, and then the suite refuses to run.',
                                      'macos': platform.mac_ver()[0], 'fixtures': public}, ensure_ascii=False, indent=1) + '\n')
    elif json.loads(frozen.read_text())['fixtures'] != public:
        print('  term sentences differ from research/term-biasing-2026-10/fixtures.json; the terms suite is disabled')
        return []
    return fixtures


def langbug_fixtures():
    """Mik's preserved wrong-language corpus: English speech, private, never committed."""
    base = PRIVATE / 'lang-bug'
    groups = {'take': sorted(base.glob('*.wav')), 'sweep': sorted((base / 'fine/raw').glob('*.wav')),
              'varied': sorted((base / 'rate/raw').glob('*.wav')), 'perturb': sorted((base / 'perturb').glob('*.wav')),
              'pieces': sorted((base / 'pieces').glob('*.wav'))}
    fixtures = []
    for group, paths in groups.items():
        for index, path in enumerate(paths):
            fixtures.append({'id': f'langbug-{group}-{index:03d}', 'group': group, 'language': 'en',
                             'path': str(path), 'audio_sha256': digest(path), 'private': True})
    return fixtures


def hook_fixtures():
    """Private suites a person adds later; see README 'Hooks'."""
    suites = {}
    for path in sorted((PRIVATE / 'scorecard/suites').glob('*.jsonl')):
        rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        for index, row in enumerate(rows):
            row.setdefault('id', f'{path.stem}-{index:04d}')
            row['private'] = True
            row['audio_sha256'] = digest(Path(row['path']).expanduser())
        suites[path.stem] = rows
    return suites


def prepare(freeze=False):
    if not (ROOT / 'manifest.json').exists():
        env = {**os.environ, 'BENCH_ROOT': str(ROOT)}
        subprocess.run([sys.executable, '-I', str(PRODUCT_BENCHMARK / 'scripts/prepare-handy-benchmark.py')], env=env, check=True)
    if not (ROOT / 'extended-long.json').exists():
        env = {**os.environ, 'BENCH_ROOT': str(ROOT)}
        subprocess.run([sys.executable, '-I', str(PRODUCT_BENCHMARK / 'scripts/prepare-long-mono.py')], env=env, check=True)
    frozen = json.loads((PRODUCT_BENCHMARK / 'data/manifest.json').read_text())
    local = json.loads((ROOT / 'manifest.json').read_text())

    def identity(m):
        return [(f['id'], f['audio_sha256'], f.get('reference_sha256')) for f in m['fixtures'] + m['long_fixtures']]
    if identity(frozen) != identity(local):
        sys.exit('The local FLEURS corpus differs from the frozen Oct 9 manifest; refusing to measure it.')
    frozen_long = json.loads((PRODUCT_BENCHMARK / 'data/extended-long.json').read_text())['fixtures']
    local_long = json.loads((ROOT / 'extended-long.json').read_text())['fixtures']
    if [(f['id'], f['audio_sha256']) for f in frozen_long] != [(f['id'], f['audio_sha256']) for f in local_long]:
        sys.exit('The monolingual hour composites differ from the frozen Oct 9 files.')

    generated = generated_fixtures(local['fixtures'])
    committed = RESEARCH / 'fixtures.json'
    public = {'schema': SCHEMA, 'seed': SEED,
              'note': 'Generated by scorecard.py prepare from the frozen FLEURS manifest and a fixed seed.',
              'fixtures': [{k: v for k, v in f.items() if k != 'path'} for f in generated]}
    if freeze or not committed.exists():
        committed.write_text(json.dumps(public, ensure_ascii=False, indent=2) + '\n')
    elif json.loads(committed.read_text())['fixtures'] != public['fixtures']:
        sys.exit('Generated fixtures differ from research/scorecard/fixtures.json; refusing to measure them.')

    full = fleurs_full()
    identity = [{'id': f['id'], 'audio_sha256': f['audio_sha256'], 'reference_sha256': f['reference_sha256']} for f in full]
    frozen_full = RESEARCH / 'fleurs-full.json.gz'
    if freeze or not frozen_full.exists():
        with gzip.open(frozen_full, 'wt', compresslevel=9) as f:
            json.dump({'source': 'google/fleurs test, en_us and ru_ru, every utterance', 'fixtures': identity}, f)
    elif json.loads(gzip.open(frozen_full, 'rt').read())['fixtures'] != identity:
        sys.exit('The full FLEURS test set differs from research/scorecard/fleurs-full.json.gz.')

    langbug = langbug_fixtures() if (PRIVATE / 'lang-bug').exists() else []
    terms = term_fixtures(freeze) if shutil.which('say') else []
    document = {'terms': terms, 'fleurs': local['fixtures'], 'fleurs_full': full, 'hour': local['long_fixtures'] + local_long, 'generated': generated,
                'langbug': langbug, 'hooks': hook_fixtures(),
                'langbug_identity': hashlib.sha256('\n'.join(f['audio_sha256'] for f in langbug).encode()).hexdigest()}
    (ROOT / 'scorecard-inputs.json').write_text(json.dumps(document, ensure_ascii=False, indent=1) + '\n')
    print(f"inputs ready: {len(document['fleurs'])} FLEURS, {len(full)} full FLEURS, {len(document['hour'])} hour composites, "
          f"{len(generated)} generated, {len(langbug)} private language clips, {sum(map(len, document['hooks'].values()))} hook clips")
    return document


def inputs():
    return json.loads((ROOT / 'scorecard-inputs.json').read_text())


# ---------------------------------------------------------------------------
# Candidates and runners.

def candidate(name: str) -> dict:
    spec = json.loads((RESEARCH / 'candidates' / f'{name}.json').read_text())
    spec['id'] = name
    return spec


def at_root(path: str) -> Path:
    return Path(path) if path.startswith('/') else ROOT / path


def model_path(spec) -> Path:
    return at_root(spec['model']['path'])


def build_asr_bench(spec) -> Path:
    """asr-bench from the candidate's product source, with today's tool sources.

    The LocalASR and DictationCore libraries are the product at `commit`; only
    the asr-bench executable target is overlaid, so a baseline can answer the
    scorecard's requests without changing what it measures.
    """
    warm = spec['warm']
    commit = subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', warm['commit']], text=True).strip()
    runtime = at_root(warm['xcframework_zip']) if warm.get('xcframework_zip') else None
    tree = ROOT / 'builds' / (commit + (f'-{digest(runtime)[:12]}' if runtime else ''))
    binary = tree / 'Packages/LocalASR/.build/release/asr-bench'
    tool = REPO / 'Packages/LocalASR/Sources/asr-bench'
    stamp = hashlib.sha256(b''.join(p.read_bytes() for p in sorted(tool.glob('*.swift')))).hexdigest()
    if binary.exists() and (tree / '.tool-stamp').read_text() == stamp:
        return binary
    if not (tree / 'Packages').exists():
        tree.mkdir(parents=True, exist_ok=True)
        archive = subprocess.run(['git', '-C', str(REPO), 'archive', commit, 'Packages'], check=True, capture_output=True).stdout
        subprocess.run(['tar', '-x', '-C', str(tree)], input=archive, check=True)
        if runtime:
            # A runtime built from source replaces the pinned download; nothing else changes.
            subprocess.run(['unzip', '-q', str(runtime), '-d', str(tree / 'Packages/LocalASR')], check=True)
            manifest = tree / 'Packages/LocalASR/Package.swift'
            text, count = re.subn(r'\.binaryTarget\(\s*name: "CTranscribe",\s*url: "[^"]+",\s*checksum: "[0-9a-f]+"\s*\)',
                                  '.binaryTarget(name: "CTranscribe", path: "TranscribeCpp.xcframework")', manifest.read_text())
            if count != 1:
                sys.exit('Could not replace the runtime pin in Package.swift')
            manifest.write_text(text)
    target = tree / 'Packages/LocalASR/Sources/asr-bench'
    shutil.rmtree(target)
    shutil.copytree(tool, target)
    subprocess.run(['swift', 'build', '--package-path', str(tree / 'Packages/LocalASR'), '-c', 'release',
                    '--product', 'asr-bench'], check=True)
    (tree / '.tool-stamp').write_text(stamp)
    return binary


def vocabulary_env(spec):
    """Terms a candidate's engine is given, one per line, from a file in the repository."""
    if not spec.get('vocabulary'):
        return {}
    return {'WAI_ASR_VOCABULARY_FILE': str(REPO / spec['vocabulary'])}


def snapshot():
    return {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'thermal': subprocess.run(['pmset', '-g', 'therm'], capture_output=True, text=True).stdout.strip(),
            'load_average': os.getloadavg()}


def busy_lanes():
    """Other recognition processes. One model lane at a time on this Mac."""
    names = {'asr-bench', 'whisper-cli', 'openramble-cli', 'transcribe-cli', 'handy'}
    rows = subprocess.run(['ps', '-axo', 'pid=,comm='], capture_output=True, text=True).stdout.splitlines()
    busy = []
    for row in rows:
        pid, _, command = row.strip().partition(' ')
        if Path(command.strip()).name in names and int(pid) != os.getpid():
            busy.append(row.strip())
    return busy


def cpu_idle():
    """Whole-machine idle share over one second, from top."""
    sample = subprocess.run(['top', '-l', '2', '-s', '1', '-n', '0'], capture_output=True, text=True).stdout
    found = re.findall(r'([\d.]+)% idle', sample)
    return float(found[-1]) / 100 if found else 0.0


def wait_for_quiet(minimum=QUIET_IDLE, patience=3600):
    """Hold a timed block until the rest of the Mac is idle.

    Speed is measured on a shared desktop. A block starts only after two
    consecutive one-second samples show at least `minimum` of the CPUs idle,
    and the idle share it saw is recorded with every observation.
    """
    waited = 0.0
    started = time.monotonic()
    while True:
        wait_for_lane()
        first = cpu_idle()
        if first >= minimum:
            second = cpu_idle()
            if second >= minimum:
                return {'cpu_idle': min(first, second), 'waited_seconds': waited}
        if waited == 0.0:
            print(f'  waiting for a quiet Mac (idle {first:.0%}, need {minimum:.0%})', flush=True)
        time.sleep(30)
        waited = time.monotonic() - started
        if waited > patience:
            sys.exit(f'The Mac stayed busy for {patience} s; speed suites need it quiet. Rerun later; finished blocks are kept.')


@contextmanager
def pressure(count):
    """The Oct 9 load: one busy Python process per logical CPU."""
    workers = []
    try:
        for _ in range(count):
            workers.append(subprocess.Popen([sys.executable, '-c', 'while True: pass'],
                                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        if workers:
            time.sleep(3)
        yield
    finally:
        for p in workers:
            p.terminate()
        for p in workers:
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()


def max_rss(stderr: str):
    found = re.search(r'(\d+)\s+maximum resident set size', stderr)
    return int(found.group(1)) if found else None


class Serve:
    """A persistent `asr-bench serve`, network denied, measured by /usr/bin/time."""

    def __init__(self, spec, label: str, timeout=600):
        self.raw = ROOT / 'runs' / spec['id'] / 'raw'
        self.raw.mkdir(parents=True, exist_ok=True)
        self.errpath = self.raw / f'{label}.stderr'
        self.timeout = timeout
        env = {**os.environ, 'WAI_ASR_MODEL_DIR': str(model_path(spec).parent), **vocabulary_env(spec)}
        started = time.perf_counter()
        self.process = subprocess.Popen(['/usr/bin/time', '-l', '/usr/bin/sandbox-exec', '-p', PROFILE,
                                         str(build_asr_bench(spec)), 'serve'],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errpath.open('wb'),
                                        env=env, text=True, bufsize=1, start_new_session=True)
        self.lines = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()
        self.count = 0
        self.ready = self._next(lambda o: o.get('event') == 'ready')
        self.ready['process_ready_seconds'] = time.perf_counter() - started

    def _pump(self):
        for line in self.process.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def _next(self, accept):
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                line = self.lines.get(timeout=max(0.0, deadline - time.monotonic()))
            except queue.Empty:
                self.kill()
                raise TimeoutError('asr-bench serve did not answer in time')
            if line is None:
                raise RuntimeError(f'asr-bench serve exited; see {self.errpath}')
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if accept(obj):
                return obj

    def request(self, path, mode='dictation'):
        self.count += 1
        rid = str(self.count)
        started = time.perf_counter()
        self.process.stdin.write(json.dumps({'id': rid, 'path': path, 'mode': mode}) + '\n')
        self.process.stdin.flush()
        reply = self._next(lambda o: o.get('id') == rid)
        reply['roundtrip_seconds'] = time.perf_counter() - started
        return reply

    def kill(self):
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=60)
        except subprocess.TimeoutExpired:
            self.kill()
            self.process.wait()
        return max_rss(self.errpath.read_text(errors='replace'))


def run_process(spec, fixture, label, mode='dictation', timeout=7200):
    """One complete CLI process, launch to exit, network denied, as on Oct 9."""
    raw = ROOT / 'runs' / spec['id'] / 'raw'
    raw.mkdir(parents=True, exist_ok=True)
    kind = spec['process']['kind']
    stdin_payload = None
    env = dict(os.environ)
    if kind == 'openramble-cli':
        argv = [str(at_root(spec['process']['executable'])), fixture['path'], '--model-dir', str(model_path(spec).parent),
                '--format', 'json']
    elif kind == 'whisper-cli':
        argv = [str(at_root(spec['process']['executable'])), '-m', str(model_path(spec)), '-f', fixture['path'],
                '-l', spec.get('language') or 'auto', '-oj', '-of', str(raw / label)]
    elif kind == 'asr-bench':
        argv = [str(build_asr_bench(spec)), 'serve']
        env['WAI_ASR_MODEL_DIR'] = str(model_path(spec).parent)
        env.update(vocabulary_env(spec))
        stdin_payload = json.dumps({'id': '1', 'path': fixture['path'], 'mode': mode}) + '\n'
    else:
        raise ValueError(f'unknown process runner {kind}')
    argv = ['/usr/bin/time', '-l', '/usr/bin/sandbox-exec', '-p', PROFILE] + argv
    out, err = raw / f'{label}.stdout', raw / f'{label}.stderr'
    before, timed_out = snapshot(), False
    started = time.perf_counter_ns()
    with out.open('wb') as o, err.open('wb') as e:
        process = subprocess.Popen(argv, stdin=subprocess.PIPE if stdin_payload else subprocess.DEVNULL,
                                   stdout=o, stderr=e, env=env, start_new_session=True)
        if stdin_payload:
            process.stdin.write(stdin_payload.encode())
            process.stdin.close()
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            code = process.wait()
    wall = (time.perf_counter_ns() - started) / 1e9
    stdout, stderr = out.read_text(errors='replace'), err.read_text(errors='replace')
    text, ok, extra = '', False, {}
    try:
        if kind == 'openramble-cli':
            text, ok = json.loads(stdout)['text'], True
        elif kind == 'whisper-cli':
            payload = json.loads((raw / f'{label}.json').read_text())
            text, ok = ' '.join(x['text'].strip() for x in payload['transcription']), True
            timings = dict(re.findall(r'(load|total) time =\s+([\d.]+) ms', stderr))
            if len(timings) == 2:
                extra['self_reported_compute_seconds'] = (float(timings['total']) - float(timings['load'])) / 1000
        else:
            reply = next(o for o in map(_json_or_none, stdout.splitlines()) if o and o.get('id') == '1')
            text, ok = reply.get('text', ''), 'error' not in reply
            extra['engine_seconds'] = reply.get('engineSeconds')
    except (ValueError, KeyError, FileNotFoundError, StopIteration):
        pass
    return {'wall_seconds': wall, 'exit_code': code, 'timeout': timed_out, 'ok': ok and code == 0, 'text': text,
            'max_rss_bytes': max_rss(stderr), 'before': before, 'after': snapshot(), **extra}


def _json_or_none(line):
    try:
        return json.loads(line)
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# Suites. Observations are appended to runs/<candidate>/<suite>.jsonl and a
# rerun resumes; private suites keep counts and hashes, never text.

def observations(name, suite):
    path = ROOT / 'runs' / name / f'{suite}.jsonl'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []


def record(name, suite, row, fixture=None, private=False):
    """Append one observation. Private rows keep derived numbers, never text."""
    if private:
        text = row.pop('text', '')
        latin, cyrillic = script_counts(text)
        row.update({'letters_latin': latin, 'letters_cyrillic': cyrillic, 'words': len(norm(text).split()),
                    'text_sha256': hashlib.sha256(norm(text).encode()).hexdigest()})
        if fixture and fixture.get('reference'):
            row['wer'] = wer_counts([(fixture['reference'], text)])
            row['edges'] = edge_words(fixture['reference'], text)
        if fixture and fixture.get('terms'):
            row['terms'] = term_recall([{'text': text, 'terms': fixture['terms']}])
    path = ROOT / 'runs' / name / f'{suite}.jsonl'
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as f:
        f.write(json.dumps(row, ensure_ascii=False) + '\n')


def recognize_all(spec, suite, fixtures, mode='dictation', private=False):
    """Recognize each fixture once, warm when the candidate has a warm lane."""
    done = {r['fixture'] for r in observations(spec['id'], suite)}
    todo = [f for f in fixtures if f['id'] not in done]
    if not todo:
        return
    print(f"{spec['id']} {suite}: {len(todo)} inputs", flush=True)
    if spec.get('warm'):
        serve = Serve(spec, f'{suite}-{len(done)}')
        try:
            for f in todo:
                reply = serve.request(f['path'], mode)
                record(spec['id'], suite, {'fixture': f['id'], 'runner': 'warm', 'mode': mode, 'condition': 'quiet',
                                           'ok': 'error' not in reply, 'error': reply.get('error'),
                                           'text': reply.get('text', ''), 'wall_seconds': reply.get('wallSeconds'),
                                           'engine_seconds': reply.get('engineSeconds'),
                                           'audio_seconds': reply.get('audioSeconds'),
                                           'peak_memory_bytes': reply.get('peakMemoryBytes')}, f, private)
        finally:
            serve.close()
    else:
        for i, f in enumerate(todo):
            row = run_process(spec, f, f'{suite}-{f["id"]}', mode)
            row.update({'fixture': f['id'], 'runner': 'process', 'mode': mode, 'condition': 'quiet'})
            record(spec['id'], suite, row, f, private)
            if (i + 1) % 25 == 0:
                print(f'  {i + 1}/{len(todo)}', flush=True)


def speed_files(fleurs):
    files = []
    for language in ('ru', 'en'):
        rows = sorted([f for f in fleurs if f['language'] == language], key=lambda f: f['duration_seconds'])
        files.extend([rows[0], rows[len(rows) // 2], rows[-1]])
    return files


def order(block, count):
    """Candidate order for one block: a rotation, reversed every other cycle.

    Rotations advance separately within quiet and loaded blocks, so in each
    condition every candidate takes every position equally often and position
    effects do not favor anyone.
    """
    condition = conditions(block + 1)[-1]
    k = conditions(block).count(condition)
    base = [(i + k) % count for i in range(count)]
    return base[::-1] if (k // count) % 2 else base


def conditions(blocks):
    """Quiet/load blocks in ABBA order, so drift is not confounded with load."""
    return [('quiet', 'load', 'load', 'quiet')[i % 4] for i in range(blocks)]


def speed_process(specs, data, repeats=6):
    files = speed_files(data['fleurs'])
    done = set.intersection(*({(r['block'], r['fixture']) for r in observations(s['id'], 'speed-process')
                               if r['candidate_count'] == len(specs)} for s in specs))
    for block, condition in enumerate(conditions(repeats * 2)):
        if all((block, f['id']) in done for f in files):
            continue
        print(f'speed-process block {block} {condition}', flush=True)
        quiet = wait_for_quiet()
        with pressure(os.cpu_count() if condition == 'load' else 0):
            sequence = order(block, len(specs))
            for f in files:
                for index in sequence:
                    spec = specs[index]
                    row = run_process(spec, f, f'speed-{block}-{f["id"]}')
                    row.update({'fixture': f['id'], 'runner': 'process', 'condition': condition, 'block': block,
                                'order': [specs[i]['id'] for i in sequence], 'candidate_count': len(specs), **quiet})
                    record(spec['id'], 'speed-process', row)


def speed_warm(specs, data, repeats=10):
    specs = [s for s in specs if s.get('warm')]
    if not specs:
        return
    files = speed_files(data['fleurs']) + [f for f in data['generated'] if f['suite'] == 'takes']
    done = set.intersection(*({r['block'] for r in observations(s['id'], 'speed-warm')
                               if r['candidate_count'] == len(specs) and r['fixture'] == '_ready'} for s in specs))
    rng = random.Random(SEED)
    for block, condition in enumerate(conditions(repeats * 2)):
        sequence = files[:]
        rng.shuffle(sequence)
        if block in done:
            continue
        print(f'speed-warm block {block} {condition}', flush=True)
        quiet = wait_for_quiet()
        with pressure(os.cpu_count() if condition == 'load' else 0):
            for index in order(block, len(specs)):
                spec = specs[index]
                serve = Serve(spec, f'speed-warm-{block}')
                first = True
                try:
                    for f in sequence:
                        reply = serve.request(f['path'])
                        record(spec['id'], 'speed-warm', {
                            'fixture': f['id'], 'runner': 'warm', 'condition': condition, 'block': block,
                            'first_request': first, 'ok': 'error' not in reply, 'text': reply.get('text', ''),
                            'wall_seconds': reply.get('wallSeconds'), 'engine_seconds': reply.get('engineSeconds'),
                            'roundtrip_seconds': reply.get('roundtrip_seconds'), 'audio_seconds': reply.get('audioSeconds'),
                            'candidate_count': len(specs)})
                        first = False
                finally:
                    rss = serve.close()
                record(spec['id'], 'speed-warm', {'fixture': '_ready', 'block': block, 'condition': condition,
                                                  'candidate_count': len(specs), 'max_rss_bytes': rss, **quiet, **serve.ready})


SUITES = ('fleurs', 'fleurs-full', 'terms', 'noise', 'takes', 'langbug', 'hooks', 'hour', 'speed-process', 'speed-warm')


def wait_for_lane(patience=3600):
    """One model lane at a time on this Mac: wait while another one runs."""
    started = time.monotonic()
    announced = False
    while lanes := busy_lanes():
        if not announced:
            print('  waiting for another recognition process to finish:\n    ' + '\n    '.join(lanes), flush=True)
            announced = True
        if time.monotonic() - started > patience:
            sys.exit('Another recognition process kept running; one model lane at a time. Rerun later.')
        time.sleep(30)


def run(names, suites):
    wait_for_lane()
    data = inputs()
    specs = [candidate(n) for n in names]
    for spec in specs:
        for check in ('model', 'process'):
            entry = spec.get(check) or {}
            target = model_path(spec) if check == 'model' else at_root(entry['executable']) if entry.get('executable') else None
            if target and entry.get('sha256') and digest(target) != entry['sha256']:
                sys.exit(f"{spec['id']}: {target} does not match its pinned SHA-256")
        warm = spec.get('warm') or {}
        if warm.get('xcframework_zip') and digest(at_root(warm['xcframework_zip'])) != warm.get('xcframework_sha256'):
            sys.exit(f"{spec['id']}: the source-built runtime does not match its pinned SHA-256")
        session = {'started': snapshot(), 'suites': suites, 'host': host(),
                   'installed_app_running': bool(subprocess.run(['pgrep', '-x', 'OpenRamble'], capture_output=True).stdout)}
        record(spec['id'], 'sessions', session)
    for suite in suites:
        if suite == 'speed-process':
            speed_process(specs, data)
        elif suite == 'speed-warm':
            speed_warm(specs, data)
        else:
            for spec in specs:
                if suite == 'fleurs':
                    recognize_all(spec, 'fleurs', data['fleurs'])
                elif suite == 'fleurs-full':
                    recognize_all(spec, 'fleurs-full', data['fleurs_full'])
                elif suite == 'terms' and data.get('terms'):
                    recognize_all(spec, 'terms', data['terms'])
                elif suite == 'noise':
                    recognize_all(spec, 'noise', [f for f in data['generated'] if f['suite'] == 'noise'])
                elif suite == 'takes':
                    recognize_all(spec, 'takes', [f for f in data['generated'] if f['suite'] == 'takes'])
                elif suite == 'langbug' and data['langbug']:
                    recognize_all(spec, 'langbug', data['langbug'], private=True)
                elif suite == 'hooks':
                    for name, rows in data['hooks'].items():
                        if name not in HOOKS:
                            sys.exit(f'Unknown hook suite {name}; known: {", ".join(HOOKS)}')
                        recognize_all(spec, f'hook-{name}', rows, private=True)
                elif suite == 'hour':
                    hour(spec, data['hour'])


def hour(spec, fixtures):
    """Hour composites through the file-import path, once each, idle."""
    done = {r['fixture'] for r in observations(spec['id'], 'hour')}
    for f in fixtures:
        if f['id'] in done:
            continue
        print(f"{spec['id']} hour {f['id']}", flush=True)
        if spec.get('warm') and spec['process']['kind'] == 'asr-bench':
            serve = Serve(spec, f'hour-{f["id"]}', timeout=7200)
            try:
                reply = serve.request(f['path'], 'file')
            finally:
                rss = serve.close()
            row = {'ok': 'error' not in reply, 'text': reply.get('text', ''), 'wall_seconds': reply.get('wallSeconds'),
                   'max_rss_bytes': rss, 'runner': 'warm-file'}
        else:
            row = run_process(spec, f, f'hour-{f["id"]}', 'file')
            row['runner'] = 'process'
        row['fixture'] = f['id']
        record(spec['id'], 'hour', row)


def host():
    return {'hardware': subprocess.check_output(['sysctl', '-n', 'hw.model', 'machdep.cpu.brand_string', 'hw.memsize',
                                                 'hw.logicalcpu'], text=True).split('\n')[:4],
            'macos': platform.mac_ver()[0], 'pressure_workers': os.cpu_count()}


# ---------------------------------------------------------------------------
# Scoring.

def score(name):
    spec = candidate(name)
    data = inputs()
    by_id = {f['id']: f for f in data['fleurs'] + data['fleurs_full'] + data.get('terms', []) + data['hour']
             + data['generated'] + data['langbug']}
    for rows in data['hooks'].values():
        by_id.update({r['id']: r for r in rows})
    result = {'schema': SCHEMA, 'candidate': {k: v for k, v in spec.items()}, 'scored_at': snapshot()['at'],
              'sessions': observations(name, 'sessions'), 'metrics': {}, 'hooks': {}, 'evidence': {}}
    metrics = result['metrics']

    for suite, key in (('fleurs', 'fleurs'), ('fleurs-full', 'fleurs_full')):
        rows = observations(name, suite)
        if rows:
            metrics[key] = fleurs_accuracy(rows, by_id)
            metrics[f'latency_{key}_idle'] = latency_buckets(rows, by_id)
    term_rows = observations(name, 'terms')
    if term_rows:
        metrics['terms'] = {}
        for language in ('en', 'ru'):
            for split in ('dev', 'test', 'all'):
                rows = [r for r in term_rows if by_id[r['fixture']]['language'] == language
                        and split in ('all', by_id[r['fixture']]['split'])]
                metrics['terms'][f'{language}_{split}'] = {
                    **term_recall([{'text': r['text'], 'terms': by_id[r['fixture']]['terms']} for r in rows]),
                    'wer': wer_counts([(by_id[r['fixture']]['reference'], r['text']) for r in rows])}
    takes = observations(name, 'takes')
    if takes:
        metrics['long_takes'] = {r['fixture']: {'audio_seconds': by_id[r['fixture']]['duration_seconds'],
                                                **wer_counts([(by_id[r['fixture']]['reference'], r['text'])])}
                                 for r in takes}
    noise = observations(name, 'noise')
    if noise:
        per_clip = {r['fixture']: invented_words(r['text']) for r in noise}
        metrics['hallucination'] = {'clips': len(per_clip), 'clips_with_words': sum(w > 0 for w, _ in per_clip.values()),
                                    'words': sum(w for w, _ in per_clip.values()),
                                    'annotations': sum(a for _, a in per_clip.values()),
                                    'per_clip_words': {k: w for k, (w, _) in per_clip.items()},
                                    'failures': sum(not r['ok'] for r in noise)}
    langbug = observations(name, 'langbug')
    if langbug:
        groups = collections.defaultdict(lambda: {'decodes': 0, 'wrong': 0, 'empty': 0})
        for r in langbug:
            flip = wrong_script(r['letters_latin'], r['letters_cyrillic'], 'en')
            for key in (by_id[r['fixture']]['group'], 'total'):
                groups[key]['decodes'] += 1
                groups[key]['wrong'] += flip is True
                groups[key]['empty'] += flip is None
        metrics['wrong_script_private'] = {'corpus': 'Mik\'s preserved English takes, ~/.openramble/lang-bug (private)',
                                           'identity_sha256': data['langbug_identity'], **groups}
    hour_rows = observations(name, 'hour')
    if hour_rows:
        metrics['hour'] = {r['fixture']: {'audio_seconds': by_id[r['fixture']]['duration_seconds'],
                                          'wall_seconds': r['wall_seconds'], 'ok': r['ok'],
                                          'max_rss_bytes': r.get('max_rss_bytes'), 'runner': r['runner'],
                                          **wer_counts([(by_id[r['fixture']]['reference'], r['text'] if r['ok'] else '')])}
                           for r in hour_rows}
    process = observations(name, 'speed-process')
    if process:
        metrics['latency_process'] = {}
        for condition in ('quiet', 'load'):
            rows = [r for r in process if r['condition'] == condition]
            ok = [r for r in rows if r['ok']]
            entry = {'runs': len(rows), 'success': len(ok), **distribution([r['wall_seconds'] for r in ok]),
                     'max_rss_bytes': max((r['max_rss_bytes'] or 0) for r in rows)}
            if any('self_reported_compute_seconds' in r for r in ok):
                entry['self_reported_compute'] = distribution([r.get('self_reported_compute_seconds') for r in ok])
            metrics['latency_process'][condition] = entry
    warm = observations(name, 'speed-warm')
    if warm:
        ready = [r for r in warm if r['fixture'] == '_ready']
        requests = [r for r in warm if r['fixture'] != '_ready' and r['ok']]
        metrics['latency_warm'] = {condition: latency_buckets([r for r in requests if r['condition'] == condition], by_id)
                                   for condition in ('quiet', 'load')}
        metrics['latency_warm']['first_request_after_load'] = distribution(
            [r['wall_seconds'] for r in requests if r['first_request'] and r['condition'] == 'quiet'])
        metrics['load'] = {'model_load': distribution([r['loadSeconds'] for r in ready if r['condition'] == 'quiet']),
                           'warmup_inference': distribution([r['warmupSeconds'] for r in ready if r['condition'] == 'quiet']),
                           'process_to_ready': distribution([r['process_ready_seconds'] for r in ready if r['condition'] == 'quiet']),
                           'peak_rss_bytes': max((r.get('max_rss_bytes') or 0) for r in ready)}
        metrics['runner_parity'] = parity(name, by_id)
    metrics['model'] = {'bytes': model_path(spec).stat().st_size, 'sha256': spec['model'].get('sha256'),
                        'license': spec['model'].get('license')}
    result['hooks'] = hooks(name, data, by_id)
    evidence = {}
    for path in sorted((ROOT / 'runs' / name).glob('*.jsonl')):
        evidence[path.name] = digest(path)
    result['evidence'] = {'observation_sha256': evidence}
    out = RESEARCH / 'results'
    out.mkdir(parents=True, exist_ok=True)
    (out / f'{name}.json').write_text(json.dumps(result, ensure_ascii=False, indent=1) + '\n')
    public = [r for suite in ('fleurs', 'fleurs-full', 'terms', 'noise', 'takes', 'hour', 'speed-process', 'speed-warm')
              for r in ({**x, 'suite': suite} for x in observations(name, suite))]
    with gzip.open(out / f'{name}.observations.jsonl.gz', 'wt', compresslevel=9) as f:
        for row in public:
            row.pop('before', None)
            row.pop('after', None)
            f.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + '\n')
    print(f'wrote {out / (name + ".json")}')
    return result


def fleurs_accuracy(rows, by_id):
    accuracy = {}
    for language in ('en', 'ru'):
        subset = [r for r in rows if by_id[r['fixture']]['language'] == language]
        pairs = [(by_id[r['fixture']]['reference'], r['text'] if r['ok'] else '') for r in subset]
        flips = [wrong_script(*script_counts(t), language) for _, t in pairs]
        accuracy[language] = {'wer': wer_counts(pairs), **punctuation_and_case(pairs),
                              'wrong_script': {'decodes': len(flips), 'wrong': sum(f is True for f in flips),
                                               'empty': sum(f is None for f in flips)},
                              'failures': sum(not r['ok'] for r in subset)}
    words = sum(accuracy[x]['wer']['reference_words'] for x in ('en', 'ru'))
    errors = sum(accuracy[x]['wer']['wer'] * accuracy[x]['wer']['reference_words'] for x in ('en', 'ru'))
    accuracy['pooled_wer'] = errors / words if words else None
    return accuracy


def paired_bootstrap(base_name, cand_name, suite='fleurs-full', samples=10000):
    """WER difference (candidate minus baseline) with a 95% interval, resampling utterances."""
    import jiwer
    data = inputs()
    by_id = {f['id']: f for f in data['fleurs'] + data['fleurs_full']}
    texts = [{r['fixture']: (r['text'] if r['ok'] else '') for r in observations(n, suite)} for n in (base_name, cand_name)]
    shared = sorted(texts[0].keys() & texts[1].keys())
    out = {'suite': suite, 'utterances': len(shared), 'baseline': base_name, 'candidate': cand_name, 'seed': SEED}
    for language in ('en', 'ru', 'pooled'):
        ids = [k for k in shared if language == 'pooled' or by_id[k]['language'] == language]
        per = []
        for k in ids:
            ref = norm(by_id[k]['reference'])
            a, b = (jiwer.process_words(ref, norm(t[k])) for t in texts)
            words = a.hits + a.substitutions + a.deletions
            per.append((words, a.substitutions + a.deletions + a.insertions, b.substitutions + b.deletions + b.insertions))
        words = sum(p[0] for p in per)
        delta = (sum(p[2] for p in per) - sum(p[1] for p in per)) / words
        rng = random.Random(SEED)
        draws = []
        for _ in range(samples):
            pick = [per[rng.randrange(len(per))] for _ in per]
            w = sum(p[0] for p in pick)
            draws.append((sum(p[2] for p in pick) - sum(p[1] for p in pick)) / w)
        out[language] = {'utterances': len(ids), 'reference_words': words, 'baseline_wer': sum(p[1] for p in per) / words,
                         'candidate_wer': sum(p[2] for p in per) / words, 'difference': delta,
                         'ci95': [pct(draws, 0.025), pct(draws, 0.975)],
                         'utterances_better': sum(p[2] < p[1] for p in per), 'utterances_worse': sum(p[2] > p[1] for p in per)}
    return out


def latency_buckets(rows, by_id):
    rows = [r for r in rows if r.get('ok') and r.get('wall_seconds') is not None]

    def seconds(r):
        return by_id[r['fixture']].get('duration_seconds') or r.get('audio_seconds') or 0
    return {'all': distribution([r['wall_seconds'] for r in rows]),
            'short': distribution([r['wall_seconds'] for r in rows if seconds(r) < SHORT_TAKE_SECONDS]),
            'long': distribution([r['wall_seconds'] for r in rows if seconds(r) >= SHORT_TAKE_SECONDS])}


def parity(name, by_id):
    """Same input, warm lane against process lane: identical normalized text?"""
    warm = {r['fixture']: norm(r['text']) for r in observations(name, 'speed-warm') if r.get('ok') and 'text' in r}
    process = {r['fixture']: norm(r['text']) for r in observations(name, 'speed-process') if r.get('ok')}
    shared = sorted(warm.keys() & process.keys())
    return {'inputs': len(shared), 'identical': sum(warm[k] == process[k] for k in shared)}


HOOKS = {
    'term-recall': ('terms', 'Names, companies and code terms. Rows: {"path", "language", "reference", "terms": [...]}. '
                    'Record consented takes or TTS; keep audio outside Git.'),
    'code-switch': ('wer', 'RU↔EN switching inside one take. Rows: {"path", "language", "reference"}.'),
    'noise-accent': ('wer', 'MUSAN mixes at 20/10/5 dB and non-native speech. Rows: {"path", "language", "reference", "tag"}.'),
    'onset-offset': ('edges', 'Scripted takes whose first and last words sit at the clip edges. Rows: {"path", "language", "reference"}.'),
}
APP_HOOKS = {
    'insertion-matrix': 'Right app, right text, clipboard byte-exact across 12 apps. Needs the Phase 4 e2e harness driving the app.',
    'paste-timings': 'Key-up to paste p50/p95 from the local numeric journal once toPasteDispatched lands (Phase 4).',
    'energy': 'Energy per dictated minute with powermetrics; needs sudo, so it is run by hand.',
    'meaning-preservation': 'False deletions on the scripted disfluent set; owned by the Clean Verbatim work in DictationCore.',
}


def hooks(name, data, by_id):
    out = {}
    for hook, (kind, needs) in HOOKS.items():
        rows = observations(name, f'hook-{hook}')
        if not rows:
            out[hook] = {'status': 'no-data', 'needs': needs,
                         'where': str(PRIVATE / 'scorecard/suites' / f'{hook}.jsonl')}
            continue
        entry = {'status': 'measured', 'inputs': len(rows), 'failures': sum(not r['ok'] for r in rows)}
        scored = [r['wer'] for r in rows if r.get('wer')]
        if scored:
            words = sum(w['reference_words'] for w in scored)
            errors = sum(w['substitutions'] + w['deletions'] + w['insertions'] for w in scored)
            entry['wer'] = errors / words if words else None
            entry['deletion_rate'] = sum(w['deletions'] for w in scored) / words if words else None
        edges = [r['edges'] for r in rows if r.get('edges')]
        if edges:
            entry['first_word_captured'] = sum(e[0] for e in edges) / len(edges)
            entry['last_word_captured'] = sum(e[1] for e in edges) / len(edges)
        terms = [r['terms'] for r in rows if r.get('terms')]
        if terms:
            expected = sum(t['terms'] for t in terms)
            entry['term_recall'] = sum(t['found'] for t in terms) / expected if expected else None
        out[hook] = entry
    for hook, needs in APP_HOOKS.items():
        out[hook] = {'status': 'not-in-harness', 'needs': needs}
    return out


# ---------------------------------------------------------------------------
# Comparison gate and HTML.

GATES = [
    # (label, path, worse-if, absolute tolerance, relative tolerance)
    ('WER EN', ('fleurs', 'en', 'wer', 'wer'), 'higher', 0.0025, 0),
    ('WER RU', ('fleurs', 'ru', 'wer', 'wer'), 'higher', 0.0025, 0),
    ('WER full FLEURS EN', ('fleurs_full', 'en', 'wer', 'wer'), 'higher', 0.0025, 0),
    ('WER full FLEURS RU', ('fleurs_full', 'ru', 'wer', 'wer'), 'higher', 0.0025, 0),
    ('Punctuation F1 EN', ('fleurs', 'en', 'punctuation', 'micro_f1'), 'lower', 0.01, 0),
    ('Punctuation F1 RU', ('fleurs', 'ru', 'punctuation', 'micro_f1'), 'lower', 0.01, 0),
    ('Capitalization F1 EN', ('fleurs', 'en', 'capitalization', 'f1'), 'lower', 0.01, 0),
    ('Capitalization F1 RU', ('fleurs', 'ru', 'capitalization', 'f1'), 'lower', 0.01, 0),
    ('Wrong script, FLEURS EN', ('fleurs', 'en', 'wrong_script', 'wrong'), 'higher', 0, 0),
    ('Wrong script, FLEURS RU', ('fleurs', 'ru', 'wrong_script', 'wrong'), 'higher', 0, 0),
    ('Wrong script, private', ('wrong_script_private', 'total', 'wrong'), 'higher', 0, 0),
    ('Hallucinated words', ('hallucination', 'words'), 'higher', 0, 0),
    ('Hour EN deleted words', ('hour', 'en-3540s', 'deletion_rate'), 'higher', 0.005, 0),
    ('Hour RU deleted words', ('hour', 'ru-3540s', 'deletion_rate'), 'higher', 0.005, 0),
    ('Warm p50 idle', ('latency_warm', 'quiet', 'all', 'p50'), 'higher', 0.005, 0.10),
    ('Warm p95 idle', ('latency_warm', 'quiet', 'all', 'p95'), 'higher', 0.005, 0.10),
    ('Warm p95 load', ('latency_warm', 'load', 'all', 'p95'), 'higher', 0.010, 0.15),
    ('Process p50 idle', ('latency_process', 'quiet', 'p50'), 'higher', 0.010, 0.10),
    ('Process p95 load', ('latency_process', 'load', 'p95'), 'higher', 0.020, 0.15),
    ('Peak RSS', ('load', 'peak_rss_bytes'), 'higher', 0, 0.10),
    ('Model load', ('load', 'model_load', 'p50'), 'higher', 0.05, 0.20),
]


def lookup(metrics, path):
    value = metrics
    for key in path:
        if not isinstance(value, dict) or key not in value:
            return None
        value = value[key]
    return value


def compare(base_name, cand_name):
    base = json.loads((RESEARCH / 'results' / f'{base_name}.json').read_text())['metrics']
    cand = json.loads((RESEARCH / 'results' / f'{cand_name}.json').read_text())['metrics']
    regressions = []
    print(f'{"metric":28} {base_name:>22} {cand_name:>22}  verdict')
    for label, path, worse, absolute, relative in GATES:
        a, b = lookup(base, path), lookup(cand, path)
        if a is None or b is None:
            verdict = 'not compared'
        else:
            allowance = max(absolute, abs(a) * relative)
            delta = (b - a) if worse == 'higher' else (a - b)
            verdict = 'REGRESSION' if delta > allowance else 'better' if delta < 0 else 'same' if delta == 0 else 'within tolerance'
            if verdict == 'REGRESSION':
                regressions.append(label)
        print(f'{label:28} {fmt(a):>22} {fmt(b):>22}  {verdict}')
    return regressions


def fmt(value):
    if value is None:
        return '—'
    if isinstance(value, float):
        return f'{value:.4f}'
    return str(value)


ROWS = [
    # family, label, path, unit, better, target
    ('Accuracy', 'WER, FLEURS English, frozen 100', ('fleurs', 'en', 'wer', 'wer'), '%', 'lower', '≤ Whisper Turbo'),
    ('Accuracy', 'WER, FLEURS Russian, frozen 100', ('fleurs', 'ru', 'wer', 'wer'), '%', 'lower', '≤ Whisper Turbo'),
    ('Accuracy', 'WER, all FLEURS test, EN + RU', ('fleurs_full', 'pooled_wer'), '%', 'lower', ''),
    ('Accuracy', 'Punctuation F1, English', ('fleurs', 'en', 'punctuation', 'micro_f1'), '%', 'higher', 'best local'),
    ('Accuracy', 'Punctuation F1, Russian', ('fleurs', 'ru', 'punctuation', 'micro_f1'), '%', 'higher', 'best local'),
    ('Accuracy', 'Question marks F1, all FLEURS EN', ('fleurs_full', 'en', 'punctuation', 'question', 'f1'), '%', 'higher', ''),
    ('Accuracy', 'Capitalization F1, English', ('fleurs', 'en', 'capitalization', 'f1'), '%', 'higher', 'best local'),
    ('Accuracy', 'Capitalization F1, Russian', ('fleurs', 'ru', 'capitalization', 'f1'), '%', 'higher', 'best local'),
    ('Accuracy', 'WER, dictation takes of 33 to 129 s', ('long_takes',), '%', 'lower', ''),
    ('Accuracy', 'Term recall, English (synthetic voices)', ('terms', 'en_all', 'recall'), '%', 'higher', '≥ 95% after one teach'),
    ('Accuracy', 'Term recall, Russian with English terms', ('terms', 'ru_all', 'recall'), '%', 'higher', '≥ 95% after one teach'),
    ('Robustness', 'Wrong script, private English takes', ('wrong_script_private', 'total'), 'ratio', 'lower', '≤ 0.1%'),
    ('Robustness', 'Wrong script, boundary sweep (79)', ('wrong_script_private', 'sweep'), 'ratio', 'lower', ''),
    ('Robustness', 'Wrong script, FLEURS (200)', ('fleurs',), 'script', 'lower', '0'),
    ('Robustness', 'Words invented on silence and noise', ('hallucination', 'words'), 'n', 'lower', '0'),
    ('Robustness', 'Hour EN: deleted words', ('hour', 'en-3540s', 'deletion_rate'), '%', 'lower', '≤ 1%'),
    ('Robustness', 'Hour RU: deleted words', ('hour', 'ru-3540s', 'deletion_rate'), '%', 'lower', '≤ 1%'),
    ('Robustness', 'Hour RU↔EN: WER', ('hour', 'mixed-3540s', 'wer'), '%', 'lower', 'halve it'),
    ('Speed', 'Warm, short take p50 / p95', ('latency_warm', 'quiet', 'short'), 'ms', 'lower', 'p95 ≤ 250 ms'),
    ('Speed', 'Warm, long take p50 / p95', ('latency_warm', 'quiet', 'long'), 'ms', 'lower', 'p95 ≤ 400 ms'),
    ('Speed', 'Warm, 14 busy CPUs p50 / p95', ('latency_warm', 'load', 'all'), 'ms', 'lower', '≤ 1.3× idle'),
    ('Speed', 'Warm p99, idle / load', ('latency_warm',), 'p99', 'lower', ''),
    ('Speed', 'Whole process p50 / p95, idle', ('latency_process', 'quiet'), 'ms', 'lower', ''),
    ('Speed', 'Whole process p50 / p95, 14 busy CPUs', ('latency_process', 'load'), 'ms', 'lower', ''),
    ('Speed', 'Hour file, English', ('hour', 'en-3540s', 'wall_seconds'), 's', 'lower', '≤ 30 s'),
    ('Resources', 'Model load (warm file cache)', ('load', 'model_load', 'p50'), 's', 'lower', '≤ 1 s'),
    ('Resources', 'Peak resident memory', ('load', 'peak_rss_bytes'), 'GB', 'lower', '≤ 1 GB'),
    ('Resources', 'Peak memory, whole process', ('latency_process', 'quiet', 'max_rss_bytes'), 'GB', 'lower', ''),
    ('Resources', 'Model file', ('model', 'bytes'), 'MB', 'lower', ''),
]


def cell(metrics, path, unit):
    """Display text and a sortable number for one scorecard cell."""
    value = lookup(metrics, path)
    if value is None:
        return '—', None
    if unit == '%':
        if path == ('long_takes',):
            errors = sum(v['wer'] * v['reference_words'] for v in value.values())
            words = sum(v['reference_words'] for v in value.values())
            value = errors / words
        return f'{value * 100:.2f}%', value
    if unit == 'ratio':
        return f"{value['wrong']}/{value['decodes']}", value['wrong'] / value['decodes'] if value['decodes'] else None
    if unit == 'script':
        wrong = value['en']['wrong_script']['wrong'] + value['ru']['wrong_script']['wrong']
        return f'{wrong}/{value["en"]["wrong_script"]["decodes"] + value["ru"]["wrong_script"]["decodes"]}', wrong
    if unit == 'ms':
        if not value.get('n'):
            return '—', None
        return f"{value['p50'] * 1000:.0f} / {value['p95'] * 1000:.0f}", value['p95']
    if unit == 'p99':
        quiet, load = value.get('quiet', {}).get('all', {}), value.get('load', {}).get('all', {})
        if not quiet.get('n'):
            return '—', None
        loaded = f"{load['p99'] * 1000:.0f}" if load.get('n') else '—'
        return f"{quiet['p99'] * 1000:.0f} / {loaded} ms", quiet['p99']
    if unit == 's':
        return f'{value:.2f} s', value
    if unit == 'GB':
        return f'{value / 1e9:.2f} GB', value
    if unit == 'MB':
        return f'{value / 1e6:.0f} MB', value
    return str(value), value


def markdown_table(names):
    """The scorecard rows as a Markdown table, for reports."""
    results = [json.loads((RESEARCH / 'results' / f'{n}.json').read_text()) for n in names]
    lines = ['| | ' + ' | '.join(r['candidate']['label'] for r in results) + ' | Target |',
             '|---|' + '---:|' * len(results) + '---|']
    for _, label, path, unit, _, target in ROWS:
        cells = [cell(r['metrics'], path, unit)[0] for r in results]
        if all(c == '—' for c in cells):
            continue
        lines.append(f'| {label} | ' + ' | '.join(cells) + f' | {target} |')
    return '\n'.join(lines)


def transcript_diff(base_name, cand_name, suite):
    """Utterances whose normalized transcripts differ between two candidates."""
    data = inputs()
    by_id = {f['id']: f for f in data['fleurs'] + data['fleurs_full'] + data['generated'] + data['hour']}
    a = {r['fixture']: r.get('text', '') for r in observations(base_name, suite)}
    b = {r['fixture']: r.get('text', '') for r in observations(cand_name, suite)}
    shared = sorted(a.keys() & b.keys())
    differing = [{'fixture': k, 'reference': by_id[k]['reference'] if k in by_id else None,
                  base_name: a[k], cand_name: b[k], 'exact_text_differs': a[k] != b[k]}
                 for k in shared if norm(a[k]) != norm(b[k])]
    return {'suite': suite, 'compared': len(shared), 'normalized_identical': len(shared) - len(differing),
            'exact_identical': sum(a[k] == b[k] for k in shared), 'differing': differing}


def render_html():
    results = [json.loads(p.read_text()) for p in sorted((RESEARCH / 'results').glob('*.json'))]
    results = [r for r in results if r['candidate'].get('index', True)]
    results.sort(key=lambda r: r['candidate'].get('order', 99))
    head = ''.join(f"<th><span>{html.escape(r['candidate']['label'])}</span><small>{html.escape(r['candidate'].get('summary', ''))}</small></th>"
                   for r in results)
    body, family = [], None
    for fam, label, path, unit, better, target in ROWS:
        cells = [cell(r['metrics'], path, unit) for r in results]
        numbers = [n for _, n in cells if n is not None]
        best = (min(numbers) if better == 'lower' else max(numbers)) if len(numbers) > 1 else None
        if fam != family:
            body.append(f'<tr class="family"><th colspan="{len(results) + 2}">{fam}</th></tr>')
            family = fam
        tds = ''.join(f'<td class="{"best" if n is not None and n == best else ""}">{html.escape(t)}</td>' for t, n in cells)
        body.append(f'<tr><th scope="row">{html.escape(label)}</th>{tds}<td class="target">{html.escape(target)}</td></tr>')
    hook_rows = ''.join(f'<li><b>{html.escape(k)}</b> {html.escape(v["needs"])}</li>'
                        for k, v in (results[0]['hooks'].items() if results else []) if v['status'] != 'measured')
    page = PAGE.format(head=head, body='\n'.join(body), hooks=hook_rows, count=len(results),
                       date=max((r['scored_at'][:10] for r in results), default=''))
    (RESEARCH / 'index.html').write_text(page)
    print(f'wrote {RESEARCH / "index.html"}')


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>OpenRamble Scorecard</title>
<style>
:root{{--bg:#fbfaf7;--ink:#1d1b18;--muted:#6f6a62;--line:#e6e2da;--best:#0b6e4f;--best-bg:#e3f3ec;--accent:#c2410c}}
@media (prefers-color-scheme:dark){{:root{{--bg:#131211;--ink:#f1eee8;--muted:#9a948a;--line:#2b2926;--best:#5fd3a6;--best-bg:#13291f;--accent:#fb923c}}}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 ui-sans-serif,-apple-system,"SF Pro Text",system-ui,sans-serif}}
main{{max-width:1080px;margin:0 auto;padding:56px 16px 80px}}
h1{{font:600 44px/1.05 ui-serif,"New York",Georgia,serif;letter-spacing:-.02em;margin:0 0 10px}}
h1 em{{font-style:normal;color:var(--accent)}}
.lede{{color:var(--muted);max-width:60ch;margin:0 0 36px}}
.wrap{{overflow-x:auto;border-top:2px solid var(--ink)}}
table{{border-collapse:collapse;width:100%;min-width:640px;font-variant-numeric:tabular-nums}}
th,td{{padding:9px 10px;border-bottom:1px solid var(--line);text-align:right;vertical-align:top}}
thead th{{text-align:right;font-weight:600;font-size:13px;padding-top:14px}}
thead th span{{display:block}}thead th small{{display:block;color:var(--muted);font-weight:400;font-size:12px}}
thead th:first-child,tbody th{{text-align:left;font-weight:400}}
tr.family th{{text-align:left;font:600 12px/1 ui-sans-serif,system-ui;letter-spacing:.12em;text-transform:uppercase;color:var(--muted);padding-top:26px;border-bottom:1px solid var(--ink)}}
td.best{{color:var(--best);background:var(--best-bg);font-weight:600}}
td.target{{color:var(--muted);font-size:13px}}
h2{{font:600 22px/1.2 ui-serif,Georgia,serif;margin:48px 0 8px}}
ul{{padding-left:18px;color:var(--muted);max-width:75ch}}li{{margin:6px 0}}li b{{color:var(--ink);font-weight:600}}
footer{{margin-top:40px;color:var(--muted);font-size:13px;max-width:75ch}}
</style></head><body><main>
<h1>Scorecard<em>.</em></h1>
<p class="lede">{count} candidates on one Mac, one frozen corpus, one normalization. Lower is better except F1. The best value in each row is marked; a dash means the candidate cannot be measured that way. Scored through {date}.</p>
<div class="wrap"><table>
<thead><tr><th></th>{head}<th>Target</th></tr></thead>
<tbody>
{body}
</tbody></table></div>
<h2>Not measured yet</h2>
<ul>{hooks}</ul>
<footer>Speech: Google FLEURS test (CC BY 4.0), the frozen Oct 9 selection. Private wrong-script clips stay on the Mac that owns them; only counts are published. Method, limits and every input hash: research/scorecard/README.md. These are measurements on one Apple M4 Pro, not product claims.</footer>
</main></body></html>
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('prepare')
    p.add_argument('--freeze', action='store_true')
    p = sub.add_parser('run')
    p.add_argument('candidates', nargs='+')
    p.add_argument('--suite', action='append', choices=SUITES)
    p = sub.add_parser('score')
    p.add_argument('candidate')
    sub.add_parser('html')
    p = sub.add_parser('compare')
    p.add_argument('baseline')
    p.add_argument('candidate')
    p = sub.add_parser('table')
    p.add_argument('candidates', nargs='+')
    p = sub.add_parser('diff')
    p.add_argument('baseline')
    p.add_argument('candidate')
    p.add_argument('--suite', default='fleurs-full')
    p = sub.add_parser('paired')
    p.add_argument('baseline')
    p.add_argument('candidate')
    p.add_argument('--suite', default='fleurs-full', choices=('fleurs', 'fleurs-full'))
    a = parser.parse_args()
    if a.command == 'prepare':
        prepare(a.freeze)
    elif a.command == 'run':
        run(a.candidates, a.suite or list(SUITES))
    elif a.command == 'score':
        score(a.candidate)
    elif a.command == 'html':
        render_html()
    elif a.command == 'compare':
        sys.exit(1 if compare(a.baseline, a.candidate) else 0)
    elif a.command == 'table':
        print(markdown_table(a.candidates))
    elif a.command == 'diff':
        print(json.dumps(transcript_diff(a.baseline, a.candidate, a.suite), ensure_ascii=False, indent=1))
    elif a.command == 'paired':
        print(json.dumps(paired_bootstrap(a.baseline, a.candidate, a.suite), indent=1))


if __name__ == '__main__':
    main()
