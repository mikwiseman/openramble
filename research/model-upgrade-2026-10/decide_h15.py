"""Apply H15's preregistered rules (HYPOTHESES.md) to the scorecard runs.

    uv run --with jiwer==4.0.0 python research/model-upgrade-2026-10/decide_h15.py

The baseline is Ultra Q4_K_M on transcribe.cpp 0.4.0 (`parakeet-ultra-q4km`),
the candidate the same model on upstream main (`runtime-main-ultra-q4km`).
Accuracy comes from each candidate's scored results; speed, load and memory
from the interleaved run tagged `h15`. Rules 7 and 8 are not measurements and
are recorded in HYPOTHESES.md. Writes h15.json next to this file.
"""
import json
import statistics

from decide import HERE, get, metrics, rule, sc

BASE, CAND, TAG = 'parakeet-ultra-q4km', 'runtime-main-ultra-q4km', 'h15'


def speed(name):
    data = sc.inputs()
    by_id = {f['id']: f for f in data['fleurs'] + data['fleurs_full'] + data['generated'] + data['hour']}
    warm = sc.observations(name, f'speed-warm@{TAG}')
    ready = [r for r in warm if r['fixture'] == '_ready' and r['condition'] == 'quiet']
    requests = [r for r in warm if r['fixture'] != '_ready']
    process = [r for r in sc.observations(name, f'speed-process@{TAG}') if r['ok'] and r['condition'] == 'quiet']
    return {
        'warm': {c: sc.latency_buckets([r for r in requests if r['condition'] == c], by_id)['all'] for c in ('quiet', 'load')},
        'process_p50': sc.distribution([r['wall_seconds'] for r in process]).get('p50'),
        'load_p50': statistics.median(r['loadSeconds'] for r in ready),
        'footprint_ready': statistics.median(r['footprintBytes'] for r in ready),
        'footprint_peak': max(r.get('peak_footprint_bytes') or 0 for r in requests),
    }


def main():
    a, b = metrics(BASE), metrics(CAND)
    rows = []
    diff = sc.transcript_diff(BASE, CAND, 'fleurs-full')
    paired = sc.paired_bootstrap(BASE, CAND)['pooled']
    share = diff['normalized_identical'] / diff['compared']
    rule(rows, '1. >= 99% identical and pooled WER within +-0.10 pp',
         {'identical': f"{diff['normalized_identical']}/{diff['compared']}", 'pooled_pp': round(paired['difference'] * 100, 3),
          'ci95_pp': [round(x * 100, 3) for x in paired['ci95']]},
         share >= 0.99 and abs(paired['difference']) <= 0.001)
    wrong = [get(m, 'wrong_script_private', 'total', 'wrong') + get(m, 'fleurs_full', 'en', 'wrong_script', 'wrong')
             + get(m, 'fleurs_full', 'ru', 'wrong_script', 'wrong') for m in (a, b)]
    invented = [get(m, 'hallucination', 'words') for m in (a, b)]
    rule(rows, '2. wrong script and invented words not more', {'wrong': wrong, 'invented': invented},
         wrong[1] <= wrong[0] and invented[1] <= invented[0])
    deletions = {k: [get(m, 'hour', k, 'deletion_rate') for m in (a, b)] for k in ('en-3540s', 'ru-3540s')}
    rule(rows, '3. hour deleted words within 0.2 pp', deletions,
         all(abs(v[1] - v[0]) <= 0.002 for v in deletions.values()))

    x, y = speed(BASE), speed(CAND)
    values, ok = {}, True
    for condition in ('quiet', 'load'):
        for stat in ('p50', 'p95'):
            p, q = x['warm'][condition][stat], y['warm'][condition][stat]
            values[f'warm {condition} {stat} ms'] = [round(p * 1000, 1), round(q * 1000, 1)]
            ok = ok and q <= p * 1.05 + 0.002
    values['process quiet p50 s'] = [round(x['process_p50'], 3), round(y['process_p50'], 3)]
    ok = ok and y['process_p50'] <= x['process_p50'] * 1.10
    rule(rows, '4. warm p50/p95 within 5% + 2 ms; process p50 within 10%', values, ok)
    mb = 1e6
    rule(rows, '5. footprint after load at least 300 MB lower; peak footprint not higher',
         {'after load MB': [round(x['footprint_ready'] / mb), round(y['footprint_ready'] / mb)],
          'peak MB': [round(x['footprint_peak'] / mb), round(y['footprint_peak'] / mb)]},
         x['footprint_ready'] - y['footprint_ready'] >= 300 * mb and y['footprint_peak'] <= x['footprint_peak'])
    rule(rows, '6. warm-cache model load not more than 10% slower', {'load p50 s': [round(x['load_p50'], 3), round(y['load_p50'], 3)]},
         y['load_p50'] <= x['load_p50'] * 1.10)
    (HERE / 'h15.json').write_text(json.dumps({'baseline': BASE, 'candidate': CAND, 'rules': rows}, indent=1) + '\n')


if __name__ == '__main__':
    main()
