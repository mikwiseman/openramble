"""Turn the measurement lines of one hosted machine into a table.

    speed_table.py MACHINE.txt [MACHINE.txt ...]

Prints, per machine and per thread count, the best wall time in milliseconds of
each runtime by clip length, and the ratio. Where a job also ran the Q8_0 file
(lines prefixed "Q8_0 | "), prints transcribe.cpp with Q8_0, which is what
Windows and Linux ship, against the engine with each file.
"""
import re, sys

def parse(lines):
    runs = []   # (runtime, kernels, threads, {seconds: wall_min})
    cur = None
    for line in lines:
        m = re.match(r'^ore [\d.]+, ([\w+]+), threads (\d+)', line)
        if m:
            cur = ('ore', m.group(1), int(m.group(2)), {}); runs.append(cur); continue
        m = re.match(r'^transcribe\.cpp [\d.]+, backend CPU, threads (\d+)', line)
        if m:
            cur = ('tcpp', 'ggml', int(m.group(1)), {}); runs.append(cur); continue
        m = re.match(r'^\s+([\d.]+) \|\s+([\d.]+) \|', line)
        if m and cur:
            cur[3][float(m.group(1))] = float(m.group(2))
    return runs


for path in sys.argv[1:]:
    cpu = ''
    runs = []   # (runtime, kernels, threads, {seconds: wall_min})
    cur = None
    q8_lines = []
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.rstrip('\n')
        if line.startswith('Q8_0 | '):
            q8_lines.append(line[7:])
            continue
        m = re.match(r'^(?:Model name:\s*|Name\s*:\s*)?((?:Intel|Apple|AMD|INTEL|Neoverse).*)$', line)
        if m and not cpu:
            cpu = m.group(1).strip()
        m = re.match(r'^ore [\d.]+, ([\w+]+), threads (\d+)', line)
        if m:
            cur = ('ore', m.group(1), int(m.group(2)), {}); runs.append(cur); continue
        m = re.match(r'^transcribe\.cpp [\d.]+, backend CPU, threads (\d+)', line)
        if m:
            cur = ('tcpp', 'ggml', int(m.group(1)), {}); runs.append(cur); continue
        m = re.match(r'^\s+([\d.]+) \|\s+([\d.]+) \|', line)
        if m and cur:
            cur[3][float(m.group(1))] = float(m.group(2))
    print(f'## {path.split("/")[-1][:-4]}: {cpu}')
    # The first three engine runs are the chosen kernel set at 1, 2 and 4
    # threads; later ones name another set.
    best = [r for r in runs if r[0] == 'ore'][:3]
    for o in best:
        t = next((r for r in runs if r[0] == 'tcpp' and r[2] == o[2]), None)
        if not t:
            continue
        cells = []
        for secs in sorted(o[3]):
            if secs in t[3]:
                cells.append(f'{secs:g} s: {o[3][secs]:.0f} vs {t[3][secs]:.0f} ({t[3][secs] / o[3][secs]:.2f}x)')
        print(f'  {o[2]} threads, {o[1]}: ' + '; '.join(cells))
    for o in [r for r in runs if r[0] == 'ore'][3:]:
        if o[1] == best[0][1]:
            continue  # the same set again
        t = next((r for r in runs if r[0] == 'tcpp' and r[2] == o[2]), None)
        cells = [f'{secs:g} s: {o[3][secs]:.0f}' + (f' vs {t[3][secs]:.0f}' if t and secs in t[3] else '') for secs in sorted(o[3])]
        print(f'  {o[2]} threads, {o[1]} kernels: ' + '; '.join(cells))
    q8 = parse(q8_lines)
    if q8:
        text = next((l for l in q8_lines if l.startswith('text:')), 'text: not reported')
        print(f'  Q8_0 file, both runtimes: {text}')
        for threads in (1, 2, 4):
            t8 = next((r for r in q8 if r[0] == 'tcpp' and r[2] == threads), None)
            o8 = next((r for r in q8 if r[0] == 'ore' and r[2] == threads), None)
            o4 = next((r for r in best if r[2] == threads), None)
            if not (t8 and o8 and o4):
                continue
            cells = [f'{secs:g} s: {t8[3][secs]:.0f} | {o4[3][secs]:.0f} ({t8[3][secs] / o4[3][secs]:.2f}x) | '
                     f'{o8[3][secs]:.0f} ({t8[3][secs] / o8[3][secs]:.2f}x)'
                     for secs in sorted(t8[3]) if secs in o4[3] and secs in o8[3]]
            print(f'  {threads} threads, transcribe.cpp Q8_0 | engine Q4_K_M | engine Q8_0: ' + '; '.join(cells))
        shipped = next((r for r in q8 if r[0] == 'tcpp' and r[2] == 1), None)
        if shipped:
            for threads in (2, 4):
                o4 = next((r for r in best if r[2] == threads), None)
                if o4:
                    cells = [f'{secs:g} s: {shipped[3][secs]:.0f} vs {o4[3][secs]:.0f} ({shipped[3][secs] / o4[3][secs]:.1f}x)'
                             for secs in sorted(shipped[3]) if secs in o4[3]]
                    print(f'  as shipped (transcribe.cpp, Q8_0, one thread) vs engine Q4_K_M on {threads} threads: ' + '; '.join(cells))
