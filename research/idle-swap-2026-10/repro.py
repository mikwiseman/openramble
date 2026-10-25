"""Idle-swap reproduction: asr-bench serve lanes idle side by side under the same
memory pressure, then one take each, one lane at a time in ORDER. A lane named
`before…` sends the take at key-up only (0.33.1 behaviour); a lane named
`after…` sends `warm` at key-down, as the app now does, then the take SPEECH
seconds later. Appends one JSON object per trial to OUT; transcripts are dropped.

    python3 -I repro.py <asr-bench> <model dir> <take.wav> <hog> <out.jsonl>
"""
import json, os, signal, subprocess, sys, threading, time, shutil, re

BIN, MODEL, WAV, HOG, OUT = sys.argv[1:6]
IDLE = float(os.environ.get("IDLE", 240))
SPEECH = float(os.environ.get("SPEECH", 3.79))
HOG_GB = os.environ.get("HOG_GB", "8")
ORDER = os.environ.get("ORDER", "before,after").split(",")
MIN_FREE = 8 * 2**30

T0 = time.monotonic()
def log(*a): print(f"[{time.monotonic()-T0:7.1f}s]", *a, flush=True)

def vm():
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    get = lambda k: int(re.search(k + r":\s+(\d+)", out).group(1))
    swap = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout
    used = float(re.search(r"used = ([\d.]+)M", swap).group(1))
    return {"swapins": get("Swapins"), "swapouts": get("Swapouts"), "freePages": get("Pages free"),
            "compressorPages": get("Pages occupied by compressor"), "swapUsedMB": used,
            "vmFreeGiB": round(shutil.disk_usage("/System/Volumes/VM").free / 2**30, 2)}

def rss_mb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out) // 1024 if out else None

class Lane:
    def __init__(self, name):
        self.name = name
        env = dict(os.environ, WAI_ASR_MODEL_DIR=MODEL)
        self.p = subprocess.Popen([BIN, "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, env=env, bufsize=1)
        self.lines, self.cv = [], threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()
    def _read(self):
        for line in self.p.stdout:
            if not line.startswith("{"): continue
            obj = json.loads(line); obj.pop("text", None)  # never keep transcripts
            with self.cv: self.lines.append(obj); self.cv.notify_all()
    def wait(self, pred, timeout=120, what=""):
        end = time.time() + timeout
        with self.cv:
            while True:
                for obj in self.lines:
                    if pred(obj): return obj
                left = end - time.time()
                if left <= 0: raise TimeoutError(f"{self.name}: {what}")
                if self.p.poll() is not None: raise RuntimeError(f"{self.name} exited {self.p.returncode}: {what}")
                self.cv.wait(min(left, 1))
    def send(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n"); self.p.stdin.flush()
    def close(self):
        self.p.stdin.close(); self.p.wait(timeout=60)

def take(lane, warm):
    keydown = time.monotonic()
    rec = {"lane": lane.name, "rssMBBefore": rss_mb(lane.p.pid), "vmBefore": vm()}
    if warm:
        lane.send({"id": "warm", "mode": "warm"})
        rec["warmReply"] = lane.wait(lambda o: o.get("id") == "warm" and "warming" in o, what="warm reply")
        log(lane.name, "key-down, warm sent", rec["warmReply"])
    time.sleep(max(0, SPEECH - (time.monotonic() - keydown)))
    keyup = time.monotonic()
    lane.send({"id": "take", "path": WAV})
    log(lane.name, "key-up, take sent")
    reply = lane.wait(lambda o: o.get("id") == "take", timeout=600, what="take")
    log(lane.name, "take answered")
    rec["keyUpToTextSeconds"] = round(time.monotonic() - keyup, 3)
    rec["take"] = reply
    if warm and rec["warmReply"].get("warming"):
        rec["warmed"] = lane.wait(lambda o: o.get("event") == "warmed", what="warmed")
    rec["vmAfter"] = vm()
    return rec

result = {"idleSeconds": IDLE, "speechSeconds": SPEECH, "hogGB": HOG_GB, "order": ORDER, "start": time.strftime("%H:%M:%S")}
lanes = {name: Lane(name) for name in ORDER}
for lane in lanes.values():
    result[lane.name + "Ready"] = lane.wait(lambda o: o.get("event") == "ready", timeout=300, what="ready")
    log(lane.name, "ready")
    lane.send({"id": "steady", "path": WAV})
    result[lane.name + "Steady"] = lane.wait(lambda o: o.get("id") == "steady", what="steady")
    log(lane.name, "steady take done")
last_run = time.monotonic()
hog = subprocess.Popen([HOG, HOG_GB, str(int(IDLE + 120))], stdout=subprocess.PIPE, text=True) if float(HOG_GB) > 0 else None
samples, aborted = [], None
while time.monotonic() - last_run < IDLE:
    v = vm(); v["t"] = round(time.monotonic() - last_run)
    v["rssMB"] = {n: rss_mb(l.p.pid) for n, l in lanes.items()}
    samples.append(v); log("idle", v)
    if v["vmFreeGiB"] * 2**30 < MIN_FREE:
        aborted = "swap volume below 8 GiB free"
        if hog: hog.send_signal(signal.SIGTERM)
        break
    time.sleep(10)
result["idleSamples"] = samples
result["takes"] = [take(lanes[name], warm=name.startswith("after")) for name in ORDER] if not aborted else []
result["aborted"] = aborted
if hog: hog.send_signal(signal.SIGTERM); hog.wait(timeout=60)
for lane in lanes.values(): lane.close()
with open(OUT, "a") as f: f.write(json.dumps(result) + "\n")
for t in result["takes"]:
    print(t["lane"], "wait", t["keyUpToTextSeconds"], "take wall", round(t["take"]["wallSeconds"], 3),
          "engine", round(t["take"]["engineSeconds"], 3), "warm", t.get("warmed", {}).get("seconds"),
          "rssBefore", t["rssMBBefore"])
print("aborted", aborted)
