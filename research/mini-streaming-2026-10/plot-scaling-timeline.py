"""Show chronological scaling evidence, including interruptions and host cleanup."""
import argparse
from datetime import datetime
import gzip
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

parser = argparse.ArgumentParser()
parser.add_argument('--data', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
summary = json.loads((args.data/'summary.json').read_text())
events = json.loads((args.data/'condition-events.json').read_text())
def read(name):
    with gzip.open(args.data/name, 'rt') as stream:
        return [json.loads(line) for line in stream]
def stamp(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
runs = {r['id']: r for r in read('public-runs.jsonl.gz')}
observations = read('system-observations.jsonl.gz')
start = min(stamp(r['before']['utc']) for r in observations)
colors = {'ru': '#4A59CC', 'en': '#6F8996', 'mixed': '#B49568'}
markers = {1: 'o', 2: 's', 4: 'D'}
plt.rcParams.update({'font.family': 'DejaVu Sans', 'font.size': 12,
                     'axes.spines.top': False, 'axes.spines.right': False,
                     'axes.spines.left': False, 'axes.edgecolor': '#d5d7dd',
                     'svg.fonttype': 'none'})
fig, (timing, memory) = plt.subplots(2, 1, figsize=(15, 9), sharex=True,
                                    gridspec_kw={'height_ratios': [1.3, 1]})
fig.suptitle('Что происходило между повторами', x=.03, ha='left', fontsize=25, weight='bold')
for item in observations:
    row = runs[item['id']]
    x = (stamp(item['before']['utc']) - start) / 60
    color = colors[row['fixture'].split('-')[0]]
    marker = 'P' if row['mode'] == 'shipping-file' else markers[row['workers']]
    timing.scatter(x, row['processingSeconds'], color=color, marker=marker, s=75, zorder=3)
    memory.scatter(x, row['sampledPeakPhysicalFootprintBytes']/2**30,
                   color=color, marker=marker, s=75, zorder=3)
for failure in summary['failures']:
    assert failure.get('utc'), 'failure timestamps must be preserved'
    x = (stamp(failure['utc']) - start) / 60
    peak = max((s.get('memory', {}).get('physicalFootprintBytes', 0)
                for s in failure['samples'] if s.get('memory')), default=0) / 2**30
    color = '#B03B40' if failure['hardStop'] == 'memory pressure' else '#777B88'
    memory.scatter(x, peak, color=color, marker='x', s=85, linewidths=2, zorder=4)
    # The lower axis accounts for failures; no failed process duration is
    # presented as a successful transcription time on the upper axis.
for event in events['events']:
    x = (stamp(event['utc']) - start) / 60
    for axis in (timing, memory):
        axis.axvline(x, color='#8B67A0', linestyle='--', linewidth=1.2, zorder=1)
    timing.text(x+.4, .96, 'Закрыты фоновые процессы', transform=timing.get_xaxis_transform(),
                fontsize=11, va='top', color='#735184')
timing.set_ylabel('Обработка файла, с')
memory.set_ylabel('Пик физической памяти, ГиБ')
memory.set_xlabel('Минуты с начала отдельной серии 11 октября')
for axis in (timing, memory):
    axis.grid(axis='y', color='#e9eaf0')
    axis.set_ylim(bottom=0)
    axis.tick_params(length=0)
legend = [Line2D([], [], marker='o', linestyle='', color=color, label=language)
          for language, color in zip(['RU', 'EN', 'RU + EN'], colors.values())]
legend += [Line2D([], [], marker=marker, linestyle='', color='#444750', label=label)
           for marker, label in [('o', '1 модель'), ('s', '2 модели'), ('D', '4 модели · n=1')]]
if any(r['mode']=='shipping-file' for r in runs.values()):
    legend.append(Line2D([], [], marker='P', linestyle='', color='#444750', label='Путь приложения'))
legend += [Line2D([], [], marker='x', linestyle='', color=color, label=label)
           for color, label in [('#B03B40', 'Прервано: память'), ('#777B88', 'Прервано: сборка')]]
fig.legend(handles=legend, loc='upper center', bbox_to_anchor=(.51, .93), ncol=4, frameon=False, fontsize=10)
fig.subplots_adjust(top=.81, bottom=.17, left=.095, right=.97, hspace=.15)
fig.text(.03, .025,
         'Mac Mini M4, 16 ГиБ · Parakeet v3 Q8 · три фиксированных файла около 59 минут, свежий процесс и прогрев перед каждым запуском.\n'
         'На верхнем графике только завершённые распознавания. Кресты снизу — прерванные попытки с максимумом памяти до остановки.\n'
         'Память измерена с шагом 1 с и включает загрузку. Пунктир: закрыты простаивавшие процессы, занимавшие около 1,59 ГиБ физической памяти.\n'
         'Рабочий компьютер использовался и для других задач. Все условия, прерывания и диапазоны сохранены; универсальный выигрыш не заявляется.',
         fontsize=10.5, color='#5D606B', linespacing=1.5)
args.out.mkdir(parents=True, exist_ok=True)
for extension in ('png', 'svg'):
    fig.savefig(args.out/f'scaling-timeline.{extension}', dpi=180)
