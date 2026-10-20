"""Choose the vocabulary boost weight on the dev half; never look at the test half.

    uv run --with jiwer==4.0.0 python research/term-biasing-2026-10/tune.py <transcribe-cli> <model.gguf>

For each weight, one transcribe-cli process (one decoder thread, Metal, network
denied) recognizes the dev term sentences and the frozen 200 FLEURS files with
every corpus term in its vocabulary. FLEURS contains none of the terms, so any
change there is the cost of biasing. Results go to tuning.json next to this
file; transcripts of public inputs are kept so the choice can be audited.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location('scorecard', REPO / 'scripts/scorecard/scorecard.py')
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)

WEIGHTS = [0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0]


def recognize(cli, model, vocabulary, weight, fixtures):
    with tempfile.TemporaryDirectory() as work:
        listing = Path(work) / 'files.list'
        listing.write_text(''.join(f['path'] + '\n' for f in fixtures))
        terms = Path(work) / 'terms.txt'
        terms.write_text(''.join(t + '\n' for t in vocabulary))
        env = {**os.environ, 'TRANSCRIBE_VOCABULARY_BOOST': str(weight)}
        argv = ['/usr/bin/sandbox-exec', '-p', sc.PROFILE, cli, '-m', model, '--batch', str(listing), '--batch-jsonl',
                '--threads', '1', '--backend', 'metal', '-q']
        if weight > 0:
            argv += ['--vocabulary-file', str(terms)]
        out = subprocess.run(argv, env=env, capture_output=True, text=True, check=True).stdout
    rows = {r['file']: r for r in (json.loads(line) for line in out.splitlines() if line.startswith('{')) if 'file' in r}
    missing = [f['id'] for f in fixtures if f['path'] not in rows or 'error' in rows[f['path']]]
    if missing:
        sys.exit(f'transcribe-cli failed on {missing[:5]}')
    decode_ms = sum(rows[f['path']]['decode_ms'] for f in fixtures)
    return [(f, rows[f['path']]['text']) for f in fixtures], decode_ms


def main():
    cli, model = sys.argv[1], sys.argv[2]
    data = sc.inputs()
    dev = [f for f in data['terms'] if f['split'] == 'dev']
    vocabulary = sorted({t for f in data['terms'] for t in f['terms']})
    report = {'cli': cli, 'model': model, 'model_sha256': sc.digest(Path(model)), 'vocabulary': vocabulary,
              'dev_inputs': len(dev), 'fleurs_inputs': len(data['fleurs']), 'weights': {}}
    for weight in WEIGHTS:
        entry = {}
        for name, fixtures in (('dev', dev), ('fleurs', data['fleurs'])):
            texts, decode_ms = recognize(cli, model, vocabulary, weight, fixtures)
            entry[name] = {'decode_ms_total': decode_ms}
            for language in ('en', 'ru'):
                rows = [(f, t) for f, t in texts if f['language'] == language]
                entry[name][language] = {
                    'wer': sc.wer_counts([(f['reference'], t) for f, t in rows]),
                    **({'terms': sc.term_recall([{'text': t, 'terms': f['terms']} for f, t in rows])} if name == 'dev' else {})}
            entry[name]['transcripts'] = {f['id']: t for f, t in texts}
        report['weights'][str(weight)] = entry
        summary = {lang: (entry['dev'][lang]['terms']['recall'], entry['dev'][lang]['wer']['wer'],
                          entry['fleurs'][lang]['wer']['wer']) for lang in ('en', 'ru')}
        print(weight, json.dumps(summary), flush=True)
    (HERE / 'tuning.json').write_text(json.dumps(report, ensure_ascii=False, indent=1) + '\n')


if __name__ == '__main__':
    main()
