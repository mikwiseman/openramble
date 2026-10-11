"""Plot the fixed activity-threshold experiment, including empty-output work."""
import argparse
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument('--input', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
data = json.loads(args.input.read_text())
assert data['completedRuns'] == 18
speech = [r for r in data['comparisons'] if r['control']['quality'] is not None]
negative = [r for r in data['comparisons'] if r['control']['quality'] is None]
assert len(speech) == 4 and len(negative) == 5
args.out.mkdir(parents=True, exist_ok=True)
plt.rcParams.update({'font.family': 'DejaVu Sans', 'font.size': 12, 'svg.fonttype': 'none',
                     'axes.spines.top': False, 'axes.spines.right': False, 'axes.spines.left': False,
                     'axes.edgecolor': '#d5d7dd', 'text.color': '#25262e', 'figure.facecolor': 'white'})
styles = [('control', -.18, '#4A59CC', 'Порог 0,02'), ('candidate', .18, '#B49568', 'Порог 0,005')]

def finish(fig, name, caption, left=.17):
    fig.subplots_adjust(left=left, right=.96, top=.80, bottom=.24, wspace=.25)
    handles, labels = fig.axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc='upper right', bbox_to_anchor=(.96, .91), frameon=False, ncol=2)
    fig.text(.02, .025, caption, fontsize=10.5, color='#5d606b', va='bottom', linespacing=1.5)
    for extension in ('png', 'svg'):
        fig.savefig(args.out / f'{name}.{extension}', dpi=180)
    plt.close(fig)

fig, axes = plt.subplots(1, 2, figsize=(16, 8), sharey=True)
fig.suptitle('Тихая речь: порог активности и потери', x=.02, ha='left', fontsize=25, weight='bold')
for variant, offset, color, label in styles:
    for ax, field in zip(axes, ('coverage', 'wer')):
        values = ([100*r[variant]['submittedFrames']/(r['audioSeconds']*16000) for r in speech]
                  if field == 'coverage' else [100*r[variant]['quality']['wer'] for r in speech])
        bars = ax.barh(np.arange(4)+offset, values, .30, color=color, label=label, zorder=3)
        ax.bar_label(bars, labels=[f'{v:.1f}' for v in values], padding=5, fontsize=11)
for ax, title, limit in zip(axes, ('Передано модели, % аудио', 'Ошибки слов, WER %'), (115, 100)):
    ax.set_title(title, loc='left', fontsize=17, pad=18)
    ax.set_xlim(0, limit)
    ax.grid(axis='x', color='#e9eaf0', zorder=0)
    ax.tick_params(axis='y', length=0)
axes[0].set_yticks(range(4), [r['fixture'].replace('ru-', 'RU · ').replace('en-', 'EN · ').replace('360s', '6 минут').replace('60s', '1 минута') for r in speech])
axes[0].invert_yaxis()
finish(fig, 'quiet-speech',
       'Mac Mini M4, 16 ГиБ · одна Parakeet v3 Q8, Metal · четыре фиксированных публичных составных входа FLEURS, исходная громкость.\n'
       'Одна обработка каждой пары. Оба порога используют исправленный отсчёт сегментов; сохранение всего тихого аудио выключено.\n'
       'Подача ускорена с ожиданием очереди. Эта проверка локализует потери и не представляет все реальные микрофоны, комнаты и встречи.\n'
       'Глобальное снижение порога отклонено из-за эха. Отдельный порог системного канала рассматривается только после новых проверок.')

fig, axes = plt.subplots(1, 2, figsize=(16, 9), sharey=True)
fig.suptitle('Шум: лишние слова и работа модели', x=.02, ha='left', fontsize=25, weight='bold')
for variant, offset, color, label in styles:
    for ax, metric in zip(axes, ('words', 'work')):
        values = ([r[variant]['normalizedWords'] for r in negative] if metric == 'words'
                  else [r[variant]['decodeWork']['totalSeconds'] for r in negative])
        bars = ax.barh(np.arange(5)+offset, values, .30, color=color, label=label, zorder=3)
        ax.bar_label(bars, labels=[str(v) if metric == 'words' else f'{v:.3f}' for v in values], padding=6, fontsize=11)
for ax, title in zip(axes, ('Распознанных слов без речи', 'Суммарное декодирование, с')):
    ax.set_title(title, loc='left', fontsize=17, pad=18)
    ax.set_xlim(0, max(1, ax.get_xlim()[1])*1.25)
    ax.grid(axis='x', color='#e9eaf0', zorder=0)
    ax.tick_params(axis='y', length=0)
axes[0].set_xlim(0, 1.1)
axes[0].set_xticks([0, 1])
axes[1].set_xlim(0, max(r[v]['decodeWork']['totalSeconds'] for r in negative for v in ('control', 'candidate')) * 1.4)
axes[0].set_yticks(range(5), ['Цифровая тишина', 'Шум до 0,003', 'Шум до 0,01', 'Тон 50 Гц · 0,01', 'Щелчки 1 мс · 0,3'])
axes[0].invert_yaxis()
finish(fig, 'quiet-noise',
       'Mac Mini M4, 16 ГиБ · одна Parakeet v3 Q8, Metal · пять синтетических входов по 20 секунд, одна обработка при каждом пороге.\n'
       'Пустая эталонная фраза: считаются выданные слова, WER не вычисляется. Нулевой текст не означает нулевую вычислительную работу.\n'
       'Загрузка и прогрев исключены из времени декодирования. Число вызовов, максимум одного вызова и хеши PCM сохранены в таблицах.\n'
       'Для принятия кандидата все пять входов должны дать ноль слов, а отдельный вызов модели не должен превысить две секунды.')
