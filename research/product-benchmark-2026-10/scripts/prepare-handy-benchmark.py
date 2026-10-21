"""Freeze public FLEURS inputs before observing either product's output."""
from pathlib import Path
import os
import concurrent.futures, csv, hashlib, json, subprocess, tarfile, urllib.request, wave

ROOT = Path(os.environ.get('BENCH_ROOT', str(Path.home() / 'Library/Caches/OpenRambleHandyBenchmark'))).expanduser()
REV = '70bb2e84b976b7e960aa89f1c648e09c59f894dd'
SEED = 'openramble-handy-product-cli-20261009-v1'
ARCHIVES = {'en_us': 'd9c2e37b41aacd41bc283554a0a82b5476b36887049774ecb2819dcaaa55a356',
            'ru_ru': '8a0d6a0d23c3421f50c575bcf65d875cd19dadae2f7cabb415024f81b65178b1'}

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1<<20),b''): h.update(b)
    return h.hexdigest()

def fetch(url, path, expected=None):
    if not path.exists():
        subprocess.run(['curl','--fail','--location','--silent','--show-error','--retry','2',url,'-o',str(path)+'.part'],check=True)
        Path(str(path)+'.part').replace(path)
    if expected: assert digest(path)==expected, path

def prepare(locale):
    folder = ROOT/'corpus'/locale; folder.mkdir(parents=True,exist_ok=True)
    base = f'https://huggingface.co/datasets/google/fleurs/resolve/{REV}/data/{locale}/'
    metadata = folder/'test.tsv'; archive = folder/'test.tar.gz'
    fetch(base+'test.tsv',metadata)
    rows = list(csv.reader(metadata.open(),delimiter='\t'))
    rows.sort(key=lambda r:hashlib.sha256((SEED+'/'+locale+'/'+r[1]).encode()).hexdigest())
    # 100 utterances per language, selected once by hash, before recognition.
    chosen = rows[:100]; wanted = {r[1]:r for r in chosen}
    fetch(base+'audio/test.tar.gz',archive,ARCHIVES[locale])
    raw = folder/'source'; raw.mkdir(exist_ok=True)
    with tarfile.open(archive,'r|gz') as tar:
        for entry in tar:
            name = Path(entry.name).name
            if name not in wanted or not entry.isfile(): continue
            with tar.extractfile(entry) as source, (raw/name).open('wb') as output:
                output.write(source.read())
    canonical = folder/'pcm16';canonical.mkdir(exist_ok=True)
    fixtures=[]
    for rank,r in enumerate(chosen):
        source=raw/r[1];target=canonical/r[1]
        if not target.exists():
            subprocess.run(['afconvert','-f','WAVE','-d','LEI16','-r','16000','-c','1',str(source),str(target)],check=True,capture_output=True)
        with wave.open(str(target)) as w:
            assert (w.getframerate(),w.getnchannels(),w.getsampwidth())==(16000,1,2)
            frames=w.getnframes()
        fixtures.append({'id':locale+'-'+r[1][:-4],'language':locale[:2],'rank':rank,
                         'path':str(target),'audio_sha256':digest(target),'duration_seconds':frames/16000,
                         'reference':r[2],'reference_sha256':hashlib.sha256(r[2].encode()).hexdigest(),
                         'source_filename':r[1],'source_row_id':r[0],'gender':r[6],'license':'CC BY 4.0'})
    print(locale, len(fixtures), 'inputs frozen',flush=True)
    return fixtures

if __name__=='__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        groups=list(pool.map(prepare,ARCHIVES))
    fixtures=sum(groups,[])
    longdir=ROOT/'corpus/composite';longdir.mkdir(exist_ok=True)
    # This is explicitly a composite stress workload, not a real conversation.
    # Alternate RU/EN complete public utterances; add 0.5 s silence between them.
    order=[x for pair in zip(groups[1],groups[0]) for x in pair]
    long=[]
    for target_seconds in [60,600,3540]:
        p=longdir/f'mixed-{target_seconds}s.wav';ref=[];sources=[];frames=0
        with wave.open(str(p),'wb') as out:
            out.setnchannels(1);out.setsampwidth(2);out.setframerate(16000)
            while frames/16000 < target_seconds:
                f=order[len(sources)%len(order)]
                with wave.open(f['path']) as inp: data=inp.readframes(inp.getnframes())
                out.writeframes(data);out.writeframes(b'\0'*16000)
                frames+=len(data)//2+8000;ref.append(f['reference']);sources.append(f['id'])
        long.append({'id':f'mixed-{target_seconds}s','language':'mixed','kind':'composite-stress',
                     'path':str(p),'audio_sha256':digest(p),'duration_seconds':frames/16000,
                     'reference':' '.join(ref),'components':sources,'license':'CC BY 4.0'})
    document={'schema_version':1,'source':'google/fleurs','source_revision':REV,'split':'test',
              'license':'CC BY 4.0','selection_seed':SEED,'selection':'100 per language, SHA-256 ranked filenames',
              'archive_sha256':ARCHIVES,'fixtures':fixtures,'long_fixtures':long}
    (ROOT/'manifest.json').write_text(json.dumps(document,ensure_ascii=False,indent=2)+'\n')
    print('frozen manifest',digest(ROOT/'manifest.json'),flush=True)
