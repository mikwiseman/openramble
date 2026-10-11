"""Plot registered follow-up results without pooling timing cohorts."""
import argparse
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

p = argparse.ArgumentParser()
p.add_argument('--quality', type=Path)
p.add_argument('--before', type=Path)
p.add_argument('--after', type=Path)
p.add_argument('--tail', type=Path)
p.add_argument('--out', required=True, type=Path)
a = p.parse_args()
a.out.mkdir(parents=True, exist_ok=True)
plt.rcParams.update({'font.family':'DejaVu Sans','font.size':12,'svg.fonttype':'none',
    'axes.spines.top':False,'axes.spines.right':False,'axes.spines.left':False,
    'axes.edgecolor':'#d5d7dd','text.color':'#25262e','axes.labelcolor':'#33343b',
    'xtick.color':'#585b67','ytick.color':'#33343b','figure.facecolor':'white'})
blue, pale, gold = '#4A59CC', '#BEC5F2', '#B49568'

def save(fig, name, caption, left=.18, bottom=.20):
    fig.subplots_adjust(left=left,right=.96,top=.82,bottom=bottom,wspace=.27)
    fig.text(.02,.025,caption,ha='left',va='bottom',fontsize=10.5,color='#5D606B',linespacing=1.5)
    for ext in ('png','svg'):fig.savefig(a.out/f'{name}.{ext}',dpi=180)
    plt.close(fig)

if a.quality:
    q = json.loads(a.quality.read_text())
    policies = q['policies']
    settings = sorted({(r['segmentSeconds'],r['minimumSegmentSeconds'],r['overlapMilliseconds']) for r in policies})
    shared_limit = np.ceil((max(100*r['comparisons'][lang]['candidateWER'] for r in policies for lang in ('ru','en','mixed')) + 3) / 5) * 5
    chosen = q['selectedPolicy']
    selected_row = settings.index((chosen['segmentSeconds'], chosen['minimumSegmentSeconds'], chosen['overlapMilliseconds'])) if chosen else None
    fig, axes = plt.subplots(1,3,figsize=(17,9),sharey=True)
    fig.suptitle('Проверка правил обработки длинных файлов',x=.02,ha='left',fontsize=25,weight='bold')
    for ax,lang,title in zip(axes,('ru','en','mixed'),('Русский','Английский','RU + EN')):
        for variant,offset,color,marker,label in [(False,-.15,blue,'o','Текущий стык'),(True,.15,gold,'D','Вариант стыка')]:
            vals=[100*next(r for r in policies if (r['segmentSeconds'],r['minimumSegmentSeconds'],r['overlapMilliseconds'])==s and r['preserveGap']==variant)['comparisons'][lang]['candidateWER'] for s in settings]
            y=np.arange(len(vals))+offset
            ax.scatter(vals,y,color=color,marker=marker,s=65,label=label,zorder=4)
            for v,yy in zip(vals,y):ax.annotate(f'{v:.2f}',(v,yy),xytext=(7,0),textcoords='offset points',va='center',fontsize=10)
        control=100*policies[0]['comparisons'][lang]['controlWER']
        ax.axvline(control,color='#aeb1bc',ls=':',lw=1.5,zorder=1)
        ax.set_xlim(0,shared_limit)
        if selected_row is not None:ax.axhspan(selected_row-.45,selected_row+.45,color='#f0f2fc',zorder=0)
        ax.set_title(title,loc='left',fontsize=17,pad=20)
        ax.set_xlabel('WER, % · меньше лучше',labelpad=12)
        ax.grid(axis='x',color='#e9eaf0',zorder=0)
        ax.tick_params(axis='y',length=0)
    axes[0].set_yticks(range(len(settings)),[f'{c} с / {m} с / {o/1000:g} с' for c,m,o in settings])
    axes[0].invert_yaxis()
    axes[0].set_ylabel('Предел / паузы после / контекст',labelpad=17)
    handles,labels=axes[0].get_legend_handles_labels()
    fig.legend(handles,labels,loc='upper right',bbox_to_anchor=(.96,.94),frameon=False,ncol=2)
    save(fig,'file-quality-map',
        'Mac Mini M4, 16 ГиБ · одна Parakeet v3 Q8, Metal · три фиксированных составных файла FLEURS около 59 минут.\n'
        'Одна обработка каждого сочетания языка и нарезки. Два правила сборки текста проверены на тех же словах и временных метках без повторного распознавания.\n'
        'Подписи слева: предел длины фрагмента / минимальная длина перед поиском паузы / контекст с каждой стороны. Пунктир: исходные 30 с / 15 с / 2 с.\n'
        'Во всех панелях одна шкала WER. Выделен ряд выбранной нарезки; для него выбран вариант стыка с сохранением слов. Выбор сделан до отложенной проверки.',left=.17)

if a.before and a.after:
    before=json.loads(a.before.read_text());after=json.loads(a.after.read_text())
    assert before['completedRuns']==8 and after['completedRuns']==8
    fixture_ids=['ru-60s','en-60s','ru-360s','en-360s']
    labels=[];coverage=[];wer=[];colors=[]
    for fixture in fixture_ids:
        for summary,preserve,label,color in [(before,False,'исходный',gold),(after,False,'исправлен',blue),(after,True,'всё аудио',pale)]:
            g=next(r for r in summary['groups'] if r['fixture']==fixture and r['meetingPreserveQuietAudio']==preserve)
            labels.append(f"{fixture.replace('-60s',' · 1 мин').replace('-360s',' · 6 мин').upper()} · {label}")
            coverage.append(100*g['submittedFrames']['p50']/(g['audioSeconds']*16000))
            wer.append(100*g['wer']['p50']);colors.append(color)
    fig,axes=plt.subplots(1,2,figsize=(17,10),sharey=True)
    fig.suptitle('Сколько аудио дошло до модели',x=.02,ha='left',fontsize=25,weight='bold')
    for ax,vals,title,limit in zip(axes,[coverage,wer],['Передано модели, % аудио','Ошибки слов, WER %'],[112,100]):
        bars=ax.barh(range(len(vals)),vals,.65,color=colors,zorder=3)
        ax.bar_label(bars,labels=[f'{v:.1f}' for v in vals],padding=5,fontsize=10)
        ax.set_xlim(0,limit);ax.set_title(title,loc='left',fontsize=17,pad=20)
        ax.grid(axis='x',color='#e9eaf0',zorder=0);ax.tick_params(axis='y',length=0)
        for y in (2.5,5.5,8.5):ax.axhline(y,color='#e9eaf0',lw=1)
    axes[0].set_yticks(range(len(labels)),labels);axes[0].invert_yaxis()
    save(fig,'meeting-coverage',
        'Mac Mini M4, 16 ГиБ · Parakeet v3 Q8, Metal · четыре фиксированных входа FLEURS. По одному завершённому запуску каждого режима.\n'
        '«Исправлен»: учёт сохранённой секунды после начальной тишины. «Всё аудио»: существующий режим сохранения тихого звука для импортированных файлов.\n'
        'Полное покрытие не означает безошибочного текста. Режим сохранения всего аудио не включён для живого микрофона: для него нужны отдельные проверки шума и эха.\n'
        'Это локализация потерь на исходной громкости публичных записей. Подача ускорена с ожиданием очереди; это не измерение полноценной живой встречи.',left=.25,bottom=.19)

if a.tail:
    s=json.loads(a.tail.read_text());assert s['completedRuns']==40
    ids=['ru-360s','en-360s','ru-3540s','en-3540s']
    fig,axes=plt.subplots(1,2,figsize=(17,8),sharey=True)
    fig.suptitle('Чтение оставшегося аудио после Stop',x=.02,ha='left',fontsize=25,weight='bold')
    for tail,offset,color,label in [(False,-.18,blue,'Весь файл'),(True,.18,pale,'Только остаток')]:
        groups=[next(g for g in s['groups'] if g['fixture']==f and g['condition']=='normal' and g['tailRead']==tail) for f in ids]
        assert all(g['seconds']['n']==3 for g in groups)
        vals=[g['seconds']['p50']*1000 for g in groups]
        errors=np.array([[g['seconds']['p50']-g['seconds']['min'] for g in groups],[g['seconds']['max']-g['seconds']['p50'] for g in groups]])*1000
        bars=axes[0].barh(np.arange(4)+offset,vals,.31,color=color,label=label,xerr=errors,error_kw={'ecolor':'#42454f','capsize':3},zorder=3)
        axes[0].bar_label(bars,labels=[f'{v:.0f}' for v in vals],padding=6,fontsize=11)
        mem=[g['sampledPeakPhysicalFootprintBytes']/2**30 for g in groups]
        bars=axes[1].barh(np.arange(4)+offset,mem,.31,color=color,label=label,zorder=3)
        axes[1].bar_label(bars,labels=[f'{v:.2f}' for v in mem],padding=6,fontsize=11)
    for ax,title in zip(axes,['Ожидание после Stop, мс','Пик физической памяти процесса, ГиБ']):
        ax.set_title(title,loc='left',fontsize=17,pad=20);ax.grid(axis='x',color='#e9eaf0',zorder=0)
        ax.tick_params(axis='y',length=0);ax.set_xlim(0,ax.get_xlim()[1]*1.14)
    axes[0].set_yticks(range(4),['RU · 6 минут','EN · 6 минут','RU · 59 минут','EN · 59 минут']);axes[0].invert_yaxis()
    handles,labels=axes[0].get_legend_handles_labels();fig.legend(handles,labels,loc='upper right',bbox_to_anchor=(.96,.94),frameon=False,ncol=2)
    parity=all(r['exactText'] and r['sameFinalSamples'] and r['sameDecodeSizes'] for r in s['tailParity'])
    save(fig,'tail-read',
        'Mac Mini M4, 16 ГиБ · одна Parakeet v3 Q8, Metal · обычная нагрузка, по три повтора. Медианы и минимум–максимум, загрузка отдельно.\n'
        'Префикс распознан до Stop. Тестовый стенд хранит исходное аудио в памяти в обоих режимах; это не память живого захвата с микрофона.\n'
        f'Текст, финальные сэмплы и размеры вызовов совпали во всех парах: {"да" if parity else "нет"}. Всего 40 запусков; проверки с нагрузкой на CPU вынесены в таблицы.\n'
        'Память измеряется раз в секунду и может пропустить короткий пик. Условие ≥10% выигрыша обоих длинных входов не выполнено; приложение не переключено.')
