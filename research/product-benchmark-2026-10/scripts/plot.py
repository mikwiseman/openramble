"""Render the archived 2026-10-09 experiment. Version captions are pinned."""
from pathlib import Path
import html,json,math,re
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
ROOT=Path(__file__).resolve().parents[1]
D=json.loads((ROOT/'data/products-benchmark.json').read_text())
assert D.get('date')=='2026-10-09' or D.get('measurement_dates')==['2026-10-09'], 'Update the figure captions for a new experiment'
Q=D['quality'];S=D['speed'];L=D['long']
assert all(Q[e][l]['n']==100 for e in ['openramble','handy','whisper','superwhisper_turbo'] for l in ['ru','en'])
assert all(S[c][e]['n']==36 for c in ['quiet','load'] for e in ['openramble','handy','whisper'])
INK='#202923';MUTED='#637067';PAPER='#f6f5f0';GREEN='#197458';RED='#ad513f'
NAMES={'openramble':'OpenRamble','handy':'Handy','whisper':'whisper.cpp · Turbo','superwhisper_turbo':'Superwhisper · Turbo'}
COLORS={'openramble':GREEN,'handy':'#90988f','whisper':'#627b9b','superwhisper_turbo':'#956978'}
plt.rcParams.update({'font.family':'DejaVu Sans','font.size':12,'text.color':INK,'axes.labelcolor':MUTED,'xtick.color':MUTED,'ytick.color':INK,'axes.facecolor':PAPER,'figure.facecolor':PAPER,'savefig.facecolor':PAPER,'svg.fonttype':'none'})
def fmt(x,d=2):return f'{x:.{d}f}'.replace('.',',')
def save(fig,name):
 for ext in ['png','svg']:
  output=ROOT/f'figures/{name}.{ext}'
  fig.savefig(output,dpi=160)
  if ext=='svg':output.write_text('\n'.join(line.rstrip() for line in output.read_text().splitlines())+'\n')
 plt.close(fig)
def polish(ax):
 for sp in ax.spines.values():sp.set_visible(False)
 ax.tick_params(length=0,pad=9);ax.grid(axis='x',color='#dce1da',lw=.8,zorder=0)

fig,axs=plt.subplots(1,2,figsize=(13,7.4));fig.subplots_adjust(left=.20,right=.94,top=.69,bottom=.28,wspace=.65)
fig.text(.055,.935,'OPENRAMBLE / КАЧЕСТВО',color=GREEN,weight='bold',fontsize=11)
fig.text(.055,.853,'Одинаковые записи. Проверяемые ошибки.',fontsize=25,weight='bold')
for ax,lang,title in zip(axs,['ru','en'],['Русский · 100 записей','Английский · 100 записей']):
 for i,e in enumerate(NAMES):
  v=Q[e][lang]['wer']*100;ax.barh(i,v,height=.48,color=COLORS[e],zorder=3)
  ax.text(v+.10,i,fmt(v)+'%',va='center',fontsize=12,weight='bold' if e=='openramble' else 'normal')
 ax.set_yticks(range(4),list(NAMES.values()));ax.invert_yaxis();ax.set_xlim(0,max(Q[e][lang]['wer']*100 for e in NAMES)*1.33);ax.set_title(title,loc='left',pad=20,fontsize=14,weight='bold');polish(ax)
fig.text(.055,.16,'OpenRamble и Handy: все 200 текстов совпали после нормализации.',fontsize=13,weight='bold')
fig.text(.055,.095,'WER, меньше — лучше. FLEURS test, фиксированная выборка. Регистр и пунктуация исключены.\nOpenRamble / Handy: один Parakeet v3 Q8. Whisper: Large v3 Turbo F16. Без словаря и AI-переписывания.',fontsize=10,color=MUTED,linespacing=1.7)
fig.text(.055,.04,'OpenRamble 0.32.0 · Handy 0.9.8 · whisper.cpp 1.9.5 · Superwhisper 2.19.2 · 09.10.2026.',fontsize=9,color=MUTED)
save(fig,'products-quality')

fig,axs=plt.subplots(1,2,figsize=(13,7.4));fig.subplots_adjust(left=.17,right=.95,top=.67,bottom=.28,wspace=.48)
fig.text(.055,.935,'OPENRAMBLE / СКОРОСТЬ',color=GREEN,weight='bold',fontsize=11)
fig.text(.055,.853,'Сколько ждать готовый текст.',fontsize=28,weight='bold')
mx=max(S[c][e]['p95_seconds'] for c in S for e in S[c])*1.18
for ax,cond,title in zip(axs,['quiet','load'],['Без искусственной нагрузки','14 занятых потоков CPU']):
 for i,e in enumerate(['openramble','handy','whisper']):
  r=S[cond][e];v=r['p50_seconds'];ax.barh(i,v,height=.45,color=COLORS[e],zorder=3)
  ax.plot([v,r['p95_seconds']],[i,i],color=COLORS[e],lw=2);ax.plot(r['p95_seconds'],i,'|',color=COLORS[e],ms=14)
  ax.text(v+.06,i-.28,fmt(v)+' с',va='center',fontsize=13,weight='bold' if e=='openramble' else 'normal')
 ax.set_yticks(range(3),['OpenRamble','Handy','Whisper Turbo']);ax.invert_yaxis();ax.set_xlim(0,mx);ax.set_title(title,loc='left',pad=20,fontsize=13,weight='bold');polish(ax)
fig.text(.055,.16,'Полный запуск CLI: файл → загрузка модели → распознавание → результат.',fontsize=13,weight='bold')
fig.text(.055,.093,'Медиана; тонкая линия — p95. 6 файлов RU/EN × 6 порядков запуска = 36 замеров на столбец.\nM4 Pro · 24 ГБ · macOS 27.0.1 · Metal GPU · 09.10.2026. Это не задержка отпускания клавиши.',fontsize=10,color=MUTED,linespacing=1.7)
fig.text(.055,.04,'OpenRamble 0.32.0 / Handy 0.9.8: Parakeet v3 Q8. Whisper: whisper.cpp 1.9.5, Large v3 Turbo F16.',fontsize=9,color=MUTED)
save(fig,'products-speed')

hour=next(r for r in L['quiet']['openramble']['fixtures'] if r['fixture']=='mixed-3540s')
hour_load=next(r for r in L['load']['openramble']['fixtures'] if r['fixture']=='mixed-3540s')
mono=D['long_mono']
assert all(mono[c][e]['n']==4 for c in ['quiet','load'] for e in ['openramble','handy'])
fig,ax=plt.subplots(figsize=(13,7.4));ax.axis('off')
fig.text(.055,.935,'OPENRAMBLE / ДИАГНОСТИКА ДЛИННЫХ ФАЙЛОВ',color=RED,weight='bold',fontsize=11)
fig.text(.055,.84,'Час аудио: язык меняет результат.',fontsize=28,weight='bold')
fig.text(.055,.745,'Составные файлы по 59 минут · обычная нагрузка · OpenRamble 0.32.0',fontsize=13,color=MUTED)
for x,t in [(.055,'Речь'),(.43,'Время CLI'),(.65,'WER ↓'),(.82,'Удаления / слова')]:fig.text(x,.65,t,fontsize=12,color=MUTED)
long_examples=[('Русский',next(x for x in mono['quiet']['openramble']['fixtures'] if x['language']=='ru')),('English',next(x for x in mono['quiet']['openramble']['fixtures'] if x['language']=='en')),('RU + EN по очереди',hour)]
for i,(label,r) in enumerate(long_examples):
 y=.55-i*.10;q=r['quality'];fig.text(.055,y,label,fontsize=16);fig.text(.43,y,fmt(r['p50_seconds'],1)+' с',fontsize=19,weight='bold');fig.text(.65,y,fmt(q['wer']*100,1)+'%',fontsize=19,weight='bold',color=RED);fig.text(.82,y,fmt(100*q['deletions']/q['reference_words'],1)+'%',fontsize=19,color=RED)
fig.text(.055,.19,'Handy 0.9.8 + та же Parakeet v3 Q8: нехватка памяти на всех трёх часовых файлах.',fontsize=12)
fig.text(.055,.105,'Это воспроизводимый стресс-тест, а не естественная встреча. Каждый файл: 2 запуска на условие.\nСкорость без сохранности текста не считается победой. Подробности и все неудачи — в отчёте.',fontsize=10,color=MUTED,linespacing=1.7)
fig.text(.055,.04,'M4 Pro · 24 ГБ · Metal · 09.10.2026. Одноязычные файлы добавлены после смешанного теста.',fontsize=9,color=MUTED)
save(fig,'products-long')
