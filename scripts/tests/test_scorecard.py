import importlib.util
import json
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('scorecard', REPO / 'scripts/scorecard/scorecard.py')
scorecard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scorecard)

try:
    import jiwer  # noqa: F401
    HAVE_JIWER = True
except ImportError:
    HAVE_JIWER = False


class TextMeasures(unittest.TestCase):
    def test_normalization_is_the_oct_9_one(self):
        self.assertEqual(scorecard.norm('Ёлка, Don\'t  stop!'), 'елка don t stop')

    def test_marks_follow_their_word_and_ignore_number_separators(self):
        words = scorecard.marked_words('Is it 3.5, really? Yes. Fine')
        self.assertEqual([w for w, _, _ in words], ['is', 'it', '3', '5', 'really', 'yes', 'fine'])
        self.assertEqual([m for _, _, m in words], [None, None, None, 'comma', 'question', 'period', None])
        self.assertEqual([c for _, c, _ in words], [True, False, False, False, False, True, True])

    def test_exclamation_and_ellipsis_end_a_sentence(self):
        self.assertEqual(scorecard.mark_after('! '), 'period')
        self.assertEqual(scorecard.mark_after('… '), 'period')
        self.assertIsNone(scorecard.mark_after(' — '))

    def test_script_decides_by_majority_and_abstains_on_empty(self):
        self.assertEqual(scorecard.script_counts('Pull request, пожалуйста'), (11, 10))
        self.assertTrue(scorecard.wrong_script(*scorecard.script_counts('Соу кул, со нау'), 'en'))
        self.assertFalse(scorecard.wrong_script(*scorecard.script_counts('Открой мне этот pull request'), 'ru'))
        self.assertIsNone(scorecard.wrong_script(0, 0, 'en'))

    def test_annotations_are_not_invented_words(self):
        self.assertEqual(scorecard.invented_words('[BLANK_AUDIO]'), (0, 1))
        self.assertEqual(scorecard.invented_words(' Thank you. (music)'), (2, 1))

    def test_edges_and_terms(self):
        self.assertEqual(scorecard.edge_words('so cool, write it', 'cool write it'), (False, True))
        recall = scorecard.term_recall([{'text': 'Ask Anthropic about Kubernetes', 'terms': ['Anthropic', 'kube ctl']}])
        self.assertEqual(recall['found'], 1)

    def test_percentile_matches_the_oct_9_definition(self):
        self.assertEqual(scorecard.pct([1, 2, 3, 4], 0.5), 2.5)
        self.assertAlmostEqual(scorecard.pct(list(range(1, 101)), 0.95), 95.05)

    def test_load_blocks_alternate_abba(self):
        self.assertEqual(scorecard.conditions(6), ['quiet', 'load', 'load', 'quiet', 'quiet', 'load'])

    def test_every_candidate_takes_every_position_in_each_condition(self):
        for count, blocks in ((2, 12), (5, 20), (6, 12)):
            seen = {}
            for block, condition in enumerate(scorecard.conditions(blocks)):
                for position, candidate in enumerate(scorecard.order(block, count)):
                    key = (condition, candidate, position)
                    seen[key] = seen.get(key, 0) + 1
            self.assertEqual(len(seen), 2 * count * count, (count, blocks))
            self.assertEqual(len(set(seen.values())), 1, (count, blocks))


@unittest.skipUnless(HAVE_JIWER, 'jiwer 4.0.0 scores WER; run through scripts/scorecard.sh or uv')
class Scoring(unittest.TestCase):
    def test_reproduces_the_published_oct_9_word_error_rates(self):
        data = REPO / 'research/product-benchmark-2026-10/data'
        manifest = json.loads((data / 'manifest.json').read_text())
        references = {f['id']: f for f in manifest['fixtures']}
        published = json.loads((data / 'products-benchmark.json').read_text())['quality']
        rows = [json.loads(line) for line in (data / 'observations.jsonl').read_text().splitlines()]
        for engine in ('openramble', 'handy', 'whisper'):
            for language in ('ru', 'en'):
                pairs = [(references[r['fixture']]['reference'], r['text']) for r in rows
                         if r['phase'] == 'quality' and r['engine'] == engine
                         and references[r['fixture']]['language'] == language]
                ours = scorecard.wer_counts(pairs)
                theirs = published[engine][language]
                for key in ('wer', 'substitutions', 'deletions', 'insertions', 'reference_words'):
                    self.assertEqual(ours[key], theirs[key], (engine, language, key))

    def test_punctuation_counts_every_kind_of_disagreement(self):
        result = scorecard.punctuation_and_case([('One, two. Three?', 'one two, Three.')])
        p = result['punctuation']
        self.assertEqual((p['comma']['tp'], p['comma']['fp'], p['comma']['fn']), (0, 1, 1))
        self.assertEqual((p['period']['tp'], p['period']['fp'], p['period']['fn']), (0, 1, 1))
        self.assertEqual((p['question']['tp'], p['question']['fn']), (0, 1))
        c = result['capitalization']
        self.assertEqual((c['tp'], c['fn'], c['aligned_words']), (1, 1, 3))

    def test_missing_words_lose_their_marks(self):
        result = scorecard.punctuation_and_case([('Stop. Go now.', ''), ('Yes, sir.', 'Yes, sir.')])
        p = result['punctuation']
        self.assertEqual(p['period']['fn'], 2)
        self.assertEqual(p['comma']['f1'], 1.0)


if __name__ == '__main__':
    unittest.main()
