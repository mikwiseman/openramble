"""Exact Levenshtein S/D/I with the original diagonal/deletion/insertion ties.

RapidFuzz only computes the optimal distance for the search band. It does NOT
choose the alignment: its tie choices differ from this study's reference DP.
"""


def banded_counts(reference, hypothesis, distance):
    n, m = len(reference), len(hypothesis)
    if not n:
        return {'substitutions': 0, 'deletions': 0, 'insertions': m, 'reference_units': 0}
    if not m:
        return {'substitutions': 0, 'deletions': n, 'insertions': 0, 'reference_units': n}
    if not distance:
        if reference != hypothesis:
            raise ValueError('zero distance for unequal sequences')
        return {'substitutions': 0, 'deletions': 0, 'insertions': 0, 'reference_units': n}
    infinite = (n + m + 1, 0, 0, 0)
    previous_start = 0
    previous = [(j, 0, 0, j) for j in range(min(m, distance) + 1)]
    for i, a in enumerate(reference, 1):
        start, stop = max(0, i - distance), min(m, i + distance)
        current = []
        for j in range(start, stop + 1):
            if not j:
                current.append((i, 0, i, 0))
                continue
            diagonal_index = j - 1 - previous_start
            deletion_index = j - previous_start
            diagonal = previous[diagonal_index] if 0 <= diagonal_index < len(previous) else infinite
            deletion = previous[deletion_index] if 0 <= deletion_index < len(previous) else infinite
            insertion = current[-1] if current else infinite
            cost, s, d, ins = diagonal
            diagonal = (cost + (a != hypothesis[j - 1]), s + (a != hypothesis[j - 1]), d, ins)
            cost, s, d, ins = deletion
            deletion = (cost + 1, s, d + 1, ins)
            cost, s, d, ins = insertion
            insertion = (cost + 1, s, d, ins + 1)
            current.append(min((diagonal, deletion, insertion), key=lambda value: value[0]))
        previous, previous_start = current, start
    cost, s, d, ins = previous[m - previous_start]
    if cost != distance:
        raise ValueError('provided optimal distance is inconsistent with alignment')
    return {'substitutions': s, 'deletions': d, 'insertions': ins, 'reference_units': n}


def fast_counts(reference, hypothesis):
    import rapidfuzz
    from rapidfuzz.distance import Levenshtein
    if rapidfuzz.__version__ != '3.14.6':
        raise ValueError('long alignment requires the pinned RapidFuzz 3.14.6')
    return banded_counts(reference, hypothesis, Levenshtein.distance(reference, hypothesis))
