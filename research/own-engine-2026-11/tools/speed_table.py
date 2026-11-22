"""Turn the measurement lines of one hosted machine into a table.

    speed_table.py MACHINE.txt [MACHINE.txt ...]

Prints, per machine and per thread count, the best wall time in milliseconds of
each runtime by clip length, and the ratio.
"""
import re, sys

for path in sys.argv[1:]:
    cpu = ''
    runs = []   # (runtime, kernels, threads, {seconds: wall_min})
    cur = None
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.rstrip('\n')
        m = re.match(r'^(?:Model name:\s*|Name\s*:\s*)?((?:Intel|Apple|AMD|INTEL|Neoverse).*)$', line)
        if m and not cpu:
            cpu = m.group(1).strip()
        m = re.match(r'^ore [\d.]+, (\w+), threads (\d+)', line)
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
