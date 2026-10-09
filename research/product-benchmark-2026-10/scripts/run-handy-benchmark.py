"""Compare released, unpatched CLIs. No microphone, GUI, or insertion timing."""
from pathlib import Path
import os
import plistlib
import argparse, datetime, hashlib, itertools, json, os, platform, random, re, signal, subprocess, sys, time, threading
from contextlib import contextmanager

ROOT=Path(os.environ.get('BENCH_ROOT', str(Path.home() / 'Library/Caches/OpenRambleHandyBenchmark'))).expanduser()
OPEN=Path(os.environ['OPENRAMBLE_CLI']).expanduser()
HANDY=Path(os.environ.get('HANDY_CLI',str(ROOT/'Handy.app/Contents/MacOS/handy'))).expanduser()
MODEL=Path(os.environ['PARAKEET_MODEL']).expanduser()
WHISPER=Path(os.environ.get('WHISPER_CLI',str(ROOT/'whisper.cpp/build/bin/whisper-cli'))).expanduser()
WHISPER_MODEL=Path(os.environ['WHISPER_MODEL']).expanduser()
MODEL_ID='handy-computer/parakeet-tdt-0.6b-v3-gguf/parakeet-tdt-0.6b-v3-Q8_0.gguf'
SEED=20261009
PROFILE='(version 1) (allow default) (deny network*)'

def bundle_version(executable):
    with (executable.parents[1]/'Info.plist').open('rb') as f: info=plistlib.load(f)
    return f"{info['CFBundleShortVersionString']} ({info['CFBundleVersion']})"

def digest(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1<<20),b''):h.update(b)
    return h.hexdigest()

def snapshot():
    return {'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'thermal':subprocess.check_output(['pmset','-g','therm'],text=True).strip(),
            'load_average':os.getloadavg()}

@contextmanager
def pressure(count):
    workers=[]
    try:
        for _ in range(count): workers.append(subprocess.Popen([sys.executable,'-c','while True: pass'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL))
        if workers: time.sleep(3)
        yield workers
    finally:
        for p in workers:p.terminate()
        for p in workers:
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait()

def run_one(engine,fixture,phase,index,order,timeout=600):
    label=f"{phase}-{fixture['id']}-{index}-{engine}"
    raw=ROOT/'raw';raw.mkdir(exist_ok=True)
    whisper_output=raw/label
    command=([str(OPEN),fixture['path'],'--model-dir',str(MODEL.parent),'--format','json'] if engine=='openramble'
             else [str(HANDY),'--transcribe-file',fixture['path'],'--model',MODEL_ID,'--repeat','1','--json'] if engine=='handy'
             else [str(WHISPER),'-m',str(WHISPER_MODEL),'-f',fixture['path'],'-l','auto','-oj','-of',str(whisper_output)])
    command=['/usr/bin/time','-l','/usr/bin/sandbox-exec','-p',PROFILE]+command
    label=f"{phase}-{fixture['id']}-{index}-{engine}"
    raw=ROOT/'raw';raw.mkdir(exist_ok=True)
    outpath=raw/(label+'.stdout');errpath=raw/(label+'.stderr')
    before=snapshot();started=time.perf_counter_ns();timed_out=False
    with outpath.open('wb') as out,errpath.open('wb') as err:
        process=subprocess.Popen(command,stdout=out,stderr=err,start_new_session=True)
        def deadline():
            nonlocal timed_out
            if process.poll() is None:
                timed_out=True
                try:os.killpg(process.pid,signal.SIGKILL)
                except ProcessLookupError:pass
        timer=threading.Timer(timeout,deadline);timer.daemon=True;timer.start()
        try:code=process.wait()
        finally:timer.cancel()
    elapsed=(time.perf_counter_ns()-started)/1e9
    stdout=outpath.read_text(errors='replace');stderr=errpath.read_text(errors='replace')
    try:
        payload=json.loads(whisper_output.with_suffix('.json').read_text()) if engine=='whisper' else json.loads(stdout)
        text=' '.join(x['text'].strip() for x in payload['transcription']) if engine=='whisper' else payload['text']
    except (ValueError,KeyError,FileNotFoundError):payload={};text=''
    rss=re.search(r'(\d+)\s+maximum resident set size',stderr)
    record={'phase':phase,'fixture':fixture['id'],'engine':engine,'repetition':index,'pair_order':order,
            'wall_seconds':elapsed,'exit_code':code,'timeout':timed_out,'valid_json':bool(payload),
            'text':text,'text_sha256':hashlib.sha256(text.encode()).hexdigest(),
            'max_rss_bytes':int(rss.group(1)) if rss else None,
            'before':before,'after':snapshot(),'argv':command,
            'raw_stdout':outpath.name,'raw_stderr':errpath.name,
            'raw_stdout_sha256':digest(outpath),'raw_stderr_sha256':digest(errpath)}
    if engine=='whisper' and payload:
        record['raw_json']=whisper_output.with_suffix('.json').name
        record['raw_json_sha256']=digest(whisper_output.with_suffix('.json'))
    if engine=='handy':record['reported_timing']={k:payload.get(k) for k in ['load_ms','transcribe_ms','bound_backend','model','audio_secs']}
    with (ROOT/'observations.jsonl').open('a') as f:f.write(json.dumps(record,ensure_ascii=False)+'\n')
    print(label, 'OK' if code==0 and payload else 'FAIL',f'{elapsed:.3f}s',flush=True)
    return record

def main():
    args=argparse.ArgumentParser();args.add_argument('phase',choices=['smoke','quality','speed','long','long-mono']);args.add_argument('--engine',choices=['openramble','handy','whisper']);args.add_argument('--limit',type=int);a=args.parse_args()
    manifest=json.loads((ROOT/'manifest.json').read_text())
    protocol={'schema_version':1,'created_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
      'openramble_version':bundle_version(OPEN),
      'handy_version':bundle_version(HANDY),
      'openramble_binary_sha256':digest(OPEN),'handy_binary_sha256':digest(HANDY),
      'model_sha256':digest(MODEL),'model_id':MODEL_ID,'manifest_sha256':digest(ROOT/'manifest.json'),
      'hardware':subprocess.check_output(['sysctl','-n','hw.model','machdep.cpu.brand_string','hw.memsize','hw.logicalcpu'],text=True).splitlines(),
      'macos':subprocess.check_output(['sw_vers'],text=True),'seed':SEED,'pressure_workers':os.cpu_count(),
      'measure':'whole official CLI process, including launch, model load, file decode, recognition, JSON output and shutdown',
      'cache':'models pre-downloaded; OS file cache warm; fresh process/model per observation',
      'network':'denied by macOS sandbox-exec for all three CLIs',
      'settings':'fresh Handy portable settings, auto GPU/language, no custom words; OpenRamble shipping file CLI, no custom vocabulary',
      'quality':'first 100 SHA-ranked FLEURS test files per language; one run per product; all failures retained as empty output',
      'whisper_source_revision':subprocess.check_output(['git','-C',str(WHISPER.parents[2]),'rev-parse','HEAD'],text=True).strip(),
      'whisper_binary_sha256':digest(WHISPER),'whisper_model_sha256':digest(WHISPER_MODEL),
      'whisper_model':'Whisper large-v3-turbo F16; official ggerganov/whisper.cpp model, revision 5359861c739e955e79d9a303bcbc70fb988958b1',
      'whisper_settings':'Metal and flash attention enabled; default 4 CPU threads, default beam/best-of 5, automatic language, no prompt, no translation',
      'speed':'shortest, median and longest selected utterance in each language; all six permutations of OpenRamble/Handy/Whisper once per input per load condition; 36 observations per product per condition',
      'long':'60, 600 and 3540-second targets, complete alternating RU/EN utterances with 0.5-second gaps; composite stress workload; two balanced OH/HO pairs per input per load condition',
      'not_measured':['microphone','voice activation','key release to insertion','live meeting stop latency','other hardware','other Handy models']}
    if a.phase=='long-mono':
        protocol['extended_manifest_sha256']=digest(ROOT/'extended-long.json')
        protocol['diagnostic_followup']='Both monolingual hour files added after mixed hour WER failed; original failures retained.'
    pp=ROOT/('protocol-long-mono.json' if a.phase=='long-mono' else 'protocol-v2.json')
    if pp.exists():
        old=json.loads(pp.read_text())
        for k in ['openramble_binary_sha256','handy_binary_sha256','model_sha256','manifest_sha256','whisper_binary_sha256','whisper_model_sha256']:assert old[k]==protocol[k],k
    else:pp.write_text(json.dumps(protocol,ensure_ascii=False,indent=2)+'\n')
    done=set()
    if (ROOT/'observations.jsonl').exists():
        done={(x['phase'],x['fixture'],x['repetition'],x['engine']) for x in map(json.loads,(ROOT/'observations.jsonl').read_text().splitlines())}
    randomizer=random.Random(SEED)
    if a.phase=='smoke':
        for engine in ([a.engine] if a.engine else ['openramble','handy','whisper']):run_one(engine,manifest['fixtures'][0],'smoke',0,'OH',60)
        return
    if a.phase=='quality':
        files=manifest['fixtures'][:];randomizer.shuffle(files)
        if a.limit:files=files[:a.limit]
        with pressure(0):
            for i,f in enumerate(files):
                order='OH' if i%2==0 else 'HO'
                for engine in ([a.engine] if a.engine else ['openramble','handy'] if order=='OH' else ['handy','openramble']):
                    if ('quality',f['id'],0,engine) not in done:run_one(engine,f,'quality',0,order,90)
        return
    if a.phase=='speed':
        files=[]
        for lang in ['ru','en']:
            rows=sorted([f for f in manifest['fixtures'] if f['language']==lang],key=lambda f:f['duration_seconds'])
            files.extend([rows[0],rows[len(rows)//2],rows[-1]])
        repeats=6
    else:
        files=json.loads((ROOT/'extended-long.json').read_text())['fixtures'] if a.phase=='long-mono' else manifest['long_fixtures']
        repeats=2
    # Alternate quiet/load blocks so drift is not confounded with condition.
    for i in range(repeats):
        for loaded in ([False,True] if i%2==0 else [True,False]):
            phase=a.phase+('-load' if loaded else '-quiet')
            with pressure(os.cpu_count() if loaded else 0):
                for f in files:
                    engines=([a.engine] if a.engine else list(itertools.permutations(['openramble','handy','whisper']))[i%6] if a.phase=='speed' else ['openramble','handy'] if i%2==0 else ['handy','openramble'])
                    order=''.join(e[0].upper() for e in engines)
                    for engine in engines:
                        if (phase,f['id'],i,engine) not in done:run_one(engine,f,phase,i,order)

if __name__=='__main__':main()
