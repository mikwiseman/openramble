"""A real Mach-O / dSYM pair proves archival and mismatch rejection."""
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]


class ReleaseSymbolsTests(unittest.TestCase):
    def test_shipping_retains_and_uploads_symbols(self):
        self.assertIn('archive-release-symbols.py', (ROOT / 'scripts/release.sh').read_text())
        self.assertIn('"$SYMBOLS"', (ROOT / 'scripts/ship.sh').read_text())

    def test_exact_binary_and_symbols_survive_build_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'OpenRamble.xcarchive'
            app = archive / 'Products/Applications/OpenRamble.app'
            binaries = app / 'Contents/MacOS'
            binaries.mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'is.waiwai.dictation', 'CFBundleShortVersionString': '1.2.3',
                'CFBundleVersion': '42', 'CFBundleExecutable': 'OpenRamble'}))
            source = root / 'probe.c'
            source.write_text('int main(void) { return 0; }\n')
            for name in ['OpenRamble', 'openramble-cli']:
                obj = root / (name + '.o')
                subprocess.run(['xcrun', 'clang', '-g', '-c', str(source), '-o', str(obj)], check=True)
                subprocess.run(['xcrun', 'clang', str(obj), '-o', str(binaries / name)], check=True)
                symbols = archive / 'dSYMs' / (('OpenRamble.app' if name == 'OpenRamble' else name) + '.dSYM')
                subprocess.run(['xcrun', 'dsymutil', str(binaries / name), '-o', str(symbols)], check=True)
            command = ['python3', str(ROOT / 'scripts/archive-release-symbols.py'), str(archive),
                       str(root / 'saved'), '--commit', 'a' * 40]
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            saved = Path(result.stdout.strip())
            with zipfile.ZipFile(saved) as z:
                names = z.namelist()
                manifest = json.loads(z.read(next(n for n in names if n.endswith('/symbols.json'))))
                self.assertEqual(manifest['commit'], 'a' * 40)
                self.assertEqual(manifest['build'], '42')
                self.assertTrue(any('/dSYMs/OpenRamble.app.dSYM/' in n for n in names))
                self.assertTrue(any(n.endswith('/MacOS/OpenRamble') for n in names))
            # A dSYM from another build must stop publishing, never replace the archive.
            original = saved.read_bytes()
            source.write_text('int main(void) { return 1; }\n')
            subprocess.run(['xcrun', 'clang', '-g', str(source), '-o', str(binaries / 'OpenRamble')], check=True)
            changed = subprocess.run(command, text=True, capture_output=True)
            self.assertNotEqual(changed.returncode, 0)
            self.assertEqual(saved.read_bytes(), original)
