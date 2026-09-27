#!/usr/bin/env python3
"""Keep the exact release archive beyond build cleanup, including UUID evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile


def uuids(binary):
    output = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(binary)], text=True)
    result = {arch: uuid.upper() for uuid, arch in re.findall(r'UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)', output)}
    if not result:
        raise ValueError(f'No Mach-O UUIDs in {binary.name}')
    return result


def archive_symbols(archive, output, commit):
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('An exact source commit is required')
    app = archive / 'Products/Applications/OpenRamble.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != 'is.waiwai.dictation':
        raise ValueError('Not the production application')
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'\d+', build):
        raise ValueError('Invalid release version/build')
    records = {}
    for executable, dsym in [('OpenRamble', 'OpenRamble.app'), ('openramble-cli', 'openramble-cli')]:
        binary = app / 'Contents/MacOS' / executable
        symbols = archive / 'dSYMs' / (dsym + '.dSYM')
        ids = uuids(binary)
        if ids != uuids(symbols):
            raise ValueError(f'dSYM UUID mismatch: {executable}')
        records[executable] = {'uuids': ids, 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    manifest = {'version': version, 'build': build, 'commit': commit, 'binaries': records}
    output.mkdir(parents=True, exist_ok=True)
    destination = output / f'OpenRamble-{version}-symbols.zip'
    if destination.exists():
        with zipfile.ZipFile(destination) as saved:
            existing = json.loads(saved.read('OpenRamble-Symbols/symbols.json'))
        if existing != manifest:
            raise ValueError('Refusing to overwrite symbols from a different release build')
        return destination
    with tempfile.TemporaryDirectory(prefix='.symbols-', dir=output) as temporary:
        stage = Path(temporary) / 'OpenRamble-Symbols'
        stage.mkdir()
        shutil.copytree(archive, stage / 'OpenRamble.xcarchive', symlinks=True)
        (stage / 'symbols.json').write_text(json.dumps(manifest, indent=2) + '\n')
        zipped = Path(temporary) / 'symbols.zip'
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', str(stage), str(zipped)], check=True)
        # No replace: an already-published version's symbols are immutable.
        os.link(zipped, destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    print(archive_symbols(args.archive, args.output, args.commit).resolve())


if __name__ == '__main__':
    main()
