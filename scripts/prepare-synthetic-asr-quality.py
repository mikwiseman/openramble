#!/usr/bin/env python3
"""Opt-in Eleven v4 fictional fixtures; fixed inputs, budget and no paid retries."""
import argparse
import base64
import fcntl
import importlib.util
import json
import urllib.error
import urllib.request
import wave
from pathlib import Path

spec=importlib.util.spec_from_file_location('prepare',Path(__file__).with_name('prepare-asr-quality.py'))
prepare=importlib.util.module_from_spec(spec); spec.loader.exec_module(prepare)
VOICE_IDS=('nzd9osse7eBCO9j6LVnX','wUndevsXFk0ArF7vJ61U','Z3R5wn05IrDiVCyEkUrK')
MODEL='eleven_v4'
RATE_PER_1000=.08  # Undiscounted public API rate; ignores temporary 72% discount.
BUDGET=20.0

def api(key, route, payload=None):
    headers={'xi-api-key':key}
    if payload is not None: headers['Content-Type']='application/json'
    request=urllib.request.Request('https://api.elevenlabs.io'+route,
        data=json.dumps(payload).encode() if payload is not None else None,headers=headers)
    with urllib.request.urlopen(request,timeout=180) as response:
        return json.load(response),dict(response.headers)

def plan(args):
    snapshots=args.root/'sources'/'elevenlabs'
    voices={v['voice_id']:v for v in json.loads((snapshots/'voices.json').read_text())['voices']}
    models=json.loads((snapshots/'models.json').read_text())
    if not any(m['model_id']==MODEL and m['can_do_text_to_speech'] for m in models):
        raise ValueError('Eleven v4 availability must be checked first')
    chosen=[]
    for voice_id in VOICE_IDS:
        voice=voices[voice_id]; sharing=voice.get('sharing') or {}
        if voice['category']!='professional' or sharing.get('status')!='copied' or sharing.get('rate')!=1:
            raise ValueError('expected an existing copied library voice with ordinary rate')
        chosen.append({'voice_id':voice_id,'name':voice['name'],'labels':voice['labels'],
                       'library_voice_id':sharing['original_voice_id'],'rate':1})
    cases=json.loads((Path(__file__).resolve().parents[1]/'research/asr-quality-2026-09/synthetic-short.json').read_text())
    jobs=[]
    for case in cases:
        for split in ('dev','holdout'):
            for voice in chosen:
                text=case[split]
                if len(text)>2000: raise ValueError('dialogue request exceeds the documented reliable size')
                payload={'inputs':[{'text':text,'voice_id':voice['voice_id']}], 'model_id':MODEL,
                         'seed':20260930, 'settings':{'stability':.5,'similarity':.75},
                         'apply_text_normalization':'on'}
                if case['language']!='mixed': payload['language_code']=case['language']
                jobs.append({'id':f"eleven-short-{case['id']}-{split}-{voice['voice_id']}",
                    'scenario':case['id'],'split':split,'language':case['language'],'tags':case['tags'],
                    'group_id':f"eleven-short-{case['id']}-{split}",'reference':text,
                    'payload':payload,'characters':len(text),'maximum_cost_usd':len(text)*RATE_PER_1000/1000})
    document={'model_id':MODEL,'ai_generated':True,'voices':chosen,'jobs':jobs,
              'budget_usd':BUDGET,'undiscounted_rate_per_1000':RATE_PER_1000,
              'pricing_source':'https://elevenlabs.io/pricing/api','estimated_cost_usd':sum(j['maximum_cost_usd'] for j in jobs),
              'policy':'one request per frozen text/voice; no automatic retries; uncertain attempts count against budget'}
    path=args.root/'manifests'/'synthetic-plan.json'
    if path.exists() and json.loads(path.read_text())!=document: raise ValueError('synthetic plan already differs')
    prepare.atomic_json(path,document)
    print(f"sealed {len(jobs)} short jobs; conservative cost ${document['estimated_cost_usd']:.2f}",flush=True)

def generate(args):
    folder=args.root/'synthetic'; folder.mkdir(parents=True,exist_ok=True)
    with (folder/'ledger.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        generate_locked(args)

def generate_locked(args):
    key=args.key_file.read_text().strip()
    document=json.loads((args.root/'manifests/synthetic-plan.json').read_text())
    folder=args.root/'synthetic'/'generations'; folder.mkdir(parents=True,exist_ok=True)
    ledger_path=args.root/'synthetic'/'ledger.json'
    ledger=json.loads(ledger_path.read_text()) if ledger_path.exists() else {}
    reserved=sum(item['maximum_cost_usd'] for item in ledger.values())
    for job in document['jobs']:
        if job['id'] in ledger: continue
        if args.dev_only and job['split']!='dev': continue
        subscription,_=api(key,'/v1/user/subscription')
        available=subscription['character_limit']-subscription['character_count']
        if available<job['characters']:
            prepare.atomic_json(args.root/'synthetic/quota-check.json',
                {'status':'insufficient_credits','remaining':available,'next_job_characters':job['characters'],
                 'reset_unix':subscription['next_character_count_reset_unix'],'billing_changes':False})
            print(f'Eleven v4 quota: {available} remaining; checkpoint preserved',flush=True)
            return
        if reserved+job['maximum_cost_usd']>BUDGET: raise ValueError('authorized synthesis budget exhausted')
        entry={'status':'attempted','maximum_cost_usd':job['maximum_cost_usd'],'characters':job['characters'],
               'payload_sha256':prepare.text_hash(json.dumps(job['payload'],sort_keys=True))}
        ledger[job['id']]=entry; prepare.atomic_json(ledger_path,ledger)
        reserved+=job['maximum_cost_usd']
        try:
            response,headers=api(key,'/v1/text-to-dialogue/with-timestamps?output_format=pcm_16000',job['payload'])
            path=folder/(job['id']+'.json'); prepare.atomic_json(path,response)
            audio=base64.b64decode(response['audio_base64'],validate=True)
            wav=folder/(job['id']+'.wav')
            with wave.open(str(wav),'wb') as output:
                output.setnchannels(1); output.setsampwidth(2); output.setframerate(16000); output.writeframes(audio)
            entry.update({'status':'ok','request_id':headers.get('request-id') or headers.get('Request-Id'),
                'audio_path':str(wav),'audio_sha256':prepare.sha256(wav),
                'response_sha256':prepare.sha256(path),'duration_seconds':len(audio)/32000,
                'charged_characters':headers.get('character-cost') or headers.get('Character-Cost')})
            print(f"Eleven v4: {job['id']}, {len(audio)/32000:.2f}s, reserved total <=${reserved:.2f}",flush=True)
        except urllib.error.HTTPError as error:
            # No response body/key in logs, and no automatic paid regeneration.
            entry.update({'status':'http_error','http_status':error.code})
            print(f'Eleven v4: HTTP {error.code}; request retained in budget',flush=True)
        except (OSError,ValueError,KeyError) as error:
            entry.update({'status':'uncertain','error_type':type(error).__name__})
            print('Eleven v4: uncertain request; no automatic paid retry',flush=True)
        prepare.atomic_json(ledger_path,ledger)
        if entry['status']!='ok': return

def freeze(args):
    document=json.loads((args.root/'manifests/synthetic-plan.json').read_text())
    ledger=json.loads((args.root/'synthetic/ledger.json').read_text()); fixtures=[]
    for job in document['jobs']:
        entry=ledger.get(job['id'],{})
        if entry.get('status')!='ok':
            if not args.available_only: raise ValueError('full 72-example synthetic set is incomplete')
            continue
        fixtures.append({k:job[k] for k in ('id','scenario','split','language','tags','group_id','reference')}|
            {'dataset':'eleven_v4_short','path':entry['audio_path'],
             'canonical_path':str(args.root/'canonical'/f"{job['id']}.wav"),
             'reference_scope':'frozen fictional intended script; not independently verified spoken gold',
             'generation_response_sha256':entry['response_sha256'],'ai_generated':True})
    if not fixtures: raise ValueError('no successful generated fixtures')
    name='synthetic-short-partial' if args.available_only else 'synthetic-short'
    prepare.freeze(args.root,name,fixtures,[{'provider':'ElevenLabs','model_id':MODEL,
        'plan_sha256':prepare.sha256(args.root/'manifests/synthetic-plan.json'),
        'source':'fictional authored script; no private audio or text uploaded'}],args.asr_bin)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase',choices=('plan','generate','freeze'))
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--key-file',type=Path)
    parser.add_argument('--asr-bin',type=Path)
    parser.add_argument('--dev-only',action='store_true')
    parser.add_argument('--available-only',action='store_true')
    args=parser.parse_args()
    if args.root.resolve().is_relative_to(Path(__file__).resolve().parents[1]): parser.error('data root must be outside Git')
    if args.phase=='generate' and args.key_file is None: parser.error('--key-file required')
    if args.phase=='freeze' and args.asr_bin is None: parser.error('--asr-bin required')
    {'plan':plan,'generate':generate,'freeze':freeze}[args.phase](args)

if __name__=='__main__': main()
