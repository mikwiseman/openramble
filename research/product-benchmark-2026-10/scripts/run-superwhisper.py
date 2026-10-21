"""Official CLI dispatch into the installed app; no UI automation."""
from pathlib import Path
import os
import argparse,datetime,hashlib,json,subprocess,time
ROOT=Path(os.environ.get('BENCH_ROOT',str(Path.home()/'Library/Caches/OpenRambleHandyBenchmark'))).expanduser()
CLI=ROOT/'superwhisper-cli-0.2.0/superwhisper'
RECORDINGS=Path(os.environ.get('SUPERWHISPER_RECORDINGS',str(Path.home()/'superwhisper/recordings'))).expanduser()
OUT=ROOT/'superwhisper-quality.jsonl'
manifest=json.loads((ROOT/'manifest.json').read_text())
args=argparse.ArgumentParser();args.add_argument('--limit',type=int,default=200);a=args.parse_args()
rows=[json.loads(x) for x in OUT.read_text().splitlines()] if OUT.exists() else []
done={r['fixture'] for r in rows}
en=[f for f in manifest['fixtures'] if f['language']=='en'];ru=[f for f in manifest['fixtures'] if f['language']=='ru']
queue=[x for pair in zip(en,ru) for x in pair]
for f in queue[:a.limit]:
 if f['id'] in done:continue
 prior=set(RECORDINGS.iterdir());start=time.perf_counter();stamp=datetime.datetime.now(datetime.timezone.utc).isoformat()
 dispatched=subprocess.run([str(CLI),'transcribe',f['path']],capture_output=True,text=True,check=True)
 end=time.monotonic()+120
 while True:
  fresh=set(RECORDINGS.iterdir())-prior
  if len(fresh)>1:raise RuntimeError('Concurrent app recording; refusing ambiguous attribution')
  if fresh:
   folder=next(iter(fresh));path=folder/'meta.json'
   try:meta=json.loads(path.read_text())
   except (FileNotFoundError,json.JSONDecodeError):meta={}
   if meta.get('result') and meta.get('processingTime',0)>0:break
  if time.monotonic()>end:raise TimeoutError(f['id'])
  time.sleep(.05)
 assert meta['modelKey']=='large-v3-turbo' and meta['appVersion']=='2.19.2',meta.get('modelKey')
 assert not meta.get('languageModelKey') and not meta.get('translationEnabled')
 assert abs(meta['duration']/1000-f['duration_seconds'])<.01
 row={'fixture':f['id'],'source_path':f['path'],'recording_folder':folder.name,
      'collected_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'cli_started_at':stamp,
      'cli_dispatch_to_observed_result_seconds':time.perf_counter()-start,
      'polling_interval_seconds':.05,'command':[str(CLI),'transcribe',f['path']],
      'cli_stdout':dispatched.stdout,'metadata':meta}
 with OUT.open('a') as out:out.write(json.dumps(row,ensure_ascii=False)+'\n')
 print(f['id'],meta['processingTime'],'ms',flush=True)
