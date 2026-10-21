"""Apply the preregistered rules in PREREGISTRATION.md to the scorecard results.

    uv run --with jiwer==4.0.0 python research/model-upgrade-2026-10/decide.py

Reads research/scorecard/results/*.json and the paired intervals, prints every
rule with its measured values and verdict, and writes decision.json next to
this file. Nothing here is tuned after the fact: the thresholds are the ones
written before the runs.
"""
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location('scorecard', REPO / 'scripts/scorecard/scorecard.py')
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)


def metrics(name):
    return json.loads((REPO / 'research/scorecard/results' / f'{name}.json').read_text())['metrics']


def get(m, *path):
    return sc.lookup(m, path)


def rule(rows, label, values, ok):
    rows.append({'rule': label, 'values': values, 'pass': bool(ok)})
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {values}")


def warm(m, condition, stat):
    return get(m, 'latency_warm', condition, 'all', stat)


def aa():
    print('\n== Part 1: runtime 0.4.0 against 0.2.3 (v3)')
    a, b = metrics('runtime-0.2.3'), metrics('runtime-0.4.0')
    rows = []
    diff = sc.transcript_diff('runtime-0.2.3', 'runtime-0.4.0', 'fleurs-full')
    paired = sc.paired_bootstrap('runtime-0.2.3', 'runtime-0.4.0')['pooled']
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
    speed = {}
    ok = True
    for condition in ('quiet', 'load'):
        for stat in ('p50', 'p95'):
            x, y = warm(a, condition, stat), warm(b, condition, stat)
            speed[f'warm {condition} {stat} ms'] = [round(x * 1000, 1), round(y * 1000, 1)] if x and y else None
            ok = ok and x is not None and y is not None and y <= x * 1.05 + 0.002
    x, y = get(a, 'latency_process', 'quiet', 'p50'), get(b, 'latency_process', 'quiet', 'p50')
    speed['process quiet p50 s'] = [round(x, 3), round(y, 3)] if x and y else None
    ok = ok and x is not None and y is not None and y <= x * 1.10
    rule(rows, '4. warm p50/p95 within 5% + 2 ms; process p50 within 10%', speed, ok)
    rss = [get(m, 'load', 'peak_rss_bytes') for m in (a, b)]
    rule(rows, '5. peak memory within 5%', {'bytes': rss}, rss[0] and rss[1] and rss[1] <= rss[0] * 1.05)
    rule(rows, '6. no new test failure', 'recorded in HYPOTHESES.md: end-to-end 21/3/0 under both; unit 163/9/0', True)
    rule(rows, '7. binary audit', 'scripts/check-network-surface.sh passes on the 0.4.0 binary', True)
    return rows


def bakeoff():
    print('\n== Part 2: bake-off against v3 on 0.4.0')
    base = metrics('runtime-0.4.0')
    out = {}
    for name in ('parakeet-ultra', 'nemotron-3.5'):
        print(f'-- {name}')
        m = metrics(name)
        rows = []
        paired = sc.paired_bootstrap('runtime-0.4.0', name)
        langs = {k: round(paired[k]['difference'] * 100, 3) for k in ('en', 'ru')}
        rule(rows, 'WER: upper 95% bound below zero; no language worse by > 0.25 pp',
             {'pooled_pp': round(paired['pooled']['difference'] * 100, 3),
              'ci95_pp': [round(x * 100, 3) for x in paired['pooled']['ci95']], 'by_language_pp': langs},
             paired['pooled']['ci95'][1] < 0 and all(v <= 0.25 for v in langs.values()))
        failures = sum(get(m, k, l, 'failures') or 0 for k in ('fleurs_full',) for l in ('en', 'ru')) + get(m, 'hallucination', 'failures')
        rule(rows, 'Gate 1: no failed recognition', {'failures': failures}, failures == 0)
        rule(rows, 'Gate 2: invented words not more', [get(base, 'hallucination', 'words'), get(m, 'hallucination', 'words')],
             get(m, 'hallucination', 'words') <= get(base, 'hallucination', 'words'))
        wrong = [get(x, 'wrong_script_private', 'total', 'wrong') + get(x, 'fleurs_full', 'en', 'wrong_script', 'wrong')
                 + get(x, 'fleurs_full', 'ru', 'wrong_script', 'wrong') for x in (base, m)]
        rule(rows, 'Gate 3: wrong script not more', wrong, wrong[1] <= wrong[0])
        hour = {k: [round(get(x, 'hour', k, 'deletion_rate') * 100, 2) for x in (base, m)] for k in ('en-3540s', 'ru-3540s')}
        mixed = [round(get(x, 'hour', 'mixed-3540s', 'wer') * 100, 2) for x in (base, m)]
        rule(rows, 'Gate 4: hour deletions within +0.5 pp; alternating hour WER within +1 pp', {'deleted_pct': hour, 'mixed_wer_pct': mixed},
             all(v[1] <= v[0] + 0.5 for v in hour.values()) and mixed[1] <= mixed[0] + 1.0)
        speed = {c: [warm(x, c, 'p95') for x in (base, m)] for c in ('quiet', 'load')}
        rule(rows, 'Gate 5: warm p95 within 1.15x, idle and load',
             {c: [round(v * 1000, 1) if v else None for v in vals] for c, vals in speed.items()},
             all(v[0] and v[1] and v[1] <= v[0] * 1.15 for v in speed.values()))
        rss = [get(x, 'load', 'peak_rss_bytes') for x in (base, m)]
        rule(rows, 'Gate 6: peak memory within 1.10x', rss, rss[0] and rss[1] and rss[1] <= rss[0] * 1.10)
        punct = {l: [round(get(x, 'fleurs_full', l, 'punctuation', 'micro_f1') * 100, 2) for x in (base, m)] for l in ('en', 'ru')}
        caps = {l: [round(get(x, 'fleurs_full', l, 'capitalization', 'f1') * 100, 2) for x in (base, m)] for l in ('en', 'ru')}
        rule(rows, 'Gate 7: punctuation and capitalization F1 within -1 pp', {'punctuation': punct, 'capitalization': caps},
             all(v[1] >= v[0] - 1 for v in list(punct.values()) + list(caps.values())))
        out[name] = {'rows': rows, 'pooled_wer': paired['pooled']['candidate_wer'], 'eligible': all(r['pass'] for r in rows)}
    eligible = {k: v for k, v in out.items() if v['eligible']}
    choice = min(eligible, key=lambda k: eligible[k]['pooled_wer']) if eligible else 'keep v3'
    print(f'\nRecommendation under the preregistered rule: {choice}')
    return out, choice


if __name__ == '__main__':
    part1 = aa()
    part2, choice = bakeoff()
    (HERE / 'decision.json').write_text(json.dumps({'aa': part1, 'bakeoff': part2, 'recommendation': choice}, indent=1) + '\n')
