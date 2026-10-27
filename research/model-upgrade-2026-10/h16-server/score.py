"""Turn out/ into results.json: python3 score.py SCORECARD_ROOT OUT RESULTS.

WER uses the scorecard's own normalization and aligner, so these numbers sit
next to its hour-file rows. Memory is in bytes, time in seconds.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'scripts/scorecard'))
import scorecard  # noqa: E402

root, out, results = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
references = {f['id']: f['reference'] for f in json.loads((root / 'scorecard-inputs.json').read_text())['hour']}


def load(path):
    return json.loads(path.read_text()) if path.exists() else None


report = {'cpus': (out / 'nproc.txt').read_text().strip()}
for label in ('before', 'after'):
    rows = {}
    for fixture in ('en-3540s', 'ru-3540s'):
        text = load(out / f'{label}-{fixture}.json')['text']
        rows[fixture] = {'wer': scorecard.wer_counts([(references[fixture], text)]),
                         'memory': load(out / f'{label}-{fixture}.memory.json')['peak'],
                         **load(out / f'{label}-{fixture}.time.json')}
    served = load(out / f'{label}-serve-en-3540s.json')
    rows['serve'] = {'idle_after_load': load(out / f'{label}-serve.idle.json')['last'],
                     'job_peak': load(out / f'{label}-serve.job.json')['peak'],
                     'same_text_as_file_mode': scorecard.norm(served['text']) == scorecard.norm(
                         load(out / f'{label}-en-3540s.json')['text']),
                     **load(out / f'{label}-serve.ready.json'), **load(out / f'{label}-serve.time.json')}
    report[label] = rows
report['word_changes'] = {fixture: scorecard.wer_counts([(load(out / f'before-{fixture}.json')['text'],
                                                            load(out / f'after-{fixture}.json')['text'])])
                          for fixture in ('en-3540s', 'ru-3540s')}
results.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n')
print(json.dumps(report, indent=1))
