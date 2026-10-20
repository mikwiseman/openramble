"""Render descriptive paired uncertainty from the existing product comparison."""
import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument("--input", type=Path, required=True)
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()
data = json.loads(args.input.read_text())
assert data["aggregateReproductionPassed"]
args.out.mkdir(parents=True, exist_ok=True)
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 12,
                     "axes.spines.top": False, "axes.spines.right": False,
                     "axes.spines.left": False, "axes.edgecolor": "#d5d7dd",
                     "text.color": "#25262e", "axes.labelcolor": "#33343b",
                     "xtick.color": "#585b67", "ytick.color": "#33343b",
                     "svg.fonttype": "none", "figure.facecolor": "white"})
blue = "#4A59CC"
fig, axes = plt.subplots(1, 2, figsize=(15, 7.5), sharex=True, sharey=True)
fig.suptitle("Разброс важнее небольших различий WER", x=.02, ha="left", fontsize=25, weight="bold")
comparators = ["handy", "whisper", "superwhisper_turbo"]
names = ["Handy · Parakeet v3 Q8", "whisper.cpp · Turbo F16", "Superwhisper · Turbo F16"]
for ax, language, title in zip(axes, ["ru", "en"], ["Русский", "Английский"]):
    entry = data["languageResults"][language]
    ax.set_title(f"{title}: 100 записей, {entry['referenceClusters']} разных фраз", loc="left", fontsize=15, pad=20)
    for y, product in enumerate(comparators):
        row = entry["pairedDifferences"][product]
        point = row["werDifferencePercentagePoints"]
        low, high = row["phraseCluster95PercentileIntervalPercentagePoints"]
        ax.errorbar(point, y, xerr=[[point - low], [high - point]], fmt="o", color=blue, capsize=6, markersize=8, lw=2)
        label = "Совпадение слов на всех 100 записях" if product == "handy" else f"{point:+.2f} п.п.  [{low:+.2f}; {high:+.2f}]"
        ax.text(.02, y + .23, label, transform=ax.get_yaxis_transform(), fontsize=10.5, color="#5D606B", va="top")
    ax.axvline(0, color="#969BAB", lw=1.2, linestyle="--", zorder=0)
    ax.set_yticks(range(3), names)
    ax.set_xlim(-1.8, 2.35)
    ax.set_ylim(2.75, -.6)
    ax.grid(axis="x", color="#eceef3", zorder=0)
    ax.tick_params(axis="y", length=0)
    ax.set_xlabel("Разница WER, процентные пункты\nСлева от нуля меньше ошибок у OpenRamble", labelpad=13)
fig.subplots_adjust(top=.82, bottom=.30, left=.20, right=.97, wspace=.22)
fig.text(.02, .035,
    "M4 Pro · одни и те же 100 RU + 100 EN файлов FLEURS. Разница = WER OpenRamble − WER сравниваемого продукта.\n"
    "Отрезки: 95%-е парные интервалы, 10 000 перевыборок групп одинаковых нормализованных фраз; seed 20261011.\n"
    "Все интервалы различий с Turbo включают ноль. Это описательный анализ выбранных фраз, а не доказательство равенства продуктов.\n"
    "Зависимость между записями одного неизвестного диктора не учитывается. Интервалы не скорректированы на множественные сравнения.",
    fontsize=10.5, color="#5D606B", linespacing=1.6, va="bottom")
for extension in ("png", "svg"):
    fig.savefig(args.out / f"quality-uncertainty.{extension}", dpi=180)
plt.close(fig)

products = ["openramble", "handy", "whisper", "superwhisper_turbo"]
labels = ["OpenRamble", "Handy", "whisper.cpp", "Superwhisper"]
fig, axes = plt.subplots(1, 2, figsize=(14, 7.2), sharex=True, sharey=True)
fig.suptitle("Какие ошибки складываются в WER", x=.02, ha="left", fontsize=25, weight="bold")
for ax, language, title in zip(axes, ["ru", "en"], ["Русский · 100 записей", "Английский · 100 записей"]):
    rows = data["languageResults"][language]["products"]
    left = np.zeros(len(products))
    for field, name, color in [("substitutions", "Замены", blue), ("deletions", "Пропуски", "#BD8556"), ("insertions", "Лишние слова", "#9BA8BD")]:
        values = np.array([100 * rows[p][field] / rows[p]["reference_words"] for p in products])
        ax.barh(range(4), values, .52, left=left, color=color, label=name, zorder=3)
        left += values
    for y, value in enumerate(left):
        ax.text(value + .12, y, f"{value:.2f}%", va="center", fontsize=12)
    ax.set_title(title, loc="left", fontsize=16, pad=15)
    ax.set_yticks(range(4), labels)
    ax.set_xlim(0, 7.2)
    ax.set_ylim(3.6, -.6)
    ax.grid(axis="x", color="#eceef3", zorder=0)
    ax.tick_params(axis="y", length=0)
    ax.set_xlabel("Ошибки / число слов эталона, %", labelpad=12)
handles, legend_labels = axes[0].get_legend_handles_labels()
fig.legend(handles, legend_labels, frameon=False, loc="upper right", bbox_to_anchor=(.98, .91), ncol=3)
fig.subplots_adjust(top=.76, bottom=.24, left=.14, right=.97, wspace=.24)
fig.text(.02, .035,
    "M4 Pro · общая нормализация, без пунктуации и регистра; числа не разворачиваются словами.\n"
    "WER = (замены + пропуски + лишние слова) / число слов эталона. Подсчёты точно воспроизводят опубликованные суммы.\n"
    "Каждая исходная запись включена один раз. Составные длинные файлы и повторы измерений времени сюда не входят.",
    fontsize=10.5, color="#5D606B", linespacing=1.5, va="bottom")
for extension in ("png", "svg"):
    fig.savefig(args.out / f"quality-error-types.{extension}", dpi=180)
plt.close(fig)
