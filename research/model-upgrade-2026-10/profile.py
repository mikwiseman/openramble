"""Where the engine's time goes: mel, encoder and decoder, per input length.

    uv run --with jiwer==4.0.0 python research/model-upgrade-2026-10/profile.py <transcribe-cli> <model.gguf> <label> [fleurs] [KEY=VALUE ...]

One transcribe-cli process per repeat (one decoder thread, Metal, network
denied) recognizes the six speed inputs and the six long takes; the runtime
reports its own mel, encode and decode milliseconds for each. The first
repeat is a warm-up and is discarded. Each repeat starts only on a quiet Mac
with no other recognition process, exactly like a scorecard speed block.
Results go to profile-<label>.json next to this file.
"""
import importlib.util
import json
import os
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location('scorecard', REPO / 'scripts/scorecard/scorecard.py')
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)

REPEATS = 6


def main():
    cli, model, label = sys.argv[1], sys.argv[2], sys.argv[3]
    extra = sys.argv[4:]
    env = {**os.environ, **dict(x.split('=', 1) for x in extra if '=' in x)}
    data = sc.inputs()
    fixtures = (data['fleurs'] if 'fleurs' in extra else
                sc.speed_files(data['fleurs']) + [f for f in data['generated'] if f['suite'] == 'takes'])
    samples = {f['id']: [] for f in fixtures}
    quiet = []
    with tempfile.TemporaryDirectory() as work:
        listing = Path(work) / 'files.list'
        listing.write_text(''.join(f['path'] + '\n' for f in fixtures))
        for repeat in range(REPEATS + 1):
            quiet.append(sc.wait_for_quiet())
            out = subprocess.run(['/usr/bin/sandbox-exec', '-p', sc.PROFILE, cli, '-m', model, '--batch', str(listing),
                                  '--batch-jsonl', '--threads', '1', '--backend', 'metal', '-q'],
                                 capture_output=True, text=True, check=True, env=env).stdout
            rows = {r['file']: r for r in (json.loads(x) for x in out.splitlines() if x.startswith('{')) if 'file' in r}
            if repeat == 0:
                continue
            for f in fixtures:
                r = rows[f['path']]
                samples[f['id']].append({k: r[k] for k in ('mel_ms', 'encode_ms', 'decode_ms')})
    report = {'cli': cli, 'model': model, 'model_sha256': sc.digest(Path(model)), 'repeats': REPEATS, 'switches': extra,
              'quiet': quiet, 'inputs': []}
    for f in fixtures:
        rows = samples[f['id']]
        report['inputs'].append({'id': f['id'], 'audio_seconds': f['duration_seconds'],
                                 **{k: statistics.median(r[k] for r in rows) for k in ('mel_ms', 'encode_ms', 'decode_ms')}})
    report['median'] = {k: statistics.median(x[k] for x in report['inputs']) for k in ('mel_ms', 'encode_ms', 'decode_ms')}
    (HERE / f'profile-{label}.json').write_text(json.dumps(report, indent=1) + '\n')
    print('median per input', report['median'])
    for x in report['inputs'][:12]:
        print(f"{x['id']:28} {x['audio_seconds']:6.1f} s  mel {x['mel_ms']:6.1f}  encode {x['encode_ms']:6.1f}  decode {x['decode_ms']:6.1f} ms")


if __name__ == '__main__':
    main()
