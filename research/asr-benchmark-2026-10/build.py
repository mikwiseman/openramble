#!/usr/bin/env python3
"""Re-present curated ASR results; no inference, private inputs or network."""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

import matplotlib

matplotlib.use('Agg')
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
STUDY = HERE.parent / 'asr-quality-2026-09'
MODELS = {
    'parakeet': ('Parakeet · OpenRamble', '#15766d'),
    'turbo': ('Whisper Turbo', '#5173b4'),
    'breeze': ('Breeze-ASR-25', '#b27b35'),
    'gigaam-e2e-ctc': ('GigaAM v3 CTC · RU', '#986193'),
}
DOMAINS = {
    'common_voice_19_mirror/en': ('Common Voice 19 · EN', 'human'),
    'common_voice_19_mirror/ru': ('Common Voice 19 · RU', 'human'),
    'golos_crowd_mirror/ru': ('Golos Crowd · RU', 'human'),
    'golos_farfield_mirror/ru': ('Golos Farfield · RU', 'human'),
    'fleurs/en': ('FLEURS · EN', 'human'),
    'fleurs/ru': ('FLEURS · RU', 'human'),
    'eleven_v4_short/ru': ('Технические фразы · RU', 'synthetic'),
    'eleven_v4_short/en': ('Технические фразы · EN', 'synthetic'),
    'eleven_v4_short/mixed': ('Технические фразы · RU + EN', 'synthetic'),
}


def build_data():
    sources, rows = {}, {}

    def read(name):
        raw = (STUDY / name).read_bytes()
        sources[name] = hashlib.sha256(raw).hexdigest()
        return json.loads(raw)

    def add(model, domain, record, pair, source):
        if model not in MODELS or domain not in DOMAINS:
            raise ValueError(f'Unexpected model/domain: {model}/{domain}')
        key = (model, domain)
        quality = record['app']
        errors = sum(quality[k] for k in ('substitutions', 'deletions', 'insertions'))
        assert quality['reference_units'] > 0
        assert math.isclose(errors / quality['reference_units'], quality['wer'], abs_tol=1e-12)
        assert 0 <= record['failures'] <= record['examples']
        result = {
            'model': model, 'domain': domain,
            'examples': record['examples'], 'groups': record['groups'],
            'failures': record['failures'], 'app': quality, 'raw': record['raw'],
            'paired_vs_parakeet': pair,
            'file_timing_screening_only': record.get('wall_seconds'),
            'source': source,
        }
        if key in rows:
            assert rows[key]['app'] == result['app'], f'Baseline changed: {key}'
            assert rows[key]['examples'] == result['examples']
            return
        rows[key] = result

    for name in ('main/comparison.json', 'giga-main/comparison.json',
                 'holdout/comparison.json', 'synthetic-holdout/comparison.json'):
        obj = read(name)
        for model, report in obj['reports'].items():
            assert report['identity']['host']['chip'] == 'Apple M4'
            for domain, record in report['sets'].items():
                add(model, domain, record, obj['paired'].get(f'{model}/{domain}/app'), name)

    for name in ('holdout-ru/comparison.json', 'giga-synthetic-holdout/comparison.json'):
        obj = read(name)
        for domain, records in obj['sets'].items():
            for model in ('parakeet', 'gigaam-e2e-ctc'):
                add(model, domain, records[model],
                    records['paired_app'] if model != 'parakeet' else None, name)

    domains = []
    for domain, (title, kind) in DOMAINS.items():
        values = [rows[(m, domain)] for m in MODELS if (m, domain) in rows]
        assert len({r['examples'] for r in values}) == 1
        assert len({r['app']['reference_units'] for r in values}) == 1
        domains.append({'id': domain, 'title': title, 'kind': kind,
                        'examples': values[0]['examples'], 'groups': values[0]['groups'],
                        'rows': values})
    assert sum(d['examples'] for d in domains if d['kind'] == 'human') == 3422
    assert sum(d['examples'] for d in domains if d['kind'] == 'synthetic') == 36
    latency = read('runtime/idle-latency.json')
    return {
        'schema': 1, 'compiled_on': '2026-10-07',
        'inference_dates': '2026-09-30 to 2026-10-01',
        'study_commit': '53dca43',
        'product_baseline_commit': 'ed1d0fe14bda180e7f6977b664f0d9d14e0455fc',
        'product_version': '0.31.2', 'runtime': 'transcribe.cpp 0.2.3',
        'host': {'chip': 'Apple M4', 'ram_gib': 16, 'macos': '26.4'},
        'models': {m: {'label': label, 'color': color} for m, (label, color) in MODELS.items()},
        'quality_scope': 'Model configurations in OpenRamble harness; not official competing apps',
        'normalization': 'NFC, lowercase, yo=ye, non-alphanumeric characters become spaces, whitespace collapsed; script and digits preserved',
        'failure_policy': 'empty hypothesis in WER; failure count retained',
        'public_market_leadership_established': False,
        'gui_stop_to_insertion_measured': False,
        'new_inference_in_this_refresh': False,
        'domains': domains, 'latency': latency,
        'source_sha256': sources,
    }


def plot(domains, filename, title, subtitle):
    nrows = (len(domains) + 1) // 2
    plt.rcParams.update({'font.family': 'sans-serif',
                         'font.sans-serif': ['DejaVu Sans', 'Arial', 'Helvetica', 'sans-serif'],
                         'font.size': 11,
                         'svg.fonttype': 'none', 'svg.hashsalt': 'openramble-20261007'})
    fig, axes = plt.subplots(nrows, 2, figsize=(14, 2.95 * nrows + 1.7), squeeze=False)
    fig.patch.set_facecolor('#fbfaf6')
    fig.suptitle(title, x=.04, y=.97, ha='left', fontsize=23, fontweight='bold', color='#202b2b')
    fig.text(.04, .925, subtitle, fontsize=11, color='#566361')
    for ax, domain in zip(axes.flat, domains):
        records = domain['rows']
        labels = [MODELS[r['model']][0] for r in records]
        wer = [r['app']['wer'] * 100 for r in records]
        ax.set_facecolor('#fbfaf6')
        ax.barh(range(len(records)), wer, color=[MODELS[r['model']][1] for r in records], height=.58)
        ax.set_yticks(range(len(records)), labels, fontsize=10)
        ax.invert_yaxis()
        for i, (value, record) in enumerate(zip(wer, records)):
            suffix = ' *' if record['failures'] else ''
            ax.text(value + .5, i, f'{value:.2f}%{suffix}', va='center', fontsize=11, fontweight='bold')
        ax.set_title(f"{domain['title']}  ·  n={domain['examples']}", loc='left', pad=12,
                     fontsize=12, fontweight='bold')
        ax.set_xlim(0, 44 if domain['kind'] == 'human' else 24)
        ax.set_xticks([0, 10, 20, 30, 40] if domain['kind'] == 'human' else [0, 5, 10, 15, 20])
        ax.tick_params(axis='both', length=0, labelcolor='#4d5d5a')
        ax.xaxis.grid(True, color='#dee3df', linewidth=.7)
        ax.set_axisbelow(True)
        for spine in ax.spines.values():
            spine.set_visible(False)
    for ax in list(axes.flat)[len(domains):]:
        ax.set_visible(False)
    fig.text(.04, .069, 'Модели в OpenRamble harness; Turbo/Breeze без промптов Klava. Это не сравнение официальных приложений.',
             fontsize=10, color='#566361')
    fig.text(.04, .045, '* Ошибка выполнения сохранена в WER как пустой ответ. Пунктуация в WER не учитывается.',
             fontsize=10, color='#566361')
    fig.text(.04, .021, 'OpenRamble benchmark · 30.09–01.10.2026 · transcribe.cpp 0.2.3 · Q8 · Mac mini M4, 16 GiB',
             fontsize=10, color='#566361')
    fig.subplots_adjust(left=.20, right=.96, top=.85, bottom=.15, wspace=.78, hspace=.62)
    svg_path = HERE / f'{filename}.svg'
    fig.savefig(svg_path, metadata={'Date': '2026-10-07', 'Creator': 'OpenRamble benchmark'})
    svg_path.write_text('\n'.join(line.rstrip() for line in svg_path.read_text().splitlines()) + '\n')
    if filename == 'quality':
        fig.savefig(HERE / f'{filename}.png', dpi=150)
    plt.close(fig)


HTML = r'''<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenRamble · скорость и качество</title>
<style>
:root{color-scheme:light;--ink:#202b2b;--muted:#586663;--line:#d5dcd6;--green:#15766d;--paper:#fbfaf6}
*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:17px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{max-width:1160px;margin:auto;padding:42px 36px 80px}header{display:flex;justify-content:space-between;gap:16px;font-size:13px;letter-spacing:.08em;text-transform:uppercase;border-bottom:1px solid var(--line);padding-bottom:20px}
h1{font-size:clamp(34px,5.4vw,68px);line-height:1.05;letter-spacing:-.045em;max-width:820px;font-weight:720;margin:46px 0 22px}
h2{font-size:30px;line-height:1.2;letter-spacing:-.025em;margin:0 0 15px}h3{font-size:20px;margin:0 0 10px}p{max-width:880px;margin:12px 0}.lead{font-size:23px;line-height:1.4;max-width:880px}.muted,small{color:var(--muted)}
a{color:var(--green);text-underline-offset:3px}.links{display:flex;flex-wrap:wrap;gap:10px 24px;font-size:15px;margin-top:24px}
.facts{display:flex;flex-wrap:wrap;gap:18px 44px;border-top:1px solid var(--line);border-bottom:1px solid var(--line);padding:20px 0;margin:36px 0 46px}.facts strong{font-size:30px;display:block;letter-spacing:-.03em}.facts span{font-size:14px;color:var(--muted)}
section{margin:46px 0;padding-top:12px}.control{display:flex;align-items:center;flex-wrap:wrap;gap:10px;margin:22px 0}button,select{font:inherit;font-size:15px;background:transparent;border:1px solid #899b94;border-radius:6px;padding:10px 14px;color:var(--ink);cursor:pointer}button[aria-pressed="true"]{background:var(--green);color:white;border-color:var(--green)}button:focus-visible,select:focus-visible,a:focus-visible{outline:3px solid #b77935;outline-offset:3px}
.figure{width:100%;overflow:auto}.figure svg{width:100%;min-width:1008px;height:auto;display:block}.note{font-size:14px;color:var(--muted);max-width:950px}.note strong{color:var(--ink)}.scroll-hint{display:none}
.scroll{overflow-x:auto;margin:18px 0}table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums;font-size:15px}th{text-align:left;font-size:12px;letter-spacing:.04em;color:var(--muted);font-weight:600}th,td{padding:13px 10px;border-bottom:1px solid var(--line);vertical-align:top}th:first-child,td:first-child{padding-left:0}td:not(:first-child){white-space:nowrap}.model{display:flex;gap:8px;align-items:center}.dot{height:10px;width:10px;border-radius:50%;flex-shrink:0}.strong{font-weight:700}
.verdict{border-left:4px solid var(--green);padding:10px 0 10px 23px;margin:28px 0;font-size:19px;max-width:900px}
.steps{padding-left:25px;max-width:950px}.steps li{padding:8px 0 16px 6px}.steps b{display:block;font-size:19px}.steps span{font-size:16px;color:var(--muted)}
.status{display:grid;grid-template-columns:1fr 1fr;gap:28px;border-top:1px solid var(--line);padding-top:24px}.status ul{padding-left:20px;font-size:16px}footer{border-top:1px solid var(--line);padding-top:22px;font-size:13px;color:var(--muted)}
@media(max-width:650px){main{padding:24px 20px 55px}header{font-size:11px}.lead{font-size:20px}.facts{gap:18px 25px}.facts strong{font-size:25px}h2{font-size:27px}.status{grid-template-columns:1fr}.figure{border:1px solid var(--line)}td,th{padding:11px 8px}select{max-width:100%}.scroll-hint{display:block}}
@media print{main{max-width:none;padding:15px}.control{display:none}.figure svg{min-width:0}.scroll{overflow:visible}section{break-inside:avoid}a{color:inherit}}
</style></head><body><main>
<header><b>OpenRamble / Research</b><span>Обзор · 07 октября 2026</span></header>
<h1>Скорость и качество OpenRamble</h1>
<p class="lead">Parakeet — сильная основа. Лидерство во всём классе ещё не доказано: результаты зависят от языка, записи и настроек.</p>
<p class="muted">Собственные измерения 30 сентября–1 октября. Сегодня мы проверили текущий стек и новые источники и собрали результаты в одну страницу. Новых прогонов моделей здесь нет.</p>
<nav class="links"><a href="REPORT.ru.md">Полное исследование</a><a href="PROTOCOL.md">Порядок работы</a><a href="benchmark.json">Данные и хеши</a><a href="quality.png">График PNG</a><a href="sources.json">Внешние источники</a></nav>
<div class="facts"><div><strong>3 422</strong><span>реальные записи</span></div><div><strong>6</strong><span>языковых / предметных срезов</span></div><div><strong>4</strong><span>модели в текущем сравнении</span></div><div><strong>M4 · 16 GiB</strong><span>одно устройство исследования</span></div></div>
<section><h2>Качество зависит от сценария</h2>
<p>WER — число замен, пропусков и лишних слов на 100 слов эталона. Ниже — лучше. Пунктуация оценивается отдельно и пока не измерена.</p>
<div class="control" aria-label="Тип аудио"><button type="button" id="human" aria-pressed="true">Реальная речь · 3 422</button><button type="button" id="synthetic" aria-pressed="false">Синтетика · 36</button></div>
<p id="kind-note" class="note"></p>
<div class="control"><label for="domain">Подробно:</label><select id="domain"></select></div>
<div class="scroll"><table><thead><tr><th>Модель</th><th>WER</th><th>Сбоев / записей</th><th>Δ к Parakeet, п.п.</th><th>95% интервал Δ</th></tr></thead><tbody id="quality-rows"></tbody></table></div>
<p class="note">Δ &lt; 0: у кандидата меньше ошибок. Интервал через ноль означает, что явного преимущества не установлено. Интервалы парные, с группировкой источников; для Golos и FLEURS они не доказывают независимость голосов. <a id="source-link" href="#">Исходные числа</a>.</p>
<p class="note scroll-hint">График и широкие таблицы можно прокручивать вбок. Выберите нужный корпус в списке выше.</p>
<div id="figure" class="figure" role="img" aria-label="WER четырёх моделей по корпусам"></div>
<p class="note">Все модели Q8, внутри OpenRamble harness. Turbo и Breeze без промптов из гайда Klava; результаты официальных приложений здесь не измерены. Числа и латиница сохраняются при подсчёте ошибок. На Golos написание чисел объясняет часть разрыва.</p>
</section>
<section><h2>Скорость: отдельно от рейтинга качества</h2>
<p>Прогретый движок, шесть русских фраз, по 20 повторов в двух процессах. Время от готового PCM до результата; запись, загрузка модели и вставка исключены.</p>
<div class="scroll"><table><thead><tr><th>Модель / язык</th><th>p50</th><th>p95</th><th>Пиковый RSS</th></tr></thead><tbody id="latency-rows"></tbody></table></div>
<p class="note">Диапазон — два процессных блока, не доверительный интервал. ABBA-порядок; между первым и вторым процессами исправлялся сборщик, первый результат сохранён. Это шесть повторяемых входов, не 240 независимых голосов. <a href="../asr-quality-2026-09/runtime/idle-latency.json">Источник и ограничения</a>.</p>
<div class="verdict">GigaAM быстрее на этом русском наборе. Его качество по доменам неоднородно, а v3 не заменяет английский и смешанную диктовку.</div>
<p class="note">Повторного сопоставимого теста Turbo/Breeze и реального Stop→вставка пока нет. Поэтому общая диаграмма «качество–задержка» не построена из несовместимых выборок.</p>
</section>
<section><h2>Что значит «работаем в несколько потоков»</h2>
<p>OpenRamble распознаёт законченные фрагменты во время речи и готовит следующий фрагмент файла параллельно текущему вычислению. В продукте один экземпляр модели, batch size 1 и один CPU-поток декодера. Metal использует собственный параллелизм.</p>
<p class="note">Эксперимент с двумя моделями давал выигрыш на длинном файле ценой памяти. Его убрали. Многоэлементный batch изменил слово и не прошёл проверку качества. <a href="../local-transcription-2026-09/README.md">Измерения и решение</a>.</p>
</section>
<section><h2>От простого к сложному</h2><ol class="steps">
<li><b>Использовать существующие корпуса и инструмент</b><span>3 422 записи людей, готовый runner, 72 короткие записи Eleven v4 и диагностика длинной речи уже есть. Здесь показаны существующие измерения; из синтетики — только 36 контрольных записей.</span></li>
<li><b>Проверить одно небольшое улучшение</b><span>Те же веса Parakeet, transcribe.cpp 0.2.3 → <a href="https://github.com/handy-computer/transcribe.cpp/releases/tag/v0.3.1">0.3.1</a>. В upstream изменена работа с памятью; выигрыш у нас пока не измерен. Затем — настроенные Turbo/Breeze на тех же входах. Другие модели идут после этого.</span></li>
<li><b>Отдельно продумать свой eval</b><span>Сначала проверить эталон по звуку уже созданной синтетики. Затем дополнить пробелы настоящими RU/EN/mixed-диктовками, терминами, числами, отрицаниями и пунктуацией. Новый большой корпус сейчас не нужен. <a href="PROTOCOL.md">Порядок и правила сравнения</a>.</span></li>
</ol><p class="note">В длинном синтетическом mixed-тесте у текущего Parakeet был пропуск 37 слов. Окно 20 с снизило WER, но ухудшило отрицания; его отклонили. Средний WER не заменяет сохранение смысла. <a href="../asr-quality-2026-09/RESULTS.md">Полный журнал</a>.</p></section>
<section><h2>Как читать сравнение с PDF</h2><p>В исследовании Егора Соколова — два голоса, IT-речь, RTX 5070 Ti и составная оценка Q, включающая латиницу и пунктуацию. Наши WER относятся к другим записям и настройкам. Это полезный повод проверить настроенные Whisper-модели на общем корпусе.</p><p><a href="https://egorsokolov.ru/ai/whisper-asr-benchmark-russian-it/">Оригинал исследования</a> · <a href="REPORT.ru.md">Обзор моделей, фреймворков и методик</a></p></section>
<div class="status"><div><h3>Есть доказательства</h3><ul><li>Качество четырёх моделей по доменам.</li><li>Повторная RU-скорость Parakeet и GigaAM.</li><li>Известные сбои, отрицательные эксперименты и границы измерений.</li></ul></div><div><h3>Остаётся измерить</h3><ul><li>Настроенные конкуренты, пунктуация и живая mixed-речь.</li><li>Stop→вставка в реальном приложении.</li><li>Другие Mac, Windows/CUDA, новые streaming-модели.</li></ul></div></div>
<footer>OpenRamble 0.31.2 · transcribe.cpp 0.2.3 · Parakeet Q8_0. Это исследовательский benchmark, не заявление о превосходстве над всеми приложениями. Новые модели и изменения продукта не выпускались.</footer>
</main><script>
const DATA=__DATA__;
const FIGURES=__FIGURES__;
let kind='human';
const byId=id=>document.getElementById(id);
function fixed(n){return n.toFixed(2).replace('.',',')}
function signed(n){return (n>0?'+':'')+fixed(n)}
function detail(){const d=DATA.domains.find(x=>x.id===byId('domain').value);byId('quality-rows').replaceChildren();for(const r of d.rows){const p=r.paired_vs_parakeet;const tr=document.createElement('tr');const td=document.createElement('td');const line=document.createElement('span');line.className='model';const dot=document.createElement('span');dot.className='dot';dot.style.background=DATA.models[r.model].color;line.append(dot,document.createTextNode(DATA.models[r.model].label));td.append(line);tr.append(td);for(const value of [fixed(r.app.wer*100)+'%',r.failures+' / '+r.examples,p?signed(p.wer_delta*100):'База',p?p.wer_delta_ci95.map(x=>signed(x*100)).join(' … '):'—']){const cell=document.createElement('td');cell.textContent=value;tr.append(cell)}byId('quality-rows').append(tr)}byId('source-link').href='../asr-quality-2026-09/'+d.rows[0].source}
function render(){for(const k of ['human','synthetic'])byId(k).setAttribute('aria-pressed',String(kind===k));byId('kind-note').textContent=kind==='human'?'Публичные записи людей. Common Voice и Golos используются через закреплённые зеркала. Полный корпус, включая ошибки выполнения.':'AI-аудио Eleven v4. 36 записей = 12 текстов × 3 голоса; смешанная речь — только 2 текста. Эталон — заданный текст, не независимая ручная расшифровка звука.';byId('figure').innerHTML=FIGURES[kind];byId('domain').replaceChildren();for(const d of DATA.domains.filter(d=>d.kind===kind)){const o=document.createElement('option');o.value=d.id;o.textContent=d.title+' · n='+d.examples;byId('domain').append(o)}detail()}
for(const k of ['human','synthetic'])byId(k).addEventListener('click',()=>{kind=k;render()});byId('domain').addEventListener('change',detail);
for(const model of ['parakeet','gigaam-e2e-ctc']){const rs=Object.values(DATA.latency.reports).filter(r=>r.model_id===model);const range=vals=>{const lo=Math.min(...vals),hi=Math.max(...vals);return lo.toFixed(1).replace('.',',')+'–'+hi.toFixed(1).replace('.',',')};const tr=document.createElement('tr');for(const t of [DATA.models[model].label.replace(' · RU','')+' / RU',range(rs.map(r=>r.sets.ru.p50_seconds*1000))+' мс',range(rs.map(r=>r.sets.ru.p95_seconds*1000))+' мс',range(rs.map(r=>r.process_peak_memory_bytes/1048576))+' MiB']){const td=document.createElement('td');td.textContent=t;tr.append(td)}byId('latency-rows').append(tr)}render();
</script></body></html>'''


def main():
    data = build_data()
    (HERE / 'benchmark.json').write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    plot([d for d in data['domains'] if d['kind'] == 'human'], 'quality',
         'Ошибка распознавания слов · реальные записи', 'WER, % · ниже лучше · одинаковая шкала во всех шести срезах')
    plot([d for d in data['domains'] if d['kind'] == 'synthetic'], 'synthetic',
         'Синтетические технические фразы', 'Диагностический holdout · не заменяет оценку на человеческой речи')
    figures = {}
    for kind, name in (('human', 'quality'), ('synthetic', 'synthetic')):
        svg = (HERE / f'{name}.svg').read_text()
        figures[kind] = svg[svg.index('<svg'):]
    html = HTML.replace('__DATA__', json.dumps(data, ensure_ascii=False).replace('<', '\\u003c'))
    html = html.replace('__FIGURES__', json.dumps(figures, ensure_ascii=False).replace('<', '\\u003c'))
    (HERE / 'index.html').write_text(html)
    print(f'Validated {sum(len(d["rows"]) for d in data["domains"])} model/domain rows; 3422 human + 36 synthetic inputs.')


if __name__ == '__main__':
    main()
