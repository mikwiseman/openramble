#!/usr/bin/env python3
"""One-pass quality comparison of the current local runtime and app text core.

Audio, references and per-example transcripts remain in the explicit local
output directory. The Markdown report contains aggregates only. Nothing here
uploads audio or text. August's paired timing helpers are reused, but its
retired serve-jsonl inference protocol is not.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import random
import selectors
import subprocess
import time
import unicodedata
from collections import defaultdict
from pathlib import Path

_spec = importlib.util.spec_from_file_location('legacy_benchmark', Path(__file__).with_name('benchmark-local-asr.py'))
_legacy = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_legacy)
sha256 = _legacy.sha256
percentile = _legacy.percentile
host_identity = _legacy.host_identity


def text_hash(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def normalize(text):
    text = unicodedata.normalize('NFC', text).lower().replace('ё', 'е')
    return ' '.join(''.join(c if c.isalnum() else ' ' for c in text).split())


def edit_counts(reference, hypothesis):
    # Deterministic Levenshtein alignment. Prefer a substitution on ties, then
    # a deletion, then an insertion. Counts always sum to the edit distance.
    previous = [(i, 0, 0, i) for i in range(len(hypothesis) + 1)]
    for i, a in enumerate(reference, 1):
        current = [(i, 0, i, 0)]
        for j, b in enumerate(hypothesis, 1):
            cost, substitutions, deletions, insertions = previous[j-1]
            diagonal = (cost + (a != b), substitutions + (a != b), deletions, insertions)
            cost, substitutions, deletions, insertions = previous[j]
            deletion = (cost+1, substitutions, deletions+1, insertions)
            cost, substitutions, deletions, insertions = current[j-1]
            insertion = (cost+1, substitutions, deletions, insertions+1)
            current.append(min((diagonal, deletion, insertion), key=lambda value: value[0]))
        previous = current
    _, substitutions, deletions, insertions = previous[-1]
    return {'substitutions': substitutions, 'deletions': deletions,
            'insertions': insertions, 'reference_units': len(reference)}


def score(reference, hypothesis):
    ref, hyp = normalize(reference), normalize(hypothesis)
    word = edit_counts(ref.split(), hyp.split())
    char = edit_counts(list(ref.replace(' ', '')), list(hyp.replace(' ', '')))
    return {'word': word, 'character': char}


def indexed_results(fixtures, results):
    expected = {f['id'] for f in fixtures}
    index = {r['id']: r for r in results}
    if len(index) != len(results) or set(index) != expected:
        raise ValueError('results must contain exactly one outcome for every frozen fixture')
    return index


def total_score(scores):
    total = {key: sum(row[key] for row in scores) for key in ('substitutions', 'deletions', 'insertions', 'reference_units')}
    total['rate'] = ((total['substitutions'] + total['deletions'] + total['insertions'])
                     / total['reference_units'] if total['reference_units'] else None)
    return total


def summarize(fixtures, results):
    index = indexed_results(fixtures, results)
    report = {'examples': len(fixtures), 'groups': len({f['group_id'] for f in fixtures}),
              'failures': sum(index[f['id']]['status'] != 'ok' for f in fixtures)}
    for lane, field in (('raw', 'raw_text'), ('app', 'app_text')):
        scores = [score(f['reference'], index[f['id']].get(field, '') if index[f['id']]['status'] == 'ok' else '') for f in fixtures]
        words = total_score([s['word'] for s in scores])
        characters = total_score([s['character'] for s in scores])
        words['wer'] = words.pop('rate')
        words['cer'] = characters['rate']
        report[lane] = words
    timing = [index[f['id']]['wall_seconds'] for f in fixtures
              if index[f['id']]['status'] == 'ok' and 'wall_seconds' in index[f['id']]]
    report['timed_successes'] = len(timing)
    report['wall_seconds'] = {name: percentile(timing, p) for name, p in (('p50', .5), ('p95', .95), ('max', 1))} if timing else None
    report['latency_scope'] = 'per-file decode + app recognition; excludes model load, GUI, microphone and insertion'
    report['failure_quality_policy'] = 'empty hypothesis (all reference units deleted); outcomes also reported separately'
    return report


def paired_delta(fixtures, baseline, candidate, field, resamples=2000, seed=20260930):
    a, b = indexed_results(fixtures, baseline), indexed_results(fixtures, candidate)
    groups = defaultdict(lambda: [0, 0, 0])
    for fixture in fixtures:
        def errors(result):
            hyp = result.get(field, '') if result['status'] == 'ok' else ''
            counts = score(fixture['reference'], hyp)['word']
            return counts['substitutions'] + counts['deletions'] + counts['insertions']
        group = groups[fixture['group_id']]
        group[0] += errors(a[fixture['id']])
        group[1] += errors(b[fixture['id']])
        group[2] += len(normalize(fixture['reference']).split())
    values = list(groups.values())
    def delta(rows):
        denominator = sum(r[2] for r in rows)
        return sum(r[1] - r[0] for r in rows) / denominator if denominator else 0
    rng = random.Random(seed)
    estimates = [delta([values[rng.randrange(len(values))] for _ in values]) for _ in range(resamples)]
    return {'wer_delta': delta(values), 'wer_delta_ci95': [percentile(estimates, .025), percentile(estimates, .975)],
            'independent_groups': len(values), 'method': 'paired bootstrap of source groups; word-weighted WER',
            'resamples': resamples, 'seed': seed}


def load_manifest(path):
    manifest = json.loads(path.read_text())
    if manifest.get('schema_version') != 1 or not manifest.get('fixtures'):
        raise ValueError('expected nonempty schema 1 manifest')
    ids, audio = set(), set()
    for fixture in manifest['fixtures']:
        for key in ('id', 'group_id', 'dataset', 'split', 'language', 'path', 'audio_sha256', 'reference', 'reference_sha256'):
            if not isinstance(fixture.get(key), str) or not fixture[key]:
                raise ValueError(f'fixture requires {key}')
        if fixture['language'] not in ('en', 'ru', 'mixed') or fixture['id'] in ids:
            raise ValueError('duplicate fixture or unsupported language')
        if sha256(Path(fixture['path'])) != fixture['audio_sha256']:
            raise ValueError(f"changed audio: {fixture['id']}")
        if text_hash(fixture['reference']) != fixture['reference_sha256']:
            raise ValueError(f"changed reference: {fixture['id']}")
        if fixture['audio_sha256'] in audio:
            raise ValueError('duplicate canonical audio must not count as independent examples')
        ids.add(fixture['id']); audio.add(fixture['audio_sha256'])
    return manifest


def check_resume(previous, current):
    if previous != current:
        raise ValueError('resume identity changed; use a new output directory')


def atomic_json(path, document):
    temporary = path.with_suffix(path.suffix + '.part')
    temporary.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def read_line(process, selector, timeout):
    # A readable pipe may contain only half a JSON row. A blocking readline
    # would then evade the timeout; retain complete and partial rows ourselves.
    buffer = getattr(process, '_quality_buffer', bytearray())
    process._quality_buffer = buffer
    deadline = time.monotonic() + timeout
    while True:
        newline = buffer.find(b'\n')
        if newline >= 0:
            line = bytes(buffer[:newline]); del buffer[:newline+1]
            return json.loads(line)
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not selector.select(remaining):
            raise TimeoutError('runtime did not complete within the per-example timeout')
        chunk = os.read(process.stdout.fileno(), 65536)
        if not chunk:
            raise RuntimeError('runtime exited before completing its frozen series')
        buffer.extend(chunk)


def run(args):
    manifest = load_manifest(args.manifest)
    fixtures = manifest['fixtures']
    model = next(args.model_dir.glob('*.gguf'))
    if len(list(args.model_dir.glob('*.gguf'))) != 1:
        raise ValueError('model directory must contain exactly one GGUF')
    if sha256(model) != args.model_sha256:
        raise ValueError('model hash differs from predeclared configuration')
    root = Path(__file__).resolve().parents[1]
    identity = {'schema_version': 1, 'manifest_sha256': sha256(args.manifest), 'model_sha256': args.model_sha256,
                'model_id': args.model_id, 'model_revision': args.model_revision, 'threads': args.threads,
                'asr_binary_sha256': sha256(args.asr_bin), 'pipeline_binary_sha256': sha256(args.pipeline_bin),
                'benchmark_sources': {p: sha256(root / p) for p in (
                    'scripts/asr-quality.py', 'scripts/prepare-asr-quality.py',
                    'Packages/LocalASR/Sources/asr-bench/QualityBenchmark.swift',
                    'core/ramble-text/examples/quality_pipeline.rs')},
                'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
                'pipeline_sources': {p: sha256(root / p) for p in (
                    'apps/macos/OpenRamble/System/SharedCorePipeline.swift',
                    'apps/macos/OpenRamble/System/SettingsDefaults.swift',
                    'core/ramble-ffi/src/lib.rs', 'core/ramble-text/src/pipeline.rs',
                    'core/conformance/fixtures/text/starter-dictionary.json')},
                'app_settings': {'starter_dictionary': True, 'personal_dictionary': False, 'phonetic_matching': True,
                                 'allow_press_return': False, 'trailing_space': False},
                'normalization': 'NFC lowercase yo=ye punctuation+whitespace; preserves script and digits',
                'host': host_identity(), 'timeout_seconds': args.timeout}
    args.output.mkdir(parents=True, exist_ok=True)
    identity_path = args.output / 'identity.json'
    results_path = args.output / 'results.jsonl'
    completed = []
    if identity_path.exists():
        if not args.resume: raise ValueError('output already exists; use --resume or a new directory')
        check_resume(json.loads(identity_path.read_text()), identity)
        if results_path.exists(): completed = [json.loads(line) for line in results_path.read_text().splitlines()]
        if len({r['id'] for r in completed}) != len(completed) or any(r['id'] not in {f['id'] for f in fixtures} for r in completed):
            raise ValueError('invalid checkpoint')
    else:
        atomic_json(identity_path, identity)
    pending = [f for f in fixtures if f['id'] not in {r['id'] for r in completed}]
    process_status = {'status':'checkpoint_complete' if not pending else 'running'}
    if pending:
        pending_path = args.output / 'pending.json'
        atomic_json(pending_path, {'fixtures': [{k: f[k] for k in ('id', 'path')} for f in pending]})
        environment = os.environ | {'WAI_ASR_MODEL_DIR': str(args.model_dir)}
        selector = selectors.DefaultSelector()
        with (args.output / 'runtime.log').open('ab') as stderr, results_path.open('a') as output:
            engine = subprocess.Popen([str(args.asr_bin), 'quality-benchmark', str(pending_path), str(args.threads)],
                                      env=environment, stdout=subprocess.PIPE, stderr=stderr, bufsize=0)
            pipeline = subprocess.Popen([str(args.pipeline_bin)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, bufsize=0)
            selector.register(engine.stdout, selectors.EVENT_READ)
            try:
                ready = read_line(engine, selector, args.timeout)
                if ready.get('type') != 'ready': raise ValueError('missing runtime load identity')
                atomic_json(args.output / f'load-{time.time_ns()}.json', ready)
                for fixture in pending:
                    row = read_line(engine, selector, args.timeout)
                    if row.get('id') != fixture['id'] or row.get('type') != 'result':
                        raise ValueError('runtime result order or identity mismatch')
                    if row['status'] == 'ok':
                        pipeline.stdin.write((json.dumps({'id': row['id'], 'text': row['raw_text']}) + '\n').encode()); pipeline.stdin.flush()
                        # Pipeline execution is small and synchronous; bound it too.
                        with selectors.DefaultSelector() as psel:
                            psel.register(pipeline.stdout, selectors.EVENT_READ)
                            processed = read_line(pipeline, psel, 10)
                        if processed['id'] != row['id']: raise ValueError('pipeline identity mismatch')
                        row['app_text'] = processed['text']; row['app_command'] = processed['command']
                        row['pipeline_seconds'] = processed['seconds']
                        if fixture.get('pcm_sha256') and row.get('pcm_sha256') and fixture['pcm_sha256'] != row['pcm_sha256']:
                            raise ValueError('canonical PCM differs between preparation and inference')
                    # Score after the model process exits. Character alignment
                    # during inference would compete for the CPU being timed.
                    output.write(json.dumps(row, ensure_ascii=False) + '\n'); output.flush(); os.fsync(output.fileno())
                    completed.append(row)
                    if len(completed) % 50 == 0: print(f'{args.model_id}: {len(completed)}/{len(fixtures)}', flush=True)
                final = read_line(engine, selector, 10)
                if final.get('type') != 'complete': raise ValueError('missing process completion')
                atomic_json(args.output / 'complete.json', final)
                engine.wait(timeout=10)
                if engine.returncode: raise RuntimeError('runtime failed on teardown')
                process_status = {'status':'ok', 'engine_exit_code':engine.returncode, **final}
            except (TimeoutError, RuntimeError) as error:
                # A process timeout affects the remaining series. Preserve every
                # missing outcome; an operator may explicitly retry in a NEW run.
                status = 'timeout' if isinstance(error, TimeoutError) else 'process_error'
                process_status = {'status':status, 'error':str(error)}
                done = {r['id'] for r in completed}
                for fixture in pending:
                    if fixture['id'] in done: continue
                    row = {'id': fixture['id'], 'status': status}
                    completed.append(row); output.write(json.dumps(row) + '\n')
                output.flush(); os.fsync(output.fileno())
            finally:
                selector.close()
                for process in (engine, pipeline):
                    if process.poll() is None:
                        process.terminate()
                        try: process.wait(timeout=10)
                        except subprocess.TimeoutExpired: process.kill(); process.wait()
        atomic_json(args.output/'process-status.json', process_status)
    elif (args.output/'process-status.json').exists():
        process_status = json.loads((args.output/'process-status.json').read_text())
    report = {'identity': identity, 'process': process_status, 'overall': summarize(fixtures, completed), 'sets': {}}
    loads = sorted(args.output.glob('load-*.json'))
    report['loads'] = [json.loads(path.read_text()) for path in loads]
    for dataset, language in sorted({(f['dataset'], f['language']) for f in fixtures}):
        selected = [f for f in fixtures if (f['dataset'], f['language']) == (dataset, language)]
        ids = {f['id'] for f in selected}
        report['sets'][f'{dataset}/{language}'] = summarize(selected, [r for r in completed if r['id'] in ids])
    atomic_json(args.output / 'report.json', report)
    write_markdown(args.output / 'REPORT.md', {args.model_id: report})
    return report


def write_markdown(path, reports, comparisons=None):
    lines = ['# Local ASR quality', '', 'One quality pass per frozen example. Errors remain in the denominator.', '',
             '| Model / set | N | Failures | Raw WER | App WER | Raw CER | App CER | File p50 / p95 s |',
             '|---|---:|---:|---:|---:|---:|---:|---:|']
    for model, report in reports.items():
        for dataset, row in report['sets'].items():
            timing = row['wall_seconds']; wall = f"{timing['p50']:.3f} / {timing['p95']:.3f}" if timing else 'unavailable'
            percent = lambda value: f'{100*value:.2f}%' if value is not None else 'unavailable'
            lines.append(f"| {model} / {dataset} | {row['examples']} | {row['failures']} | {percent(row['raw']['wer'])} | {percent(row['app']['wer'])} | {percent(row['raw']['cer'])} | {percent(row['app']['cer'])} | {wall} |")
    lines += ['', 'File timing includes decode and recognition. It does not measure Stop→insertion, microphone or GUI.',
              'Peak memory is the high-water mark of one fresh process per model, never a per-file increment.',
              'Public, synthetic and private sources must use separate manifests and reports.', '']
    lines += ['| Model | Process status | Load / warm-up s | Process peak MiB |', '|---|---|---:|---:|']
    for model, report in reports.items():
        loads = report.get('loads', [])
        load = loads[0] if loads else {}
        timing = f"{load['load_seconds']:.3f} / {load['warmup_seconds']:.3f}" if load else 'unavailable'
        process = report.get('process', {})
        peak = process.get('process_peak_memory_bytes')
        lines.append(f"| {model} | {process.get('status','unavailable')} | {timing} | {peak / 1048576:.1f} |" if peak else
                     f"| {model} | {process.get('status','unavailable')} | {timing} | unavailable |")
    lines.append('')
    if comparisons:
        lines += ['Paired WER differences (candidate minus baseline), grouped by source:', '', '| Candidate / set / lane | ΔWER pp | 95% interval pp | Groups |', '|---|---:|---:|---:|']
        for name, data in comparisons.items():
            lower, upper = data['wer_delta_ci95']
            lines.append(f"| {name} | {100*data['wer_delta']:.2f} | [{100*lower:.2f}, {100*upper:.2f}] | {data['independent_groups']} |")
    path.write_text('\n'.join(lines)+'\n')


def compare(args):
    fixtures = load_manifest(args.manifest)['fixtures']
    reports, outputs = {}, {}
    for directory in args.runs:
        report = json.loads((directory / 'report.json').read_text())
        if report['identity']['manifest_sha256'] != sha256(args.manifest): raise ValueError('different manifests')
        model = report['identity']['model_id']
        if model in reports: raise ValueError('model IDs must be unique')
        reports[model] = report
        outputs[model] = [json.loads(line) for line in (directory/'results.jsonl').read_text().splitlines()]
    baseline = next(iter(reports)); comparisons = {}
    for model in list(reports)[1:]:
        for dataset, language in sorted({(f['dataset'], f['language']) for f in fixtures}):
            selected = [f for f in fixtures if (f['dataset'], f['language']) == (dataset, language)]
            ids = {f['id'] for f in selected}
            for lane, field in (('raw', 'raw_text'), ('app', 'app_text')):
                comparisons[f'{model}/{dataset}/{language}/{lane}'] = paired_delta(selected,
                    [r for r in outputs[baseline] if r['id'] in ids], [r for r in outputs[model] if r['id'] in ids], field)
    args.output.mkdir(parents=True, exist_ok=True)
    atomic_json(args.output/'comparison.json', {'baseline': baseline, 'reports': reports, 'paired': comparisons})
    write_markdown(args.output/'REPORT.md', reports, comparisons)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    run_parser = commands.add_parser('run')
    for flag in ('manifest', 'asr-bin', 'pipeline-bin', 'model-dir', 'output'):
        run_parser.add_argument('--'+flag, required=True, type=Path)
    for flag in ('model-id', 'model-revision', 'model-sha256'):
        run_parser.add_argument('--'+flag, required=True)
    run_parser.add_argument('--threads', required=True, type=int)
    run_parser.add_argument('--timeout', type=float, default=300)
    run_parser.add_argument('--resume', action='store_true')
    compare_parser = commands.add_parser('compare')
    compare_parser.add_argument('--manifest', type=Path, required=True)
    compare_parser.add_argument('--runs', type=Path, nargs='+', required=True)
    compare_parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'run':
        if args.threads <= 0 or not math.isfinite(args.timeout) or args.timeout <= 0: parser.error('positive threads and timeout required')
        run(args)
    else: compare(args)


if __name__ == '__main__':
    main()
