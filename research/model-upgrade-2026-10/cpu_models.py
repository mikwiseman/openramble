"""H13: Ultra Q4_K_M against v3 Q8_0 on the CPU backend, one thread, idle and under load.

    uv run --with jiwer==4.0.0 python research/model-upgrade-2026-10/cpu_models.py <transcribe-cli> <v3.gguf> <ultra.gguf> [out.json]

The same design as cpu_threads.py with the two models in place of the two
thread counts: one CLI process per model per block, network denied, blocks
alternate quiet and loaded in ABBA order and the model order alternates within
them. The time per input is the runtime's own mel + encode + decode
milliseconds. Results go to cpu-models.json next to this file, or to the
file named by the optional fourth argument (H13b: cpu-models-q8.json).
"""
import json
import os
import statistics
import sys
import tempfile
from pathlib import Path

from cpu_threads import BLOCKS, HERE, recognize, sc


def main():
    cli, v3, ultra = sys.argv[1], sys.argv[2], sys.argv[3]
    out = sys.argv[4] if len(sys.argv) > 4 else 'cpu-models.json'
    models = {'v3': v3, 'ultra': ultra}
    files = sc.speed_files(sc.inputs()['fleurs'])
    rows = []
    with tempfile.TemporaryDirectory() as work:
        listing = Path(work) / 'files.list'
        listing.write_text(''.join(f['path'] + '\n' for f in files))
        for block, condition in enumerate(sc.conditions(BLOCKS)):
            sc.wait_for_lane()
            quiet = sc.wait_for_quiet()
            order = ('v3', 'ultra') if block % 2 == 0 else ('ultra', 'v3')
            print(f'block {block} {condition} {order}', flush=True)
            with sc.pressure(os.cpu_count() if condition == 'load' else 0):
                for name in order:
                    result = recognize(cli, models[name], listing, 1)
                    for f in files:
                        r = result[f['path']]
                        rows.append({'block': block, 'condition': condition, 'model': name, 'fixture': f['id'],
                                     'ms': r['mel_ms'] + r['encode_ms'] + r['decode_ms'],
                                     'cpu_idle_before': quiet['cpu_idle']})
    summary = {c: {m: statistics.median(r['ms'] for r in rows if r['condition'] == c and r['model'] == m)
                   for m in models} for c in ('quiet', 'load')}
    ratio = {c: round(summary[c]['ultra'] / summary[c]['v3'], 3) for c in summary}
    verdict = {'1_idle_ratio_at_most_1.10': ratio['quiet'] <= 1.10, '2_load_ratio_at_most_1.10': ratio['load'] <= 1.10}
    report = {'cli': cli, 'model_sha256': {m: sc.digest(Path(p)) for m, p in models.items()}, 'backend': 'cpu',
              'threads': 1, 'median_ms': summary, 'ultra_over_v3': ratio, 'verdict': verdict, 'rows': rows}
    (HERE / out).write_text(json.dumps(report, indent=1) + '\n')
    print(json.dumps({'median_ms': summary, 'ultra_over_v3': ratio, 'verdict': verdict}, indent=1))


if __name__ == '__main__':
    main()
