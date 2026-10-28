"""The runtime spike's measurements: the same audio through every runtime.

    uv run --with jiwer==4.0.0 python -I measure.py prepare
    uv run --with jiwer==4.0.0 python -I measure.py run ROUND [CONFIG...]
    uv run --with jiwer==4.0.0 python -I measure.py report

Two sets, each led by a warm-up row that is dropped from every number:

- fleurs200: the scorecard's frozen 100 English and 100 Russian FLEURS test
  utterances, 3 to 30 s each. Accuracy and short-clip latency.
- long30: 15 English and 15 Russian clips of 25 to 29.5 s, each a run of
  whole FLEURS utterances (not in fleurs200) joined by 0.5 s of silence.
  OpenRamble hands the engine pieces of at most 30 s, so this is the longest
  input any runtime would see from the app, and the one where a 15 s window
  or a dropped clause would show.

Each configuration runs as its own process under /usr/bin/time -l, only when
the Mac is quiet (the scorecard's rule), and one at a time.
"""
from __future__ import annotations

import json
import os
import re
import statistics
import subprocess
import sys
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / 'scripts/scorecard'))
import scorecard  # noqa: E402

SPIKE = Path(os.environ.get('SPIKE_ROOT', Path.home() / 'Library/Caches/OpenRambleSpike'))
INPUTS = Path.home() / 'Library/Caches/OpenRambleScorecard/scorecard-inputs.json'
GGUF = Path.home() / 'Library/Caches/OpenRambleScorecard/models/parakeet-ultra-Q4_K_M/parakeet-ultra-Q4_K_M.gguf'
TCPP = SPIKE / 'transcribe-cpp/runner'  # runners/transcribe-cpp/runner.c, linked to the fork's framework
DATA = HERE / 'data'
WARMUP = {'id': '__warmup__', 'path': str(HERE / 'smoke/en.wav')}

CONFIGS = {
    'tcpp-metal': [str(TCPP), '--model', str(GGUF), '--backend', 'metal', '--threads', '1'],
    'tcpp-cpu': [str(TCPP), '--model', str(GGUF), '--backend', 'cpu', '--threads', '4'],
    'sherpa-cpu': [str(SPIKE / 'sherpa-onnx/venv/bin/python'), '-I', str(HERE / 'runners/sherpa_onnx_runner.py'),
                   '--model', 'ultra-int8', '--threads', '4'],
    'mlx-gpu': [str(SPIKE / 'parakeet-mlx/venv/bin/python'), '-I', str(HERE / 'runners/parakeet_mlx_runner.py'),
                '--model', 'ultra', '--dtype', 'float16'],
    'fluidaudio-ane': [str(SPIKE / 'fluidaudio/build/release/fluidaudio-runner'), '--model', 'ultra', '--units', 'ane'],
}


def prepare():
    inputs = json.loads(INPUTS.read_text())
    rows = {'fleurs200': [{'id': r['id'], 'path': r['path'], 'language': r['language'],
                           'reference': r['reference']} for r in inputs['fleurs']]}
    taken = {Path(r['path']).stem for r in inputs['fleurs']}
    long30 = []
    for language in ('en', 'ru'):
        pool = sorted((r for r in inputs['fleurs_full'] if r['language'] == language
                       and Path(r['path']).stem not in taken), key=lambda r: r['id'])
        clip, seconds = [], 0.0
        for row in pool:
            if seconds + row['duration_seconds'] + 0.5 > 29.5:
                if seconds >= 25:
                    long30.append((language, clip))
                clip, seconds = [], 0.0
                if sum(1 for lang, _ in long30 if lang == language) == 15:
                    break
            clip.append(row)
            seconds += row['duration_seconds'] + 0.5
    rows['long30'] = []
    for n, (language, parts) in enumerate(long30):
        path = SPIKE / 'clips' / f'long30-{language}-{n:02d}.wav'
        seconds = scorecard.compose(parts, path)
        rows['long30'].append({'id': path.stem, 'path': str(path), 'language': language,
                               'reference': ' '.join(p['reference'] for p in parts),
                               'parts': [p['id'] for p in parts], 'seconds': seconds,
                               'audio_sha256': scorecard.digest(path)})
    DATA.mkdir(exist_ok=True)
    for name, items in rows.items():
        (DATA / f'{name}.json').write_text(json.dumps(items, ensure_ascii=False, indent=1) + '\n')
        with (SPIKE / f'{name}.manifest.jsonl').open('w') as out:
            for item in [WARMUP] + items:
                out.write(json.dumps({'id': item['id'], 'path': item['path']}) + '\n')
        print(name, len(items), 'rows', f"{sum(i.get('seconds') or 0 for i in items):.0f} s composed")


def footprint(log: str) -> dict:
    found = {}
    for key, pattern in {'max_rss_bytes': r'(\d+)\s+maximum resident set size',
                         'peak_footprint_bytes': r'(\d+)\s+peak memory footprint',
                         'process_seconds': r'([\d.]+) real'}.items():
        match = re.search(pattern, log)
        found[key] = float(match.group(1)) if match else None
    return found


def run(round_name: str, names):
    for name in names or CONFIGS:
        for suite in ('fleurs200', 'long30'):
            out = DATA / 'runs' / round_name / f'{name}-{suite}.jsonl'
            if out.exists():
                continue
            out.parent.mkdir(parents=True, exist_ok=True)
            quiet = scorecard.wait_for_quiet()
            before = scorecard.snapshot()
            command = ['/usr/bin/time', '-l'] + CONFIGS[name] + [str(SPIKE / f'{suite}.manifest.jsonl'), str(out) + '.part']
            done = subprocess.run(command, capture_output=True, text=True)
            log = done.stderr
            (out.parent / f'{name}-{suite}.log').write_text('\n'.join(
                line for line in log.splitlines() if not line.startswith(('ggml_', 'parakeet@'))) + '\n')
            if done.returncode != 0:
                sys.exit(f'{name} {suite} failed ({done.returncode}); see the log')
            meta = {'id': '__process__', 'quiet': quiet, 'before': before, 'after': scorecard.snapshot(),
                    **footprint(log)}
            with open(str(out) + '.part', 'a') as part:
                part.write(json.dumps(meta) + '\n')
            os.replace(str(out) + '.part', out)
            print(round_name, name, suite, 'done', flush=True)


def lost_words(reference: str, hypothesis: str) -> int:
    import jiwer
    out = jiwer.process_words(scorecard.norm(reference), scorecard.norm(hypothesis))
    return sum(c.ref_end_idx - c.ref_start_idx for c in out.alignments[0]
               if c.type == 'delete' and c.ref_end_idx - c.ref_start_idx >= 3)


def load(round_name, name, suite):
    path = DATA / 'runs' / round_name / f'{name}-{suite}.jsonl'
    rows = [json.loads(line) for line in path.open()] if path.exists() else []
    return {r['id']: r for r in rows}


def report():
    sets = {suite: json.loads((DATA / f'{suite}.json').read_text()) for suite in ('fleurs200', 'long30')}
    rounds = sorted(p.name for p in (DATA / 'runs').iterdir() if p.is_dir())
    summary = {}
    for name in CONFIGS:
        entry = summary[name] = {}
        for suite, items in sets.items():
            got = [load(r, name, suite) for r in rounds]
            got = [g for g in got if g]
            if not got:
                continue
            first = got[0]
            for language in ('en', 'ru'):
                pairs = [(i['reference'], first[i['id']]['text']) for i in items if i['language'] == language]
                counts = scorecard.wer_counts(pairs)
                entry[f'{suite}.{language}.wer'] = counts['wer']
                entry[f'{suite}.{language}.lost'] = sum(lost_words(r, h) for r, h in pairs)
            pooled = scorecard.wer_counts([(i['reference'], first[i['id']]['text']) for i in items])
            entry[f'{suite}.wer'] = pooled['wer']
            rtf = [g[i['id']]['wall_seconds'] / g[i['id']]['audio_seconds'] for g in got for i in items]
            walls = [g[i['id']]['wall_seconds'] for g in got for i in items]
            entry[f'{suite}.wall_p50'] = statistics.median(walls)
            entry[f'{suite}.wall_p95'] = scorecard.pct(walls, 0.95)
            entry[f'{suite}.rtf_p50'] = statistics.median(rtf)
            entry[f'{suite}.first_file'] = [g['__warmup__']['wall_seconds'] for g in got]
            entry[f'{suite}.load'] = [g['__load__']['load_seconds'] for g in got]
            entry[f'{suite}.footprint_mb'] = [g['__process__']['peak_footprint_bytes'] / 2**20 for g in got]
            entry[f'{suite}.rss_mb'] = [g['__process__']['max_rss_bytes'] / 2**20 for g in got]
            entry[f'{suite}.idle'] = [g['__process__']['quiet']['cpu_idle'] for g in got]
            if len(got) > 1:
                entry[f'{suite}.same_text_across_rounds'] = sum(
                    all(g[i['id']]['text'] == first[i['id']]['text'] for g in got) for i in items)
    (DATA / 'summary.json').write_text(json.dumps(summary, indent=1) + '\n')
    print(json.dumps(summary, indent=1))


if __name__ == '__main__':
    command = sys.argv[1]
    if command == 'prepare':
        prepare()
    elif command == 'run':
        run(sys.argv[2], sys.argv[3:])
    elif command == 'report':
        report()
