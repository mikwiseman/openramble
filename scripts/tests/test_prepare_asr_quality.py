import hashlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare_quality', Path(__file__).resolve().parents[1] / 'prepare-asr-quality.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class Response(io.BytesIO):
    def __init__(self, data, status=200, headers=None):
        super().__init__(data)
        self.status = status
        self.headers = headers or {}


class DownloadTests(unittest.TestCase):
    def test_short_successful_response_resumes_at_the_exact_offset(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'audio.tar'
            responses = [Response(b'ab'), Response(b'cd', 206, {'Content-Range':'bytes 2-3/4'})]
            with patch.object(prepare.urllib.request, 'urlopen', side_effect=responses) as get:
                prepare.download('https://example.invalid/audio', path, hashlib.sha256(b'abcd').hexdigest(), 4)
            self.assertEqual(path.read_bytes(), b'abcd')
            self.assertEqual(get.call_args_list[1].args[0].get_header('Range'), 'bytes=2-')

    def test_overlong_interrupted_partial_is_preserved_then_replaced(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'audio.tar'
            path.with_suffix('.tar.part').write_bytes(b'corrupt old overlap')
            with patch.object(prepare.urllib.request, 'urlopen', return_value=Response(b'abcd')):
                prepare.download('https://example.invalid/audio', path, hashlib.sha256(b'abcd').hexdigest(), 4)
            self.assertEqual(path.read_bytes(), b'abcd')
            self.assertEqual(len(list(Path(folder).glob('*.invalid-*'))), 1)

    def test_integrity_retries_remain_bounded_even_with_positive_partial_progress(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'audio.tar'
            responses = [item for _ in range(3) for item in
                         (Response(b'ab'), Response(b'xx', 206, {'Content-Range':'bytes 2-3/4'}))]
            with patch.object(prepare.urllib.request, 'urlopen', side_effect=responses) as get:
                with self.assertRaises(RuntimeError):
                    prepare.download('https://example.invalid/audio', path, hashlib.sha256(b'abcd').hexdigest(), 4)
            self.assertEqual(get.call_count, 6)
            self.assertFalse(path.exists())

    def test_wrong_resume_offset_cannot_seal_an_artifact(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'audio.tar'
            path.with_suffix('.tar.part').write_bytes(b'ab')
            with patch.object(prepare.urllib.request, 'urlopen', return_value=Response(b'cd', 206, {'Content-Range':'bytes 1-2/4'})):
                with self.assertRaises(ValueError):
                    prepare.download('https://example.invalid/audio', path, hashlib.sha256(b'abcd').hexdigest(), 4)
            self.assertFalse(path.exists())


if __name__ == '__main__':
    unittest.main()
