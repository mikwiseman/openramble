"""Diagnostic follow-up, declared after mixed-language long-file failures."""
from pathlib import Path
import os
import hashlib,json,wave
r=Path(os.environ.get('BENCH_ROOT', str(Path.home() / 'Library/Caches/OpenRambleHandyBenchmark'))).expanduser();m=json.loads((r/'manifest.json').read_text());out=[]
for lang in ['ru','en']:
 files=[f for f in m['fixtures'] if f['language']==lang];p=r/'corpus/composite'/f'{lang}-3540s.wav';frames=0;refs=[];components=[]
 with wave.open(str(p),'wb') as w:
  w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000)
  while frames/16000<3540:
   f=files[len(components)%len(files)]
   with wave.open(f['path']) as inp:data=inp.readframes(inp.getnframes())
   w.writeframes(data);w.writeframes(b'\0'*16000);frames+=len(data)//2+8000;refs.append(f['reference']);components.append(f['id'])
 out.append({'id':f'{lang}-3540s','language':lang,'kind':'composite-stress-monolingual-followup','path':str(p),'audio_sha256':hashlib.file_digest(p.open('rb'),'sha256').hexdigest(),'duration_seconds':frames/16000,'reference':' '.join(refs),'components':components,'license':'CC BY 4.0'})
(r/'extended-long.json').write_text(json.dumps({'reason':'Follow-up to 39.1% WER on mixed long input. Both Russian and English tested to separate duration from language alternation; original mixed negative evidence retained.','fixtures':out},ensure_ascii=False,indent=2)+'\n')
print([(f['id'],f['duration_seconds']) for f in out])
