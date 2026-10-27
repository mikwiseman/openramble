"""Peak memory of one Linux process while it runs: python3 sample.py PID OUT.json [--for SECONDS].

Reads /proc/PID/smaps_rollup every 0.2 s. Rss counts the mapped model file's
pages once per process; Anonymous is what the process owns outright, the part
that cannot be dropped and reread, and what grows per engine.
"""
import json
import sys
import time

FIELDS = ('Rss', 'Pss', 'Anonymous', 'Private_Dirty', 'Shared_Clean', 'Private_Clean')


def read(pid):
    values = {}
    with open(f'/proc/{pid}/smaps_rollup') as rollup:
        for line in rollup:
            name, _, rest = line.partition(':')
            if name in FIELDS:
                values[name] = int(rest.split()[0]) * 1024
    return values


def main():
    pid, out = int(sys.argv[1]), sys.argv[2]
    until = time.monotonic() + float(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[3] == '--for' else None
    peak, last = {}, {}
    while until is None or time.monotonic() < until:
        try:
            last = read(pid)
        except (FileNotFoundError, ProcessLookupError):
            break
        for name, value in last.items():
            peak[name] = max(peak.get(name, 0), value)
        time.sleep(0.2)
    with open(out, 'w') as file:
        json.dump({'peak': peak, 'last': last}, file, indent=1)


main()
