"""Score H17: a smaller Parakeet Ultra file against Q8_0 on hosted x86 machines.

    mkdir /tmp/h17 && tar -xzf research/model-upgrade-2026-10/h17/artifacts.tar.gz -C /tmp/h17
    uv run --with jiwer==4.0.0 python research/model-upgrade-2026-10/h17/score.py /tmp/h17

`<artifacts>` holds one folder per job of the proof workflow, named
h17-<system>-<locale>, as `gh run download` leaves them. Words are scored with
the scorecard's own normalization, aligner and paired bootstrap, imported from
scripts/scorecard/scorecard.py, so the numbers compare with H11's. Writes
`--out` (h17.json next to this file) and prints the tables of the ledger
entry. `--candidate q5` scores H17b's Q5_K_M files instead of Q4_K_M.
"""
import argparse
import collections
import json
import random
import re
import sys
from pathlib import Path

import jiwer

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts/scorecard'))
import scorecard  # noqa: E402

LANGUAGES = {'en': 'English', 'ru': 'Russian', 'de': 'German', 'es': 'Spanish', 'fr': 'French', 'uk': 'Ukrainian'}
CYRILLIC = {'ru', 'uk'}
NAMES = {'q4': 'Q4_K_M', 'q5': 'Q5_K_M'}
FILES = ['q8', 'q4']


def rows(path):
    if not path.exists():
        return []
    return [line.split('\t') for line in path.read_text(encoding='utf-8').splitlines() if line]


def errors(reference, hypothesis):
    """Reference words, and substitutions, deletions and insertions against them."""
    ref, hyp = scorecard.norm(reference), scorecard.norm(hypothesis)
    if not ref:
        return 0, 0, 0, len(hyp.split())
    out = jiwer.process_words(ref, hyp)
    return out.hits + out.substitutions + out.deletions, out.substitutions, out.deletions, out.insertions


def paired(per):
    """The scorecard's paired bootstrap over utterances: (words, errors Q8, errors Q4)."""
    words = sum(p[0] for p in per)
    rng = random.Random(scorecard.SEED)
    draws = []
    for _ in range(10000):
        pick = [per[rng.randrange(len(per))] for _ in per]
        draws.append((sum(p[2] for p in pick) - sum(p[1] for p in pick)) / sum(p[0] for p in pick))
    return {'utterances': len(per), 'reference_words': words,
            'q8_errors': sum(p[1] for p in per), 'candidate_errors': sum(p[2] for p in per),
            'q8_wer': sum(p[1] for p in per) / words, 'candidate_wer': sum(p[2] for p in per) / words,
            'difference': (sum(p[2] for p in per) - sum(p[1] for p in per)) / words,
            'ci95': [scorecard.pct(draws, 0.025), scorecard.pct(draws, 0.975)],
            'candidate_better': sum(p[2] < p[1] for p in per), 'candidate_worse': sum(p[2] > p[1] for p in per)}


def letters_apart(a, b):
    """Edit distance between two words, in letters."""
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[-1] + 1, previous[j - 1] + (x != y)))
        previous = current
    return previous[-1]


def kind(q8_words, q4_words):
    """What sort of difference one differing stretch of the two transcripts is."""
    a, b = ' '.join(q8_words), ' '.join(q4_words)
    if not q8_words or not q4_words:
        return 'a word only one file wrote'
    if a.replace(' ', '') == b.replace(' ', ''):
        return 'the same letters, split differently'
    if re.search(r'\d', a + b):
        return 'a number written differently'
    if len(q8_words) == len(q4_words) and all(letters_apart(x, y) <= 2 for x, y in zip(q8_words, q4_words)):
        return 'one or two letters'
    return 'a different word'


def differences(reference, q8, q4):
    """Each stretch where the two transcripts differ, and which one the reference agrees with."""
    ref, a, b = (scorecard.norm(t) for t in (reference, q8, q4))
    if a == b or not a or not b:
        return [] if a == b else [('a word only one file wrote', a.split(), b.split(), 'neither')]
    found = []
    reference_words = set(ref.split())
    for chunk in jiwer.process_words(a, b).alignments[0]:
        if chunk.type == 'equal':
            continue
        left = a.split()[chunk.ref_start_idx:chunk.ref_end_idx]
        right = b.split()[chunk.hyp_start_idx:chunk.hyp_end_idx]
        in_ref = [bool(words) and all(w in reference_words for w in words) for words in (left, right)]
        agrees = 'Q8_0' if in_ref[0] and not in_ref[1] else NAMES[FILES[1]] if in_ref[1] and not in_ref[0] else 'neither'
        found.append((kind(left, right), left, right, agrees))
    return found


def job(folder):
    system, locale = folder.name.split('-')[1:3]
    language = locale[:2]
    references = {r[0]: r[2] if len(r) > 2 else '' for r in rows(folder / 'references.tsv')}
    heard = {f: {r[0]: r[3] if len(r) > 3 else '' for r in rows(folder / f'words-{f}.tsv')} for f in FILES}
    extras = {f: {r[0]: r[3] if len(r) > 3 else '' for r in rows(folder / f'extras-{f}.tsv')} for f in FILES}
    ids = sorted(heard['q8'])
    assert ids == sorted(heard[FILES[1]]) and all(i in references for i in ids), folder

    per, kinds, examples, same, counts = [], collections.Counter(), [], 0, {f: [0, 0, 0] for f in FILES}
    wrong = {f: 0 for f in FILES}
    pairs = {f: [] for f in FILES}
    for i in ids:
        scored = {f: errors(references[i], heard[f][i]) for f in FILES}
        per.append((scored['q8'][0], sum(scored['q8'][1:]), sum(scored[FILES[1]][1:])))
        for f in FILES:
            counts[f] = [x + y for x, y in zip(counts[f], scored[f][1:])]
            latin, cyrillic = scorecard.script_counts(heard[f][i])
            letters = latin + cyrillic
            expected = cyrillic if language in CYRILLIC else latin
            wrong[f] += bool(letters) and expected / letters < 0.5
            pairs[f].append((references[i], heard[f][i]))
        same += scorecard.norm(heard['q8'][i]) == scorecard.norm(heard[FILES[1]][i])
        for what, left, right, agrees in differences(references[i], heard['q8'][i], heard[FILES[1]][i]):
            kinds[(what, agrees)] += 1
            examples.append({'id': i, 'kind': what, 'agrees': agrees, 'q8': ' '.join(left), 'candidate': ' '.join(right)})

    result = {'system': system, 'locale': locale, 'language': language,
              'machine': (folder / 'machine.txt').read_text(encoding='utf-8').strip().splitlines(),
              'build': (folder / 'build.txt').read_text(encoding='utf-8').strip(),
              'prepared': (folder / 'prepared.txt').read_text(encoding='utf-8').strip().splitlines(),
              'wer': paired(per), 'identical_transcripts': same, 'wrong_script': wrong,
              'substitutions_deletions_insertions': counts,
              'kinds': [{'kind': k[0], 'agrees': k[1], 'count': n} for k, n in sorted(kinds.items())]}
    if language in ('en', 'ru'):
        marks = {f: scorecard.punctuation_and_case(pairs[f]) for f in FILES}
        result['punctuation_f1'] = {f: marks[f]['punctuation']['micro_f1'] for f in FILES}
        result['capitalization_f1'] = {f: marks[f]['capitalization']['f1'] for f in FILES}

    takes, noise = {}, {}
    for i in sorted(extras['q8']):
        if i.startswith('take-'):
            takes[i] = {f: dict(zip(('words', 'substitutions', 'deletions', 'insertions'), errors(references[i], extras[f][i])))
                        for f in FILES}
        else:
            noise[i] = {f: scorecard.invented_words(extras[f][i])[0] for f in FILES}
    if takes:
        result['takes'] = takes
    if noise:
        result['noise_invented_words'] = noise

    timed = collections.defaultdict(lambda: {0: [], 1: []})
    for clip, which, _, ms, *_ in rows(folder / 'speed.tsv'):
        timed[clip][int(which)].append(float(ms))
    best = [(min(t[0]), min(t[1])) for t in timed.values()]
    if best:
        q8, q4 = [b[0] for b in best], [b[1] for b in best]
        result['speed'] = {'clips': len(best),
                           'q8_ms': {'p50': scorecard.pct(q8, .5), 'p95': scorecard.pct(q8, .95)},
                           'candidate_ms': {'p50': scorecard.pct(q4, .5), 'p95': scorecard.pct(q4, .95)},
                           'ratio_p50': scorecard.pct(q4, .5) / scorecard.pct(q8, .5),
                           'ratio_p95': scorecard.pct(q4, .95) / scorecard.pct(q8, .95),
                           'ratio_per_clip': {'min': min(b / a for a, b in best), 'p50': scorecard.pct([b / a for a, b in best], .5),
                                              'max': max(b / a for a, b in best)}}
    memory = {}
    for f in FILES:
        log = folder / f'memory-{f}.log'
        if log.exists():
            memory[f] = {line.split(':')[0]: {name.strip(): float(value) for name, value in re.findall(r'([a-z][a-z ,\']+?) (\d+) MB', line)}
                         for line in log.read_text(encoding='utf-8').splitlines() if line.startswith('memory')}
    result['memory_mb'] = memory
    return result, per, examples


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('artifacts', type=Path)
    parser.add_argument('--examples', type=int, default=6)
    parser.add_argument('--candidate', choices=sorted(NAMES), default='q4')
    parser.add_argument('--out', type=Path, default=Path(__file__).parent / 'h17.json')
    arguments = parser.parse_args()
    FILES[1] = arguments.candidate
    label = NAMES[FILES[1]]

    jobs, per, examples = {}, {}, {}
    for folder in sorted(arguments.artifacts.glob('h17-*')):
        result, utterances, found = job(folder)
        key = (result['system'], result['language'])
        jobs[key], per[key], examples[key] = result, utterances, found

    def pooled(system, languages):
        return paired([p for language in languages for p in per[(system, language)]])

    pools = {}
    for system in ('linux', 'windows'):
        if (system, 'en') in per and (system, 'ru') in per:
            pools[f'{system}, English and Russian'] = pooled(system, ('en', 'ru'))
    if all(('linux', language) in per for language in LANGUAGES):
        pools['linux, all six languages'] = pooled('linux', LANGUAGES)

    out = {'schema': 'openramble-h17/1', 'seed': scorecard.SEED,
           'jobs': [jobs[k] for k in sorted(jobs)], 'pooled': pools}
    arguments.out.write_text(json.dumps(out, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')

    def line(name, w):
        print(f"| {name} | {w['utterances']:,} | {w['reference_words']:,} | {w['q8_wer'] * 100:.2f}% | {w['candidate_wer'] * 100:.2f}% | "
              f"{w['difference'] * 100:+.3f} | {w['ci95'][0] * 100:+.3f} to {w['ci95'][1] * 100:+.3f} | "
              f"{w['candidate_better']} / {w['candidate_worse']} |")

    print(f'| | Utterances | Words | Q8_0 WER | {label} WER | Difference, pp | 95% interval | Utterances {label} better / worse |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|')
    for (system, language), result in sorted(jobs.items()):
        line(f'{system}, {LANGUAGES[language]}', result['wer'])
    for name, w in pools.items():
        line(name, w)

    print()
    for (system, language), result in sorted(jobs.items()):
        n = result['wer']['utterances']
        print(f"{system}, {LANGUAGES[language]}: {result['identical_transcripts']} of {n} transcripts identical after normalization; "
              f"wrong script Q8_0 {result['wrong_script']['q8']}, {label} {result['wrong_script'][FILES[1]]}; "
              f"S/D/I Q8_0 {result['substitutions_deletions_insertions']['q8']}, {label} {result['substitutions_deletions_insertions'][FILES[1]]}")
        if 'punctuation_f1' in result:
            print(f"  punctuation F1 Q8_0 {result['punctuation_f1']['q8'] * 100:.1f}%, {label} {result['punctuation_f1'][FILES[1]] * 100:.1f}%; "
                  f"capitalization F1 {result['capitalization_f1']['q8'] * 100:.1f}%, {result['capitalization_f1'][FILES[1]] * 100:.1f}%")
        for name, take in result.get('takes', {}).items():
            print(f"  {name}: {take['q8']['words']} words; S/D/I Q8_0 {take['q8']['substitutions']}/{take['q8']['deletions']}/{take['q8']['insertions']}, "
                  f"{label} {take[FILES[1]]['substitutions']}/{take[FILES[1]]['deletions']}/{take[FILES[1]]['insertions']}")
        if 'noise_invented_words' in result:
            invented = result['noise_invented_words']
            print(f"  noise clips: {len(invented)}; invented words Q8_0 {sum(v['q8'] for v in invented.values())}, "
                  f"{label} {sum(v[FILES[1]] for v in invented.values())}")
        if 'speed' in result:
            s = result['speed']
            print(f"  speed, {s['clips']} clips: Q8_0 p50 {s['q8_ms']['p50']:.0f} ms, p95 {s['q8_ms']['p95']:.0f} ms; "
                  f"{label} p50 {s['candidate_ms']['p50']:.0f} ms, p95 {s['candidate_ms']['p95']:.0f} ms; "
                  f"ratio p50 {s['ratio_p50']:.3f}, p95 {s['ratio_p95']:.3f}; per clip {s['ratio_per_clip']['min']:.3f} to {s['ratio_per_clip']['max']:.3f}")
        for f in FILES:
            for moment, values in result['memory_mb'].get(f, {}).items():
                print(f'  {f} {moment}: ' + ', '.join(f'{name} {value:.0f} MB' for name, value in values.items()))
        print(f"  machine: {'; '.join(result['machine'])}")

    print('\nKinds of difference between the two transcripts (stretches; which file the reference agrees with)')
    table = collections.defaultdict(collections.Counter)
    for (system, language), result in jobs.items():
        if system == 'linux':
            for k in result['kinds']:
                table[k['kind']][k['agrees']] += k['count']
    print(f'| Kind | Stretches | Reference agrees with Q8_0 | with {label} | with neither |')
    print('|---|---:|---:|---:|---:|')
    for what, c in sorted(table.items(), key=lambda item: -sum(item[1].values())):
        print(f"| {what} | {sum(c.values())} | {c['Q8_0']} | {c[label]} | {c['neither']} |")
    rng = random.Random(scorecard.SEED)
    for what in table:
        pool = [e for (system, language), found in sorted(examples.items()) if system == 'linux' for e in found if e['kind'] == what]
        print(f'\n{what}, examples (Q8_0 | {label} | reference agrees with):')
        for e in rng.sample(pool, min(arguments.examples, len(pool))):
            print(f"  {e['id'].split('-')[1]}: {e['q8'] or '∅'} | {e['candidate'] or '∅'} | {e['agrees']}")


if __name__ == '__main__':
    main()
