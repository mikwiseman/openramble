# Compare the engine's tensor dumps with transcribe.cpp's for the same clip.
import json, os, sys, numpy as np
ref_dir, out_dir = sys.argv[1], sys.argv[2]
names = ['enc.mel.in', 'enc.pre_encode.out', 'enc.block.0.ff1', 'enc.block.0.attn', 'enc.block.0.conv',
         'enc.block.0.ff2'] + ['enc.block.%d.out' % i for i in range(24)] + ['enc.final']
for n in names:
    rp, op = os.path.join(ref_dir, n + '.f32'), os.path.join(out_dir, n + '.f32')
    if not (os.path.exists(rp) and os.path.exists(op)):
        print('%-22s missing' % n); continue
    shape = json.load(open(os.path.join(ref_dir, n + '.json')))['shape']
    r = np.fromfile(rp, dtype='<f4').reshape(shape)
    rows, cols = map(int, open(os.path.join(out_dir, n + '.shape')).read().split())
    o = np.fromfile(op, dtype='<f4').reshape(rows, cols)
    if r.shape != o.shape:
        k = min(r.shape[0], o.shape[0])   # the reference keeps padded frames
        note = ' (ref %s, ours %s)' % (r.shape, o.shape)
        r, o = r[:k], o[:k]
    else:
        note = ''
    d = np.abs(r - o)
    rel = float(np.linalg.norm(r - o) / (np.linalg.norm(r) + 1e-30))
    print('%-22s max|diff| %.3e  rms rel %.3e  max|ref| %.3g%s' % (n, d.max(), rel, np.abs(r).max(), note))
