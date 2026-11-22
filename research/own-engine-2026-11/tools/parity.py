"""Compare two runtimes' output on the same clips.

    parity.py REFS.json A.tsv B.tsv [C.tsv ...]

Each TSV line is: clip name, text, tokens as id@start_ms, confidences (what
`ore-cli dump` and `tcpp-probe dump` print). REFS.json maps clip name to the
reference transcript. Prints, for every file after the first, how many clips
differ from the first in text and in tokens or times, and each file's word
error rate, scored as the polish loop scored it: NFKC, lower case, punctuation
removed, "ё" as "е".
"""
import json, re, sys, unicodedata


def norm(t):
    t = unicodedata.normalize("NFKC", t).lower().replace("ё", "е")
    t = re.sub(r"[^\w\s']", " ", t, flags=re.U)
    return re.sub(r"\s+", " ", t).strip().split()


def edits(r, h):
    d = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        prev, d[0] = d[0], i
        for j, hw in enumerate(h, 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (rw != hw))
            prev, d[j] = d[j], cur
    return d[len(h)]


def load(path):
    rows = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 3:
            rows[f[0]] = f
    return rows


refs = json.load(open(sys.argv[1]))
files = [load(p) for p in sys.argv[2:]]
names = [n for n in files[0] if all(n in f for f in files)]
print(f"{len(names)} clips in every file")
for path, rows in zip(sys.argv[2:], files):
    E = N = 0
    for n in names:
        if n in refs:
            ref = norm(refs[n])
            E += edits(ref, norm(rows[n][1]))
            N += len(ref)
    line = f"{path.split('/')[-1]}: word errors {E} of {N} = {100 * E / max(N, 1):.2f}%"
    if rows is not files[0]:
        text = sum(rows[n][1] != files[0][n][1] for n in names)
        tok = sum(rows[n][2] != files[0][n][2] for n in names)
        ids = sum([t.split("@")[0] for t in rows[n][2].split()] != [t.split("@")[0] for t in files[0][n][2].split()]
                  for n in names)
        better = worse = 0
        for n in names:
            if n in refs and rows[n][1] != files[0][n][1]:
                ref = norm(refs[n])
                a, b = edits(ref, norm(files[0][n][1])), edits(ref, norm(rows[n][1]))
                better += b < a
                worse += b > a
        line += (f"; against the first file: {text} clips differ in text, {ids} in token ids, {tok} in tokens or times;"
                 f" of the clips whose text differs, {better} have fewer word errors and {worse} have more")
    print(line)
