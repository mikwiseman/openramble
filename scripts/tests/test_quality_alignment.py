import importlib.util
import random
import unittest
from pathlib import Path


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


reference = load('reference_quality', 'asr-quality.py')
optimized = load('optimized_alignment', 'quality-alignment.py')


class ExactBandedAlignmentTests(unittest.TestCase):
    def test_matches_every_SDI_count_including_ambiguous_optimal_alignments(self):
        # RF's editops disagree on 254/2000 of these ties. A distance-only
        # comparison would miss a changed deletion/substitution interpretation.
        rng = random.Random(20260930)
        for _ in range(2000):
            a = [rng.choice('abcd') for _ in range(rng.randrange(15))]
            b = [rng.choice('abcd') for _ in range(rng.randrange(15))]
            expected = reference.edit_counts(a, b)
            distance = sum(expected[k] for k in ('substitutions', 'deletions', 'insertions'))
            self.assertEqual(optimized.banded_counts(a, b, distance), expected, (a, b))

    def test_word_alignment_preserves_the_missing_negation_and_changed_number(self):
        a = 'do not remove seventeen maps'.split()
        b = 'do remove seventy maps'.split()
        self.assertEqual(optimized.banded_counts(a, b, 2),
                         {'substitutions': 1, 'deletions': 1, 'insertions': 0, 'reference_units': 5})


if __name__ == '__main__':
    unittest.main()
