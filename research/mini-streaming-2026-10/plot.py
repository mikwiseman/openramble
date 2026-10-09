"""Standalone figures, generated only from recorded measurements."""
import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument("--summary", type=Path, required=True)
parser.add_argument("--old", type=Path, required=True)
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()
data = json.loads(args.summary.read_text())
old = json.loads(args.old.read_text())
args.out.mkdir(parents=True, exist_ok=True)
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 13,
                     "axes.spines.top": False, "axes.spines.right": False,
                     "axes.spines.left": False, "axes.edgecolor": "#d5d7dd",
                     "axes.labelcolor": "#33343b", "text.color": "#25262e",
                     "xtick.color": "#585b67", "ytick.color": "#33343b",
                     "svg.fonttype": "none", "figure.facecolor": "white"})
blue, pale = "#4A59CC", "#BEC5F2"


def finish(fig, name, caption, bottom=.20, left=.12):
    fig.subplots_adjust(bottom=bottom, top=.83, left=left, right=.97, wspace=.26)
    fig.text(.02, .02, caption, ha="left", va="bottom", fontsize=10.5, linespacing=1.5, color="#5D606B")
    for extension in ("png", "svg"):
        fig.savefig(args.out / f"{name}.{extension}", dpi=180)
    plt.close(fig)


primary = [g for g in data["groups"] if g["mode"] == "controller" and g["pacing"] == "realtime"]
if len(primary) == 8:
    fig, axes = plt.subplots(1, 2, figsize=(15, 7.8), sharex=True, sharey=True)
    fig.suptitle("Ожидание после Stop", x=.02, ha="left", fontsize=25, weight="bold")
    names = ["ru-short", "en-short", "ru-60s", "en-60s"]
    labels = ["RU · 10,92 с", "EN · 10,18 с", "RU · 66,24 с", "EN · 61,92 с"]
    limit = max(g["seconds"]["p95"] for g in primary) * 1000 * 1.26
    for ax, condition, title in zip(axes, ["normal", "cpu10"], ["Обычная нагрузка", "10 занятых CPU-процессов"]):
        groups = [next(g for g in primary if g["fixture"] == name and g["condition"] == condition) for name in names]
        for offset, stat, color in [(-.17, "p50", blue), (.17, "p95", pale)]:
            values = [g["seconds"][stat]*1000 for g in groups]
            bars = ax.barh(np.arange(4)+offset, values, .3, color=color, label=stat, zorder=3)
            ax.bar_label(bars, labels=[f"{v:.0f}" for v in values], padding=5, fontsize=11)
        ax.set_title(title, loc="left", pad=18, fontsize=17)
        ax.set_yticks(np.arange(4), labels)
        ax.set_xlim(0, limit)
        ax.set_xlabel("Миллисекунды, меньше лучше", labelpad=12)
        ax.grid(axis="x", color="#e9eaf0", zorder=0)
        ax.tick_params(axis="y", length=0)
        ax.legend(frameon=False, loc="lower right", ncol=2)
    axes[0].invert_yaxis()
    finish(fig, "stop-latency", "Mac Mini M4, 16 ГиБ · OpenRamble 0.32.0 · Parakeet v3 Q8 · Metal · 20 повторов на условие, четыре фиксированных входа FLEURS.\n"
           "p50 — медиана, p95 — 95-й процентиль, линейная интерполяция. Прогретая модель, подача PCM в реальном темпе.\n"
           "От вызова Stop контроллера до тестового приёмника текста. Без физической клавиши, микрофона и вставки в стороннее приложение.")

fig, axes = plt.subplots(1, 2, figsize=(15, 7.5), sharex=True, sharey=True)
fig.suptitle("Ошибки распознавания на 200 записях", x=.02, ha="left", fontsize=25, weight="bold")
products = ["openramble", "handy", "whisper", "superwhisper_turbo"]
labels = ["OpenRamble 0.32.0", "Handy 0.9.8", "whisper.cpp 1.9.5", "Superwhisper 2.19.2"]
for ax, lang, title in zip(axes, ["ru", "en"], ["Русский, 100 записей", "Английский, 100 записей"]):
    vals = [old["quality"][p][lang]["wer"]*100 for p in products]
    bars=ax.barh(range(4), vals, .55, color=[blue,"#AEB4C8","#6F8996","#B49568"], zorder=3)
    ax.bar_label(bars, labels=[f"{v:.2f}%" for v in vals], padding=6, fontsize=13)
    ax.set_yticks(range(4), labels)
    ax.set_xlim(0,8)
    ax.set_title(title,loc="left",fontsize=17,pad=18)
    ax.set_xlabel("WER, % · меньше лучше",labelpad=12)
    ax.grid(axis="x",color="#e9eaf0",zorder=0)
    ax.tick_params(axis="y",length=0)
axes[0].invert_yaxis()
fig.subplots_adjust(left=.18)
finish(fig,"word-errors","Отдельная серия M4 Pro, 14 CPU, 24 ГБ · FLEURS test, одни и те же файлы для всех продуктов.\n"
       "OpenRamble и Handy: Parakeet v3 Q8. whisper.cpp и Superwhisper: локальная Turbo. Нормализованные слова OpenRamble и Handy совпали 200/200.\n"
       "Небольшие различия WER на этом наборе не доказывают статистического превосходства.",left=.18)

files = [g for g in data["groups"] if g["mode"] == "file"]
if files:
    fig, axes = plt.subplots(1,3,figsize=(17,7.7))
    fig.suptitle("Параллельная обработка 59 минут аудио",x=.02,ha="left",fontsize=25,weight="bold")
    for language,color,offset in zip(["ru","en","mixed"],[blue,"#6F8996","#B49568"],[-.23,0,.23]):
        groups = [next((g for g in files if g["fixture"] == f"{language}-3540s" and g["workers"]==w),None) for w in (1,2,4)]
        for ax,key,title in zip(axes,["seconds","memory","wer"],["Время обработки, с","Пик физической памяти, ГиБ","Ошибки слов, WER %"]):
            values=[np.nan if g is None else g["seconds"]["p50"] if key=="seconds" else g["sampledPeakPhysicalFootprintBytes"]/2**30 if key=="memory" else g["wer"]["p50"]*100 for g in groups]
            bars=ax.bar(np.arange(3)+offset,values,.21,color=color,zorder=3,label={"ru":"RU","en":"EN","mixed":"RU + EN"}[language])
            ax.bar_label(bars,labels=["" if np.isnan(v) else f"{v:.1f}" for v in values],padding=4,fontsize=9)
            if key=="seconds":
                mins=[0 if g is None else g["seconds"]["p50"]-g["seconds"]["min"] for g in groups]
                maxs=[0 if g is None else g["seconds"]["max"]-g["seconds"]["p50"] for g in groups]
                ax.errorbar(np.arange(3)+offset,values,yerr=[mins,maxs],fmt="none",ecolor="#25262e",capsize=3,lw=1,zorder=4)
            ax.set_title(title,loc="left",fontsize=15,pad=15)
            ax.set_xticks(range(3),["1 модель","2 модели","4 модели"])
            ax.set_ylim(bottom=0)
            ax.grid(axis="y",color="#e9eaf0",zorder=0)
            ax.tick_params(axis="both",length=0)
    axes[2].legend(frameon=False,loc="upper left")
    if not any(g["workers"] == 4 for g in files):
        for ax in axes:
            ax.text(2, .15, "Остановлено\nпо памяти", transform=ax.get_xaxis_transform(), ha="center", fontsize=10, color="#777B88")
    for ax in axes: ax.set_ylim(0,ax.get_ylim()[1]*1.18)
    finish(fig,"parallel-files","Mac Mini M4, 16 ГиБ · Parakeet v3 Q8 · Metal · одинаковые фрагменты и сборка текста в исходном порядке.\n"
           "Время: медиана, отрезки: минимум–максимум повторов. Загрузка и прогрев моделей не входят. Память: максимум выборки с шагом 1 с, включая загрузку.\n"
           "Файлы составлены из целых фраз FLEURS с паузами 0,5 с. Это проверка длинного ввода, а не естественная встреча.\n"
           "Смешанный RU/EN показан полностью: большое число пропусков нельзя считать ускорением.",bottom=.25)

    fig,ax=plt.subplots(figsize=(13,8))
    fig.suptitle("Скорость и качество на тех же длинных файлах",x=.02,ha="left",fontsize=23,weight="bold")
    for lang,color in zip(["ru","en","mixed"],[blue,"#6F8996","#B49568"]):
        for workers,marker in [(1,"o"),(2,"s"),(4,"D")]:
            g=next((g for g in files if g["fixture"]==f"{lang}-3540s" and g["workers"]==workers),None)
            if g:
                x,y=g["seconds"]["p50"],g["wer"]["p50"]*100
                ax.scatter(x,y,s=100,marker=marker,color=color,edgecolors="white",linewidths=1,zorder=3)
                ax.annotate(f"{lang.upper()}, {workers}",(x,y),xytext=(5,7+12*(workers==2)),textcoords="offset points",fontsize=10)
    ax.set_xlim(left=0);ax.set_ylim(bottom=0)
    ax.set_xlabel("Полная обработка файла, с · меньше лучше",labelpad=14)
    ax.set_ylabel("Ошибки слов, WER % · меньше лучше",labelpad=14)
    ax.grid(color="#e9eaf0",zorder=0)
    finish(fig,"quality-vs-time","Mac Mini M4, 16 ГиБ · OpenRamble 0.32.0 · Parakeet v3 Q8, Metal · три составных файла около 59 минут.\n"
           "Подпись: язык и число независимых моделей. Скорость: медиана повторов, без загрузки модели. WER на фиксированном входе.\n"
           "Сравнивать число моделей можно внутри одного цвета. Языковые файлы содержат разные исходные фразы.")
