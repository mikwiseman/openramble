import struct, sys, collections
def rd(f, fmt):
    n = struct.calcsize(fmt); return struct.unpack(fmt, f.read(n))
def rstr(f):
    (n,) = rd(f, '<Q'); return f.read(n).decode('utf-8', 'replace')
T = {0:'B',1:'b',2:'H',3:'h',4:'I',5:'i',6:'f',7:'?',10:'Q',11:'q',12:'d'}
def rval(f, t, depth=0):
    if t in T: return rd(f, '<'+T[t])[0]
    if t == 8: return rstr(f)
    if t == 9:
        (et,) = rd(f, '<I'); (n,) = rd(f, '<Q')
        vals = [rval(f, et, depth+1) for _ in range(n)]
        return vals
    raise ValueError(t)
GT = {0:'F32',1:'F16',2:'Q4_0',3:'Q4_1',6:'Q5_0',7:'Q5_1',8:'Q8_0',9:'Q8_1',10:'Q2_K',11:'Q3_K',12:'Q4_K',13:'Q5_K',14:'Q6_K',15:'Q8_K',24:'I8',25:'I16',26:'I32',27:'I64',28:'F64',30:'BF16'}
f = open(sys.argv[1], 'rb')
magic = f.read(4); (ver,) = rd(f, '<I'); (nt,) = rd(f, '<Q'); (nkv,) = rd(f, '<Q')
print('magic', magic, 'version', ver, 'tensors', nt, 'kv', nkv)
kv = {}
for _ in range(nkv):
    k = rstr(f); (t,) = rd(f, '<I'); v = rval(f, t); kv[k] = v
    if isinstance(v, list): print('KV', k, 'list', len(v), repr(v[:6])[:160])
    else: print('KV', k, repr(v)[:200])
tens = []
for _ in range(nt):
    name = rstr(f); (nd,) = rd(f, '<I'); dims = rd(f, '<%dQ' % nd); (ty,) = rd(f, '<I'); (off,) = rd(f, '<Q')
    tens.append((name, dims, GT.get(ty, ty), off))
align = kv.get('general.alignment', 32)
base = (f.tell() + align - 1) // align * align
print('data base', base)
mode = sys.argv[2] if len(sys.argv) > 2 else 'summary'
if mode == 'all':
    for t in tens: print('T', t[0], list(t[1]), t[2], t[3])
else:
    c = collections.Counter(t[2] for t in tens); print(c)
    for t in tens:
        if 'layers.' in t[0] or 'blocks.' in t[0]:
            import re
            if not re.search(r'\.(0|23)\.', t[0]): continue
        print('T', t[0], list(t[1]), t[2], t[3])
