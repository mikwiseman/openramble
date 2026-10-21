"""Score retained public-corpus outputs with one normalization for every engine."""
from pathlib import Path
import os
import collections,hashlib,json,math,re,statistics,unicodedata
import jiwer
ROOT=Path(os.environ.get('BENCH_ROOT', str(Path.home() / 'Library/Caches/OpenRambleHandyBenchmark'))).expanduser()
OUT=Path(__file__).resolve().parents[1]/'data/products-benchmark.json'
m=json.loads((ROOT/'manifest.json').read_text());fixtures={f['id']:f for f in m['fixtures']+m['long_fixtures']}
if (ROOT/'extended-long.json').exists():fixtures.update({f['id']:f for f in json.loads((ROOT/'extended-long.json').read_text())['fixtures']})
obs=[json.loads(x) for x in (ROOT/'observations.jsonl').read_text().splitlines()]

def norm(s):return ' '.join(re.findall(r'[^\W_]+',unicodedata.normalize('NFC',s).lower().replace('ё','е')))
def pct(values,p):
 x=sorted(values);at=(len(x)-1)*p;lo=int(at);hi=math.ceil(at)
 return x[lo]+(x[hi]-x[lo])*(at-lo)
def errors(rows):
 pairs=[(norm(fixtures[r['fixture']]['reference']),norm(r['text'])) for r in rows]
 score=jiwer.process_words([p[0] for p in pairs],[p[1] for p in pairs])
 return {'n':len(rows),'wer':score.wer,'reference_words':score.hits+score.substitutions+score.deletions,'substitutions':score.substitutions,'deletions':score.deletions,'insertions':score.insertions,'failures':sum(bool(r.get('exit_code',0)) or not r.get('valid_json',True) for r in rows)}
quality={}
for engine in ['openramble','handy','whisper']:
 q=[r for r in obs if r['phase']=='quality' and r['engine']==engine]
 if q:quality[engine]={lang:errors([r for r in q if fixtures[r['fixture']]['language']==lang]) for lang in ['ru','en']}
sw=ROOT/'superwhisper-quality.jsonl'
if sw.exists():
 rows=[json.loads(x) for x in sw.read_text().splitlines()]
 converted=[{'fixture':r['fixture'],'text':r['metadata'].get('rawResult','')} for r in rows]
 quality['superwhisper_turbo']={lang:errors([r for r in converted if fixtures[r['fixture']]['language']==lang]) for lang in ['ru','en']}
speed={};long={};long_mono={}
for phase,target in [('speed',speed),('long',long),('long-mono',long_mono)]:
 for condition in ['quiet','load']:
  target[condition]={}
  for engine in ['openramble','handy','whisper']:
   rows=[r for r in obs if r['phase']==phase+'-'+condition and r['engine']==engine]
   if not rows:continue
   groups=collections.defaultdict(list)
   for r in rows:groups[r['fixture']].append(r)
   entries=[]
   for key,rs in groups.items():
    ok=[r for r in rs if r['exit_code']==0 and r['valid_json']]
    times=[r['wall_seconds'] for r in ok]
    entries.append({'fixture':key,'audio_seconds':fixtures[key]['duration_seconds'],'language':fixtures[key]['language'],'n':len(rs),'success':len(ok),'p50_seconds':statistics.median(times) if times else None,'p95_seconds':pct(times,.95) if times else None,'min_seconds':min(times) if times else None,'max_seconds':max(times) if times else None,'max_rss_bytes':max((r['max_rss_bytes'] or 0) for r in rs),'quality':errors(rs)})
   ok=[r for r in rows if r['exit_code']==0 and r['valid_json']];times=[r['wall_seconds'] for r in ok]
   target[condition][engine]={'n':len(rows),'success':len(ok),'p50_seconds':statistics.median(times) if times else None,'p95_seconds':pct(times,.95) if times else None,'fixtures':sorted(entries,key=lambda x:(x['language'],x['audio_seconds']))}
qO={r['fixture']:norm(r['text']) for r in obs if r['phase']=='quality' and r['engine']=='openramble'}
qH={r['fixture']:norm(r['text']) for r in obs if r['phase']=='quality' and r['engine']=='handy'}
result={'measurement_dates':sorted({r['before']['at'][:10] for r in obs}),'quality':quality,'speed':speed,'long':long,'matched_normalized_outputs_openramble_handy':sum(qO[k]==qH[k] for k in qO.keys()&qH.keys()),'manifest_sha256':hashlib.sha256((ROOT/'manifest.json').read_bytes()).hexdigest(),'normalization':'Unicode NFC, lowercase, ё→е, alphanumeric tokens, punctuation omitted; numerals not expanded','speed_scope':'Full CLI process including launch, model load, decode, recognition, output and shutdown. OS file cache warm; models reloaded each observation. Not physical key-release latency.','speed_sampling':'6 representative inputs (shortest/median/longest per language), all six product orders, two CPU conditions; 36 observations per product and condition','long_scope':'Composite of public utterances alternating RU/EN, with 0.5 s gaps; not a natural meeting. 2 observations per file and condition.'}
result['long_mono']=long_mono
OUT.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'quality':quality,'matched_transcripts':result['matched_normalized_outputs_openramble_handy'],'speed':{c:{e:{k:v[k] for k in ['n','p50_seconds','p95_seconds']} for e,v in t.items()} for c,t in speed.items()}},ensure_ascii=False,indent=2))
