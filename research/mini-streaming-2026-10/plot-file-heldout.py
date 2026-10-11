"""Plot the locked file-policy holdout, with quality and timing scope separated."""
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
assert d['heldoutGatePassed']
plt.rcParams.update({'font.family': 'DejaVu Sans', 'font.size': 13, 'svg.fonttype': 'none',
    'axes.spines.top': False, 'axes.spines.right': False, 'axes.spines.left': False,
    'axes.edgecolor': '#d5d7dd', 'text.color': '#25262e', 'axes.labelcolor': '#33343b',
    'xtick.color': '#585b67', 'ytick.color': '#33343b', 'figure.facecolor': 'white'})
fig, axes = plt.subplots(1, 2, figsize=(17, 8), gridspec_kw={'width_ratios': [1.7, 1]}, sharey=True)
fig.suptitle('Новые фразы подтвердили улучшение качества', x=.02, ha='left', fontsize=25, weight='bold')
languages = ['ru', 'en', 'mixed']
blue, pale, gold = '#4A59CC', '#BEC5F2', '#B49568'
for key, offset, color, label in [('control', -.17, pale, 'Исходный вариант'),
                                   ('selected', .17, blue, 'Выбранный вариант')]:
    values = [100 * d['comparisons'][lang][key]['quality']['wer'] for lang in languages]
    bars = axes[0].barh(np.arange(3) + offset, values, .29, color=color, label=label, zorder=3)
    axes[0].bar_label(bars, labels=[f'{v:.2f}%' for v in values], padding=6, fontsize=12)
costs = [100 * (d['comparisons'][lang]['selected']['medianSeconds'] /
               d['comparisons'][lang]['control']['medianSeconds'] - 1) for lang in languages]
bars = axes[1].barh(np.arange(3), costs, .45, color=gold, zorder=3)
axes[1].bar_label(bars, labels=[f'+{v:.2f}%' for v in costs], padding=6, fontsize=12)
axes[0].set_xlim(0, 51)
axes[1].set_xlim(0, 8.5)
axes[0].set_title('Ошибки слов, WER · меньше лучше', loc='left', fontsize=17, pad=20)
axes[1].set_title('Цена более короткой нарезки', loc='left', fontsize=17, pad=20)
axes[0].set_xlabel('WER, %', labelpad=12)
axes[1].set_xlabel('Рост медианы времени обработки, %', labelpad=12)
axes[0].set_yticks(range(3), ['Русский', 'Английский', 'RU + EN'])
axes[0].invert_yaxis()
for ax in axes:
    ax.grid(axis='x', color='#e9eaf0', zorder=0)
    ax.tick_params(axis='y', length=0)
fig.legend(*axes[0].get_legend_handles_labels(), loc='upper right', bbox_to_anchor=(.96, .94), frameon=False, ncol=2)
fig.subplots_adjust(left=.12, right=.96, top=.81, bottom=.28, wspace=.28)
fig.text(.02, .035,
    'Mac Mini M4, 16 ГиБ · одна Parakeet v3 Q8, Metal · 50 новых разных фраз RU и 50 EN, повторённых в трёх файлах около 59 минут.\n'
    '18 нативных запусков: три языка × два предела фрагмента × три повтора. Повторы не увеличивают разнообразие речевых примеров.\n'
    'Слева: 30 с с исходным стыком → 15 с с сохранением слов через разрыв. Правило стыка рассчитано по тем же нативным словам.\n'
    'Справа: время нативной нарезки 30 с → 15 с с исходным стыком в обоих случаях. Полный вариант отдельно проверен в FileTranscriber.\n'
    'Настройки выбраны до открытия этих фраз. Ошибок стало меньше во всех трёх наборах, но смешанная речь всё ещё содержит много ошибок.',
    ha='left', va='bottom', fontsize=10.5, color='#5D606B', linespacing=1.5)
a.out.mkdir(parents=True, exist_ok=True)
for ext in ('png', 'svg'):
    fig.savefig(a.out / f'file-quality-heldout.{ext}', dpi=180)
plt.close(fig)
