#!/usr/bin/env python3
"""Fetch pinned corpus files directly; never execute remote dataset loaders.

Use an explicit root OUTSIDE Git for source audio, canonical audio, transcripts,
weights and per-example results. Selection is SHA-ranked before inference.
"""
from __future__ import annotations
import argparse
import csv
import fcntl
import hashlib
import heapq
import json
import os
import shutil
import subprocess
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path

CV_REPOSITORY = 'fsicoli/common_voice_19_0'
CV_REVISION = '590c8abec6cf7c8d06e650f1438e60332a796e11'
FLEURS_REPOSITORY = 'google/fleurs'
FLEURS_REVISION = '70bb2e84b976b7e960aa89f1c648e09c59f894dd'
SEED = 'openramble-approved-quality-20260930-v1'
MODELS = (
    {'id':'turbo', 'repository':'handy-computer/whisper-large-v3-turbo-gguf',
     'revision':'ceea6c8a94a21ab85be244d311e874a39344dbf5', 'license':'apache-2.0',
     'file':'whisper-large-v3-turbo-Q8_0.gguf', 'bytes':886381760,
     'sha256':'b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183'},
    {'id':'breeze', 'repository':'handy-computer/Breeze-ASR-25-gguf',
     'revision':'6b7a53cea9265a2cf2b19e37b3ceadeb2927d3ba', 'license':'apache-2.0',
     'file':'Breeze-ASR-25-Q8_0.gguf', 'bytes':1667964224,
     'sha256':'1650c163cd1623d13b585368ffd87d7e669c5ff23014511e0fa91bb4ce994756'},
)
GOLOS_MIRRORS = (
    ('crowd','bond005/sberdevices_golos_10h_crowd','e634b6b810e4d30c81b4c6d8262379fe8b9f708c',9994),
    ('farfield','bond005/sberdevices_golos_100h_farfield','c93949f7140beef4adc404e7b54841e957f81c54',1916),
)

def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''): digest.update(chunk)
    return digest.hexdigest()

def text_hash(text): return hashlib.sha256(text.encode()).hexdigest()

def atomic_json(path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix+'.part')
    temporary.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True)+'\n')
    temporary.replace(path)

def get_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'OpenRamble-research/1'}), timeout=30) as response:
        return json.load(response)

def download(url, path, expected_sha=None, expected_size=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(path.suffix + '.download.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _download_locked(url, path, expected_sha, expected_size)

def _download_locked(url, path, expected_sha=None, expected_size=None):
    if path.exists():
        if expected_sha and sha256(path) != expected_sha: raise ValueError('existing source hash differs')
        if expected_size and path.stat().st_size != expected_size: raise ValueError('existing source size differs')
        return path
    temporary = path.with_suffix(path.suffix+'.part')
    failures = 0
    integrity_failures = 0
    request_number = 0
    while failures < 3 and integrity_failures < 3 and request_number < 1000:
        request_number += 1
        offset = temporary.stat().st_size if temporary.exists() else 0
        if expected_size and offset >= expected_size:
            if offset == expected_size and (not expected_sha or sha256(temporary) == expected_sha):
                temporary.replace(path)
                return path
            temporary.replace(temporary.with_suffix(f'.invalid-{time.time_ns()}'))
            integrity_failures += 1
            if integrity_failures == 3: break
            print(f'{path.name}: invalid interrupted partial preserved; restarting', flush=True)
            offset = 0
        headers = {'User-Agent':'OpenRamble-research/1'}
        if offset: headers['Range'] = f'bytes={offset}-'
        try:
            # Request a fresh signed CDN redirect rather than a cached expiry.
            request = urllib.request.Request(url + ('&' if '?' in url else '?') + f'download=true&request={time.time_ns()}', headers=headers)
            with urllib.request.urlopen(request, timeout=60) as source:
                resumed = offset and source.status == 206
                if resumed and not source.headers.get('Content-Range','').startswith(f'bytes {offset}-'):
                    raise ValueError('unexpected download resume offset')
                with temporary.open('ab' if resumed else 'wb') as output:
                    shutil.copyfileobj(source, output, length=1 << 20)
                    output.flush()
                    os.fsync(output.fileno())
            size = temporary.stat().st_size
            if expected_size and size < expected_size:
                if size > offset:
                    print(f'{path.name}: partial {size}/{expected_size}; resuming', flush=True)
                    continue
                raise OSError('download made no progress')
            if (expected_size and size > expected_size) or (expected_sha and sha256(temporary) != expected_sha):
                temporary.replace(temporary.with_suffix(f'.invalid-{time.time_ns()}'))
                integrity_failures += 1
                print(f'{path.name}: interrupted partial failed SHA256; restarting', flush=True)
                continue
            temporary.replace(path)
            print(f'frozen {path.name}: {path.stat().st_size} bytes', flush=True)
            return path
        except (urllib.error.URLError, TimeoutError, OSError):
            failures += 1
            if failures == 3: raise
            time.sleep(2)
    raise RuntimeError('download failed')

def hf_file(repository, revision, relative, root, kind='datasets'):
    tree = get_json(f'https://huggingface.co/api/{kind}/{repository}/tree/{revision}/{str(Path(relative).parent)}')
    info = next(item for item in tree if item['path'] == relative)
    url = f'https://huggingface.co/{kind+"/" if kind=="datasets" else ""}{repository}/resolve/{revision}/{relative}'
    expected = info.get('lfs',{}).get('oid')
    path = download(url, root / relative, expected, info['size'])
    return path, {'repository':repository, 'revision':revision, 'path':relative,
                  'url':url, 'sha256':sha256(path), 'bytes':path.stat().st_size}

def extract_selected(archive, wanted, destination):
    # Only selected regular members, under our own names: no tar paths,
    # links, devices, remote permissions or extractall.
    pending = dict(wanted)
    with tarfile.open(archive, mode='r|*') as tar:
        for member in tar:
            filename = Path(member.name).name
            if filename not in pending or not member.isfile(): continue
            target = destination / pending.pop(filename)
            target.parent.mkdir(parents=True, exist_ok=True)
            source = tar.extractfile(member)
            if source is None: raise ValueError('unreadable archive member')
            with source, target.open('wb') as output: shutil.copyfileobj(source, output)
    if pending: raise ValueError(f'{len(pending)} selected archive members missing')

def freeze(root, name, fixtures, sources, asr_bin):
    input_path = root/'manifests'/f'{name}-conversion.json'
    atomic_json(input_path, {'fixtures':fixtures})
    result = subprocess.run([str(asr_bin), 'canonicalize', str(input_path)], capture_output=True, text=True, check=True)
    converted = {row['id']:row for row in map(json.loads,result.stdout.splitlines())}
    if set(converted) != {fixture['id'] for fixture in fixtures}:
        raise ValueError('canonicalizer did not return the frozen input identities')
    for fixture in fixtures:
        if fixture.get('source_expected_samples') is not None and converted[fixture['id']]['sample_count'] != fixture['source_expected_samples']:
            raise ValueError('canonical sample count differs from source metadata')
        source = Path(fixture['path'])
        fixture['source_audio_sha256'] = sha256(source)
        fixture['path'] = fixture.pop('canonical_path')
        fixture.update({k:v for k,v in converted[fixture['id']].items() if k!='id'})
        fixture['audio_sha256'] = sha256(Path(fixture['path']))
        fixture['reference_sha256'] = text_hash(fixture['reference'])
    document = {'schema_version':1, 'name':name, 'selection_seed':SEED, 'sources':sources,
                'selection':'stable SHA256 rank of seed + source split + source identity; frozen before inference',
                'reference_policy':'source human-speech transcript; benchmark gold is not application output',
                'canonicalization':'shipping AudioFileReader; Float32 mono 16k WAV; round-trip PCM hash verified',
                'fixtures':fixtures}
    path = root/'manifests'/f'{name}.json'
    if path.exists() and json.loads(path.read_text()) != document: raise ValueError('refusing to replace a frozen manifest')
    atomic_json(path,document)
    # Public metadata is reviewable; references/audio/absolute source paths stay local.
    public = {k:v for k,v in document.items() if k!='fixtures'}
    public['fixtures'] = [{k:v for k,v in f.items() if k not in ('path','reference')} for f in fixtures]
    public['manifest_sha256'] = sha256(path)
    atomic_json(root/'manifests'/f'{name}-public.json', public)
    print(f'{name}: sealed {len(fixtures)} examples, manifest SHA256 {sha256(path)}',flush=True)

def common_voice(args, split, count, name):
    root=args.root; fixtures=[]; sources=[]
    for language in ('ru','en'):
        base=root/'sources'/'cv19'
        transcript,meta=hf_file(CV_REPOSITORY,CV_REVISION,f'transcript/{language}/{split}.tsv',base)
        sources.append(meta|{'unofficial_mirror':True,'license':'CC0-1.0'})
        with transcript.open(newline='') as stream: rows=list(csv.DictReader(stream,delimiter='\t'))
        rows.sort(key=lambda row:text_hash(SEED+'|cv19|'+language+'|'+split+'|'+row['path']))
        selected=rows[:count]
        if len(selected)!=count: raise ValueError('insufficient Common Voice rows')
        archive,meta=hf_file(CV_REPOSITORY,CV_REVISION,f'audio/{language}/{split}/{language}_{split}_0.tar',base)
        sources.append(meta|{'unofficial_mirror':True,'license':'CC0-1.0'})
        wanted={Path(row['path']).name: f'{language}/{split}/{Path(row["path"]).name}' for row in selected}
        extract_selected(archive,wanted,root/'audio-source'/'cv19')
        for row in selected:
            stem=Path(row['path']).stem; fixture_id=f'cv19-{language}-{split}-{stem}'
            fixtures.append({'id':fixture_id,'dataset':'common_voice_19_mirror','split':split,'language':language,
                'group_id':'cv19-'+language+'-'+(row.get('client_id') or stem),
                'source_sentence_id':row.get('sentence_id'), 'source_member':row['path'],
                'reference':row['sentence'],'path':str(root/'audio-source'/'cv19'/language/split/Path(row['path']).name),
                'canonical_path':str(root/'canonical'/f'{fixture_id}.wav')})
    freeze(root,name,fixtures,sources,args.asr_bin)

def fleurs(args):
    fixtures=[]; sources=[]
    for language,config,expected_count in (('ru','ru_ru',775),('en','en_us',647)):
        base=args.root/'sources'/'fleurs'
        transcript,meta=hf_file(FLEURS_REPOSITORY,FLEURS_REVISION,f'data/{config}/test.tsv',base)
        sources.append(meta|{'license':'CC-BY-4.0'})
        with transcript.open(newline='') as stream: rows=list(csv.reader(stream,delimiter='\t',quoting=csv.QUOTE_NONE))
        if len(rows)!=expected_count: raise ValueError('FLEURS test count changed')
        archive,meta=hf_file(FLEURS_REPOSITORY,FLEURS_REVISION,f'data/{config}/audio/test.tar.gz',base)
        sources.append(meta|{'license':'CC-BY-4.0'})
        extract_selected(archive,{row[1]:f'{config}/{row[1]}' for row in rows},args.root/'audio-source'/'fleurs')
        for row in rows:
            source_id,filename,raw,reference,characters,samples,gender=row
            fixture_id=f'fleurs-{language}-test-{Path(filename).stem}'
            fixtures.append({'id':fixture_id,'dataset':'fleurs','split':'test','language':language,
                'group_id':f'fleurs-{language}-{source_id}', 'source_id':source_id,'source_member':filename,
                'reference':reference, 'raw_reference_sha256':text_hash(raw),
                'source_expected_samples':int(samples),'gender':gender,
                'path':str(args.root/'audio-source'/'fleurs'/config/filename),
                'canonical_path':str(args.root/'canonical'/f'{fixture_id}.wav')})
    freeze(args.root,'holdout',fixtures,sources,args.asr_bin)

def models(args):
    plan = [model | {'url':f'https://huggingface.co/{model["repository"]}/resolve/{model["revision"]}/{model["file"]}'} for model in MODELS]
    path = args.root/'models'/'model-plan.json'
    if path.exists() and json.loads(path.read_text()) != plan:
        raise ValueError('refusing to replace the frozen model plan')
    atomic_json(path, plan)
    for model in plan:
        card_url = f'https://huggingface.co/{model["repository"]}/raw/{model["revision"]}/README.md'
        download(card_url, args.root/'models'/f'{model["id"]}-README.md')
        download(model['url'], args.root/'models'/model['id']/model['file'], model['sha256'], model['bytes'])
        print(f'{model["id"]}: verified pinned Q8_0 model', flush=True)

def golos(args):
    import pyarrow
    import pyarrow.parquet as parquet
    if pyarrow.__version__ != '25.0.1': raise ValueError('Golos extraction pins pyarrow==25.0.1')
    fixtures=[]; sources=[]
    for domain,repository,revision,expected_count in GOLOS_MIRRORS:
        base=args.root/'sources'/'golos'/f'{domain}-mirror'
        tree=get_json(f'https://huggingface.co/api/datasets/{repository}/tree/{revision}/data')
        files=sorted(item['path'] for item in tree if Path(item['path']).name.startswith('test-') and item['path'].endswith('.parquet'))
        if not files: raise ValueError('missing mirrored Golos test shards')
        chosen=[]; seen=set(); count=0; missing_gold=0; duplicate_audio=0
        for relative in files:
            source,meta=hf_file(repository,revision,relative,base)
            sources.append(meta|{'unofficial_mirror':True,'license':'Golos custom source license',
                'upstream':'https://www.openslr.org/114/', 'pyarrow_version':pyarrow.__version__,
                'lineage':'mirror card identifies full original test split; original tar MD5 is not verified by this representation'})
            for batch in parquet.ParquetFile(source).iter_batches(batch_size=64):
                for row in batch.to_pylist():
                    count+=1; data=row['audio']['bytes']; reference=row['transcription']
                    if not data: raise ValueError('empty source audio')
                    # Eligibility is frozen from source annotations, before any
                    # inference; absent gold cannot be fabricated from ASR.
                    if not isinstance(reference,str) or not reference.strip():
                        missing_gold+=1; continue
                    digest=hashlib.sha256(data).hexdigest()
                    if digest in seen:
                        duplicate_audio+=1; continue
                    seen.add(digest)
                    rank=text_hash(SEED+'|golos|'+domain+'|test|'+digest)
                    item=(-int(rank,16),digest,reference,data)
                    if len(chosen)<500: heapq.heappush(chosen,item)
                    elif item[0]>chosen[0][0]: heapq.heapreplace(chosen,item)
        if count!=expected_count or len(chosen)!=500: raise ValueError('Golos original test count or unique selection differs')
        sources.append({'repository':repository,'revision':revision,'domain':domain,
            'population_rows':count,'source_missing_reference':missing_gold,'duplicate_source_audio':duplicate_audio,
            'selected':500,'eligibility':'unique audio with nonempty source reference; before inference',
            'grouping':'identical prompt; source speaker identities unavailable'})
        for _,digest,reference,data in sorted(chosen,reverse=True):
            fixture_id=f'golos-{domain}-test-{digest}'
            source=args.root/'audio-source'/'golos'/domain/f'{digest}.wav'
            source.parent.mkdir(parents=True,exist_ok=True)
            if source.exists() and source.read_bytes()!=data: raise ValueError('sealed Golos source differs')
            source.write_bytes(data)
            fixtures.append({'id':fixture_id,'dataset':f'golos_{domain}_mirror','split':'test','language':'ru',
                'group_id':f'golos-{domain}-prompt-'+text_hash(' '.join(reference.lower().split())),
                'grouping':'identical source prompt; speaker identifiers are absent in this mirror; CI does not establish speaker independence',
                'source_member':digest,'reference':reference,'path':str(source),
                'canonical_path':str(args.root/'canonical'/f'{fixture_id}.wav')})
        print(f'Golos {domain}: frozen selection of 500 from {count} mirrored test rows',flush=True)
    freeze(args.root,'golos-main',fixtures,sources,args.asr_bin)

def combine_main(args):
    inputs=[json.loads((args.root/'manifests'/f'{name}.json').read_text()) for name in ('cv-main','golos-main')]
    document={'schema_version':1,'name':'main','selection_seed':SEED,
              'sources':[source for manifest in inputs for source in manifest['sources']],
              'component_sha256':{name:sha256(args.root/'manifests'/f'{name}.json') for name in ('cv-main','golos-main')},
              'fixtures':[fixture for manifest in inputs for fixture in manifest['fixtures']]}
    if len(document['fixtures'])!=2000: raise ValueError('main study requires 2000 examples')
    path=args.root/'manifests/main.json'
    if path.exists() and json.loads(path.read_text())!=document: raise ValueError('main manifest already differs')
    atomic_json(path,document)
    print(f'main: sealed 2000 examples, SHA256 {sha256(path)}',flush=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase',choices=('models','quick','cv-main','golos','main','holdout'))
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--asr-bin',type=Path)
    args=parser.parse_args()
    repo=Path(__file__).resolve().parents[1]
    if args.root.resolve().is_relative_to(repo): parser.error('data root must be outside Git')
    if args.phase not in ('models','main') and args.asr_bin is None: parser.error('corpus preparation requires --asr-bin')
    if args.phase=='models': models(args)
    elif args.phase=='quick': common_voice(args,'dev',100,'quick')
    elif args.phase=='cv-main': common_voice(args,'test',500,'cv-main')
    elif args.phase=='golos': golos(args)
    elif args.phase=='main': combine_main(args)
    else: fleurs(args)

if __name__=='__main__': main()
