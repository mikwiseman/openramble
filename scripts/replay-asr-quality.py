#!/usr/bin/env python3
"""Replay a frozen text-core candidate on existing inference, without new ASR."""
import argparse
import importlib.util
import json
import subprocess
from pathlib import Path

spec = importlib.util.spec_from_file_location('quality', Path(__file__).with_name('asr-quality.py'))
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--pipeline-bin', type=Path, required=True)
    parser.add_argument('--pipeline-source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    if args.output.resolve().is_relative_to(repository):
        parser.error('per-example outputs must remain outside Git')
    manifest = quality.load_manifest(args.manifest)
    fixtures = manifest['fixtures']
    identity = json.loads((args.baseline / 'identity.json').read_text())
    if identity['manifest_sha256'] != quality.sha256(args.manifest):
        raise ValueError('baseline must use this exact frozen manifest')
    original = [json.loads(line) for line in (args.baseline / 'results.jsonl').read_text().splitlines()]
    index = quality.indexed_results(fixtures, original)
    inputs = [{'id': f['id'], 'text': index[f['id']]['raw_text']}
              for f in fixtures if index[f['id']]['status'] == 'ok']
    completed = subprocess.run([str(args.pipeline_bin)], input=''.join(json.dumps(row) + '\n' for row in inputs),
                               text=True, capture_output=True, check=True, timeout=120)
    outputs = [json.loads(line) for line in completed.stdout.splitlines()]
    mapped = {row['id']: row for row in outputs}
    if len(mapped) != len(outputs) or set(mapped) != {row['id'] for row in inputs}:
        raise ValueError('candidate must return exactly one result per successful inference')
    results = [row | ({'app_text': mapped[row['id']]['text'],
                       'replayed_text_seconds': mapped[row['id']]['seconds']}
                      if row['status'] == 'ok' else {}) for row in original]
    report = {'experiment': 'offline paired text replay; same inference and file timings',
              'baseline_identity_sha256': quality.sha256(args.baseline / 'identity.json'),
              'baseline_results_sha256': quality.sha256(args.baseline / 'results.jsonl'),
              'manifest_sha256': quality.sha256(args.manifest),
              'candidate_binary_sha256': quality.sha256(args.pipeline_bin),
              'candidate_source_sha256': quality.sha256(args.pipeline_source),
              'replay_script_sha256': quality.sha256(Path(__file__)), 'sets': {}}
    for dataset, language in sorted({(f['dataset'], f['language']) for f in fixtures}):
        selected = [f for f in fixtures if (f['dataset'], f['language']) == (dataset, language)]
        ids = {f['id'] for f in selected}
        baseline = [r for r in original if r['id'] in ids]
        candidate = [r for r in results if r['id'] in ids]
        report['sets'][f'{dataset}/{language}'] = {
            'baseline': quality.summarize(selected, baseline),
            'candidate': quality.summarize(selected, candidate),
            'paired': quality.paired_delta(selected, baseline, candidate, 'app_text'),
            'changed_outputs': sum(a.get('app_text') != b.get('app_text') for a, b in zip(baseline, candidate))}
    args.output.mkdir(parents=True, exist_ok=True)
    if (args.output / 'report.json').exists():
        raise ValueError('replay output already exists; do not overwrite an experiment')
    (args.output / 'results.jsonl').write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in results))
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({name: {'changed': item['changed_outputs'],
                            'wer_delta': item['paired']['wer_delta']} for name, item in report['sets'].items()}))


if __name__ == '__main__':
    main()
