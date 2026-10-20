"""Show the fixed system-channel threshold on the second untouched selection."""
import argparse
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

p = argparse.ArgumentParser()
p.add_argument('--decision', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
d = json.loads(a.decision.read_text())
assert d['completedRuns'] == 4
rows = sorted(d['comparisons'], key=lambda r: {'ru': 0, 'en': 1}[r['language']])
plt.rcParams.update({'font.family': 'DejaVu Sans', 'font.size': 13, 'svg.fonttype': 'none',
    'axes.spines.top': False, 'axes.spines.right': False, 'axes.spines.left': False,
    'axes.edgecolor': '#d5d7dd', 'text.color': '#25262e', 'figure.facecolor': 'white'})
fig, axes = plt.subplots(1, 2, figsize=(17, 8), sharey=True)
fig.suptitle('Тихий системный звук: проверка на новых фразах', x=.02, ha='left', fontsize=25, weight='bold')
for key, offset, color, label in [('control', -.18, '#BEC5F2', 'Порог 0,02'),
                                  ('candidate', .18, '#4A59CC', 'Системный порог 0,005')]:
    for ax, values, units in [
        (axes[0], [100 * r[key]['quality']['wer'] for r in rows], '%'),
        (axes[1], [100 * r[key]['submittedFrames'] / (r['audioSeconds'] * 16000) for r in rows], '%')]:
        bars = ax.barh(np.arange(2) + offset, values, .30, color=color, label=label, zorder=3)
        ax.bar_label(bars, labels=[f'{v:.2f}{units}' for v in values], padding=6, fontsize=12)
axes[0].set_title('Ошибки слов, WER · меньше лучше', loc='left', fontsize=17, pad=20)
axes[1].set_title('Передано модели от исходного аудио', loc='left', fontsize=17, pad=20)
axes[0].set_xlabel('WER, %', labelpad=12)
axes[1].set_xlabel('Переданные аудиокадры, %', labelpad=12)
axes[0].set_yticks(range(2), ['Русский · 50 фраз', 'Английский · 50 фраз'])
axes[0].invert_yaxis()
for ax in axes:
    ax.set_xlim(0, 112)
    ax.grid(axis='x', color='#e9eaf0', zorder=0)
    ax.tick_params(axis='y', length=0)
fig.legend(*axes[0].get_legend_handles_labels(), loc='upper right', bbox_to_anchor=(.97, .94), frameon=False, ncol=2)
fig.subplots_adjust(left=.16, right=.97, top=.79, bottom=.30, wspace=.25)
status = 'Все заранее заданные условия пройдены; изменение внедрено в ветке PR, ещё не выпущено.' if d.get('adoptionApproved') else 'Решение о принятии варианта смотрите в таблице условий; выигрыш качества сам по себе недостаточен.'
fig.text(.02, .035,
    'Mac Mini M4, 16 ГиБ · одна Parakeet v3 Q8, Metal · второй отложенный набор, без пересечения с 300 предыдущими записями.\n'
    '50 RU и 50 EN фраз использованы по одному разу с паузами 0,5 с. Четыре запуска, один на язык и настройку.\n'
    'Меняется только системный канал; микрофон остаётся на 0,02. Проверки захвата и эха пройдены отдельно до открытия выборки.\n'
    'Порог выбран заранее, без подгонки по этим результатам. Стенд подаёт подготовленное аудио; реальные устройства и звонки здесь не измерены.\n'
    + status, ha='left', va='bottom', fontsize=10.5, color='#5D606B', linespacing=1.5)
a.out.mkdir(parents=True, exist_ok=True)
for ext in ('png', 'svg'):
    fig.savefig(a.out / f'system-heldout.{ext}', dpi=180)
plt.close(fig)
