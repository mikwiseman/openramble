"""Opt-in native CLI regression; uses an installed model, never downloads one."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.environ.get("WAI_ASR_BENCH"), "set WAI_ASR_BENCH to a built CLI")
class ASRCLIErrorTests(unittest.TestCase):
    def test_file_error_releases_native_model_before_exit(self):
        # A reader failure still happens after model preparation. Exiting while
        # the Metal model remains resident used to abort in the static destructor.
        with tempfile.TemporaryDirectory(prefix="asr-cli-error-") as directory:
            missing = Path(directory) / "missing-fictional-audio.wav"
            result = subprocess.run(
                [os.environ["WAI_ASR_BENCH"], "transcribe", str(missing)],
                env=os.environ, capture_output=True, text=True, timeout=60,
            )
        self.assertIn("Error:", result.stdout)
        self.assertEqual(result.returncode, 70, result.stdout + result.stderr)
        self.assertNotIn("GGML_ASSERT", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
