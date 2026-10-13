import importlib.util
import json
import tempfile
import unittest
import wave
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('long_quality', Path(__file__).parents[1] / 'prepare-long-asr-quality.py')
long_quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(long_quality)


class LongNarrationTests(unittest.TestCase):
    def test_word_boundary_preserves_the_last_whole_word_and_rejects_padding(self):
        text = 'first second third'
        alignment = {'characters': list(text),
                     'character_start_times_seconds': [i / 2 for i in range(len(text))],
                     'character_end_times_seconds': [i / 2 + .4 for i in range(len(text))]}
        words = long_quality.aligned_words(text, alignment, 9)
        cut, end = long_quality.word_cut(words, 9, 2.7)
        self.assertAlmostEqual(cut, 2.7)
        self.assertEqual(text[:end], 'first')
        with self.assertRaisesRegex(ValueError, 'padding'):
            long_quality.word_cut(words, 9, 900)
        alignment['characters'][0] = 'x'
        with self.assertRaisesRegex(ValueError, 'exact frozen'):
            long_quality.aligned_words(text, alignment, 9)

    def test_duplicate_paragraphs_cannot_be_used_to_make_a_long_track(self):
        with self.assertRaisesRegex(ValueError, 'repeated paragraph'):
            long_quality.split_chunks('a short example\n\na short example')
        text = 'unique first paragraph\n\na different continuation'
        self.assertEqual(''.join(''.join(long_quality.split_chunks(text)).split()), ''.join(text.split()))

    def test_pcm_preserves_frames_and_refuses_to_overwrite_a_sealed_source(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'parent.wav'
            pcm = bytes([1, 0, 2, 0, 3, 0])
            long_quality.write_pcm(path, pcm)
            long_quality.write_pcm(path, pcm)
            with wave.open(str(path), 'rb') as source:
                self.assertEqual(source.getnframes(), 3)
                self.assertEqual(source.readframes(3), pcm)
            with self.assertRaisesRegex(ValueError, 'sealed'):
                long_quality.write_pcm(path, pcm + bytes([4, 0]))

    def fixture(self, root):
        (root / 'synthetic').mkdir()
        (root / 'manifests').mkdir()
        (root / 'synthetic/ledger.json').write_text('{}')
        key = root / 'test-key'
        key.write_text('dummy')
        job = {'id': 'one', 'characters': 10, 'maximum_cost_usd': .001,
               'reference': 'one sample', 'payload': {'text': 'one sample'}}
        (root / 'manifests/synthetic-long-plan.json').write_text(json.dumps({'jobs': [job], 'generation_endpoint': '/generate'}))
        return SimpleNamespace(root=root, key_file=key)

    def test_quota_exhaustion_makes_no_paid_request_or_budget_reservation(self):
        with tempfile.TemporaryDirectory() as folder:
            args = self.fixture(Path(folder))
            with patch.object(long_quality.synthetic, 'api', return_value=({'character_limit': 10, 'character_count': 10,
                                                                          'next_character_count_reset_unix': 1234}, {})) as api:
                long_quality.generate(args)
            self.assertEqual(api.call_count, 1)
            self.assertEqual(json.loads((args.root / 'synthetic/ledger.json').read_text()), {})

    def test_uncertain_paid_attempt_is_durable_before_call_and_never_retried(self):
        with tempfile.TemporaryDirectory() as folder:
            args = self.fixture(Path(folder))

            def api(key, route, payload=None):
                if payload is None:
                    return {'character_limit': 1000, 'character_count': 0}, {}
                ledger = json.loads((args.root / 'synthetic/ledger.json').read_text())
                self.assertEqual(ledger['one']['status'], 'attempted')
                self.assertEqual(ledger['one']['maximum_cost_usd'], .001)
                raise TimeoutError('response may have been lost after billing')

            with patch.object(long_quality.synthetic, 'api', side_effect=api) as remote:
                long_quality.generate(args)
                with self.assertRaisesRegex(ValueError, 'never automatically'):
                    long_quality.generate(args)
            self.assertEqual(remote.call_count, 2)
            self.assertEqual(json.loads((args.root / 'synthetic/ledger.json').read_text())['one']['status'], 'needs_review')


if __name__ == '__main__':
    unittest.main()
