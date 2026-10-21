"""H10: one against four session threads on the CPU backend, idle and under load.

    uv run --with jiwer==4.0.0 python research/model-upgrade-2026-10/cpu_threads.py <transcribe-cli> <model.gguf>

Each block recognizes the six speed inputs in one CLI process per thread
count, on the CPU backend, network denied; blocks alternate quiet and loaded
in ABBA order and the thread order alternates within them. The time per input
is the runtime's own mel + encode + decode milliseconds, so model loading is
excluded. Results go to cpu-threads.json next to this file.
"""
import importlib.util
import json
import os
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location('scorecard', REPO / 'scripts/scorecard/scorecard.py')
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)

THREADS = (1, 4)
BLOCKS = 12


def recognize(cli, model, listing, threads):
    out = subprocess.run(['/usr/bin/sandbox-exec', '-p', sc.PROFILE, cli, '-m', model, '--batch', str(listing),
                          '--batch-jsonl', '--threads', str(threads), '--backend', 'cpu', '-q'],
                         capture_output=True, text=True, check=True).stdout
    return {r['file']: r for r in (json.loads(x) for x in out.splitlines() if x.startswith('{')) if 'file' in r}


def main():
    cli, model = sys.argv[1], sys.argv[2]
    files = sc.speed_files(sc.inputs()['fleurs'])
    rows = []
    with tempfile.TemporaryDirectory() as work:
        listing = Path(work) / 'files.list'
        listing.write_text(''.join(f['path'] + '\n' for f in files))
        for block, condition in enumerate(sc.conditions(BLOCKS)):
            quiet = sc.wait_for_quiet()
            order = THREADS if block % 2 == 0 else THREADS[::-1]
            print(f'block {block} {condition} {order}', flush=True)
            with sc.pressure(os.cpu_count() if condition == 'load' else 0):
                for threads in order:
                    result = recognize(cli, model, listing, threads)
                    for f in files:
                        r = result[f['path']]
                        rows.append({'block': block, 'condition': condition, 'threads': threads, 'fixture': f['id'],
                                     'ms': r['mel_ms'] + r['encode_ms'] + r['decode_ms'], 'text': r['text'],
                                     'cpu_idle_before': quiet['cpu_idle']})
    summary = {}
    for condition in ('quiet', 'load'):
        summary[condition] = {t: statistics.median(r['ms'] for r in rows if r['condition'] == condition and r['threads'] == t)
                              for t in THREADS}
    texts = {(r['fixture'], r['threads']): sc.norm(r['text']) for r in rows}
    identical = all(texts[(f['id'], 1)] == texts[(f['id'], 4)] for f in files)
    verdict = {'1_idle_4_threads_at_most_0.67x': summary['quiet'][4] <= 0.67 * summary['quiet'][1],
               '2_load_4_threads_not_slower': summary['load'][4] <= summary['load'][1],
               '3_identical_transcripts': identical}
    report = {'cli': cli, 'model_sha256': sc.digest(Path(model)), 'backend': 'cpu', 'median_ms': summary,
              'verdict': verdict, 'rows': [{k: v for k, v in r.items() if k != 'text'} for r in rows]}
    (HERE / 'cpu-threads.json').write_text(json.dumps(report, indent=1) + '\n')
    print(json.dumps({'median_ms': summary, 'verdict': verdict}, indent=1))


if __name__ == '__main__':
    main()
