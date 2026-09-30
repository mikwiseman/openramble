import importlib.util
import json
import selectors
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'asr-quality.py'
spec = importlib.util.spec_from_file_location('asr_quality', SCRIPT)
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


class QualityTests(unittest.TestCase):
    def test_normalization_keeps_terms_numbers_and_negation(self):
        self.assertNotEqual(quality.normalize('GitHub'), quality.normalize('гитхаб'))
        self.assertNotEqual(quality.normalize('Не удаляй 7 файлов'), quality.normalize('Удаляй 9 файлов'))
        self.assertEqual(quality.normalize('Ёж,  API!'), 'еж api')

    def test_alignment_counts_substitution_deletion_and_insertion(self):
        self.assertEqual(quality.edit_counts('one two three'.split(), 'one too'.split()),
                         {'substitutions': 1, 'deletions': 1, 'insertions': 0, 'reference_units': 3})
        self.assertEqual(quality.edit_counts(['one'], ['one', 'two'])['insertions'], 1)

    def test_failure_remains_in_the_quality_denominator(self):
        fixtures = [{'id': 'a', 'group_id': 'a', 'reference': 'one two'},
                    {'id': 'b', 'group_id': 'b', 'reference': 'three four'}]
        results = [{'id': 'a', 'status': 'ok', 'raw_text': 'one two', 'app_text': 'one two', 'wall_seconds': 1},
                   {'id': 'b', 'status': 'timeout'}]
        report = quality.summarize(fixtures, results)
        self.assertEqual(report['failures'], 1)
        self.assertEqual(report['raw']['wer'], 0.5)
        self.assertEqual(report['raw']['reference_units'], 4)

    def test_missing_and_duplicate_results_are_not_silently_excluded(self):
        fixture = [{'id': 'a', 'group_id': 'a', 'reference': 'one'}]
        for results in ([], [{'id': 'a', 'status': 'error'}, {'id': 'a', 'status': 'error'}]):
            with self.assertRaises(ValueError):
                quality.summarize(fixture, results)

    def test_paired_intervals_resample_source_groups(self):
        fixtures = [{'id': str(i), 'group_id': 'same', 'reference': 'one two'} for i in range(3)]
        baseline = [{'id': str(i), 'status': 'ok', 'raw_text': 'one', 'app_text': 'one'} for i in range(3)]
        candidate = [{'id': str(i), 'status': 'ok', 'raw_text': 'one two', 'app_text': 'one two'} for i in range(3)]
        result = quality.paired_delta(fixtures, baseline, candidate, 'raw_text', resamples=100)
        self.assertEqual(result['independent_groups'], 1)
        self.assertEqual(result['wer_delta_ci95'], [-0.5, -0.5])

    def test_manifest_checks_pcm_and_references_before_inference(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio = root / 'sample.wav'
            audio.write_bytes(b'fictional test audio')
            fixture = {'id': 'a', 'group_id': 'source', 'dataset': 'fictional', 'split': 'dev',
                       'language': 'en', 'path': str(audio), 'audio_sha256': quality.sha256(audio),
                       'reference': 'one', 'reference_sha256': quality.text_hash('one')}
            manifest = root / 'manifest.json'
            manifest.write_text(json.dumps({'schema_version': 1, 'fixtures': [fixture]}))
            quality.load_manifest(manifest)
            audio.write_bytes(b'changed')
            with self.assertRaises(ValueError):
                quality.load_manifest(manifest)

    def test_resume_identity_cannot_change_model_or_input(self):
        with self.assertRaises(ValueError):
            quality.check_resume({'model_sha256': 'a'}, {'model_sha256': 'b'})

    def test_timing_is_per_file_and_failures_have_no_invented_latency(self):
        fixtures = [{'id': str(i), 'group_id': str(i), 'reference': 'one'} for i in range(3)]
        results = [{'id': '0', 'status': 'ok', 'raw_text': 'one', 'app_text': 'one', 'wall_seconds': 1},
                   {'id': '1', 'status': 'ok', 'raw_text': 'one', 'app_text': 'one', 'wall_seconds': 2},
                   {'id': '2', 'status': 'timeout'}]
        result = quality.summarize(fixtures, results)
        self.assertEqual(result['wall_seconds']['p50'], 1.5)
        self.assertEqual(result['timed_successes'], 2)

    def test_partial_json_row_cannot_evade_the_timeout(self):
        process = subprocess.Popen([sys.executable, '-c',
            'import sys,time; sys.stdout.write("{\\\"type\\\":"); sys.stdout.flush(); time.sleep(10)'],
            stdout=subprocess.PIPE, bufsize=0)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                with self.assertRaises(TimeoutError):
                    quality.read_line(process, selector, .2)
        finally:
            process.terminate(); process.wait(); process.stdout.close()

    def test_multiple_buffered_rows_are_not_lost_after_the_pipe_exits(self):
        process = subprocess.Popen([sys.executable, '-c', 'print("{}\\n{}")'],
            stdout=subprocess.PIPE, bufsize=0)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                self.assertEqual(quality.read_line(process, selector, 2), {})
                process.wait()
                self.assertEqual(quality.read_line(process, selector, 2), {})
        finally:
            process.wait(); process.stdout.close()


if __name__ == '__main__':
    unittest.main()
