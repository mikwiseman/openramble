"""Run one exclusive, resumable benchmark lane. Uses only public fixture paths."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("suite", choices=["smoke", "controller", "file", "meeting", "long"])
parser.add_argument("--data", required=True, type=Path)
parser.add_argument("--out", required=True, type=Path)
parser.add_argument("--model", required=True, type=Path)
parser.add_argument("--repeats", type=int)
parser.add_argument("--max-workers", type=int, choices=[1, 2, 4], default=4)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
for name in ("configs", "raw", "logs", "scratch", "failed-attempts"):
    (out / name).mkdir(exist_ok=True)
fixtures = json.loads((args.data / "mini-inputs.json").read_text())["fixtures"]
fixture_map = {f["id"]: f for f in fixtures}
model = next(args.model.glob("*.gguf"))
assert hashlib.file_digest(model.open("rb"), "sha256").hexdigest() == "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7"
bundle = repo / "Packages/LocalASR/.build/arm64-apple-macosx/release/LocalASRPackageTests.xctest"
binary = bundle / "Contents/MacOS/LocalASRPackageTests"
identity = {"head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
            "binary_sha256": hashlib.file_digest(binary.open("rb"), "sha256").hexdigest(),
            "runner_sha256": hashlib.file_digest(Path(__file__).open("rb"), "sha256").hexdigest(),
            "harness_sha256": hashlib.file_digest((repo / "Packages/LocalASR/Tests/LocalASRTests/ProductBenchmarkTests.swift").open("rb"), "sha256").hexdigest(),
            "input_manifest_sha256": hashlib.file_digest((args.data / "mini-inputs.json").open("rb"), "sha256").hexdigest(),
            "model_sha256": hashlib.file_digest(model.open("rb"), "sha256").hexdigest()}
identity_path = out / "identity.json"
if identity_path.exists():
    assert json.loads(identity_path.read_text()) == identity, "changed run identity; choose a new output directory"
else:
    identity_path.write_text(json.dumps(identity, indent=2) + "\n")

jobs = []
def add(fixture, mode, pacing, workers, condition, repeat):
    jobs.append({"fixture": fixture, "mode": mode, "pacing": pacing, "workers": workers,
                 "condition": condition, "repeat": repeat})

if args.suite == "smoke":
    for name in ("ru-short", "en-short", "ru-60s", "en-60s", "ru-360s"):
        add(name, "controller", "settled", 1, "normal", 0)
    for workers in (1, 2, 4):
        add("en-60s", "file", "settled", workers, "normal", 0)
    add("en-60s", "shipping-file", "settled", 1, "normal", 0)
    add("ru-60s", "meeting", "settled", 1, "normal", 0)
elif args.suite == "controller":
    for repeat in range(args.repeats or 20):
        conditions = ["normal", "cpu10"] if repeat % 2 == 0 else ["cpu10", "normal"]
        names = ["ru-short", "en-short", "ru-60s", "en-60s"]
        names = names[repeat % 4:] + names[:repeat % 4]
        for condition in conditions:
            for name in names:
                add(name, "controller", "realtime", 1, condition, repeat)
elif args.suite == "file":
    for repeat in range(args.repeats or 3):
        workers = [1, 2, 4]
        workers = workers[repeat % 3:] + workers[:repeat % 3]
        for name in ("ru-3540s", "en-3540s", "mixed-3540s"):
            for count in workers:
                add(name, "file", "settled", count, "normal", repeat)
    for name in ("ru-3540s", "en-3540s", "mixed-3540s"):
        add(name, "shipping-file", "settled", 1, "normal", 0)
elif args.suite == "meeting":
    for repeat in range(args.repeats or 20):
        for condition in (["normal", "cpu10"] if repeat % 2 == 0 else ["cpu10", "normal"]):
            for name in ("ru-60s", "en-60s"):
                add(name, "meeting", "settled", 1, condition, repeat)
else:
    for repeat in range(args.repeats or 5):
        for condition in ("normal", "cpu10"):
            for name in ("ru-360s", "en-360s"):
                for pacing in ("settled", "burst"):
                    add(name, "controller", pacing, 1, condition, repeat)

jobs = [job for job in jobs if job["workers"] <= args.max_workers]
(out / f"plan-{args.suite}.json").write_text(json.dumps(jobs, indent=2) + "\n")

def command(*words):
    return subprocess.run(words, capture_output=True, text=True).stdout.strip()

def builds():
    names = {"swift-frontend", "swift-build", "rustc", "clang", "clang++", "xcodebuild", "cargo"}
    return sorted({Path(line.strip()).name for line in command("ps", "-axo", "comm").splitlines()
                   if Path(line.strip()).name in names})

def snapshot():
    return {"utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "load": os.getloadavg(), "swap": command("sysctl", "-n", "vm.swapusage"),
            "pressure": command("sysctl", "-n", "kern.memorystatus_vm_pressure_level"),
            "thermal": command("pmset", "-g", "therm"),
            "processes": command("ps", "-axo", "pid,ppid,%cpu,rss,etime,comm")}

# Darwin's documented rusage_info_v0 includes physical footprint, unlike
# getrusage's resident-set peak. Samples include model loading and warmup.
class RUsageInfo(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in
        ("user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins",
         "wired_size", "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime")]

libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
libproc.proc_pid_rusage.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_void_p)
libproc.proc_pid_rusage.restype = ctypes.c_int

def memory(pid):
    usage = RUsageInfo()
    if libproc.proc_pid_rusage(pid, 0, ctypes.byref(usage)) != 0:
        return None
    return {"residentBytes": usage.resident_size, "physicalFootprintBytes": usage.phys_footprint}

finished = set()
if (out / "observations.jsonl").exists():
    for line in (out / "observations.jsonl").read_text().splitlines():
        previous = json.loads(line)
        if previous.get("exit_code") == 0 and "hard_stop" not in previous:
            finished.add(previous["id"])

owned = []
active = None
def stop_owned():
    for process in owned:
        if process.poll() is None: process.terminate()
    for process in owned:
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
    owned.clear()

def interrupted(sig, frame):
    if active is not None and active.poll() is None:
        active.terminate()
    stop_owned()
    raise SystemExit(128 + sig)

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
try:
    for index, job in enumerate(jobs):
        identifier = "-".join(str(job[k]) for k in ("mode", "fixture", "pacing", "workers", "condition", "repeat"))
        result_path = out / "raw" / (identifier + ".json")
        if result_path.exists() and identifier in finished: continue
        waiting = 0
        while (busy := builds()) or command("sysctl", "-n", "kern.memorystatus_vm_pressure_level") not in ("", "1"):
            if waiting % 30 == 0:
                print("Waiting for builds/memory pressure to clear:", ", ".join(busy), flush=True)
            time.sleep(5)
            waiting += 5
            if waiting >= 900:
                raise SystemExit("No quiet memory/build interval in 15 minutes; no inference started")
        # A resumed job must not overwrite diagnostic evidence from failure.
        for previous in (result_path, out / "logs" / (identifier + ".log")):
            if previous.exists():
                stamp = str(time.time_ns())
                previous.rename(out / "failed-attempts" / (stamp + "-" + previous.name))
        fixture = fixture_map[job["fixture"]]
        assert hashlib.file_digest(Path(fixture["path"]).open("rb"), "sha256").hexdigest() == fixture["audio_sha256"]
        config = dict(id=identifier, input=fixture["path"], model=str(args.model.resolve()), output=str(result_path),
                      scratch=str(out / "scratch"), mode=job["mode"], pacing=job["pacing"], workers=job["workers"])
        config_path = out / "configs" / (identifier + ".json")
        config_path.write_text(json.dumps(config))
        before = snapshot()
        if job["condition"] == "cpu10":
            owned.extend(subprocess.Popen([sys.executable, "-c", "while True: pass"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for _ in range(10))
            time.sleep(2)
        record = {**job, "id": identifier, "before": before, "load_pids": [p.pid for p in owned]}
        record["under_condition"] = snapshot()
        env = dict(os.environ, OPENRAMBLE_PRODUCT_BENCHMARK_CONFIG=str(config_path))
        cmd = ["xcrun", "xctest", "-XCTest", "LocalASRTests.ProductBenchmarkTests/testPublicFixture", str(bundle)]
        print(f"[{index + 1}/{len(jobs)}] {identifier}", flush=True)
        start = time.monotonic()
        pressure = []
        with (out / "logs" / (identifier + ".log")).open("w") as log:
            active = subprocess.Popen(cmd, cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT)
            while active.poll() is None:
                value = command("sysctl", "-n", "kern.memorystatus_vm_pressure_level")
                busy = builds()
                pressure.append({"seconds": time.monotonic() - start, "level": value, "memory": memory(active.pid), "builds": busy})
                if busy:
                    active.terminate()
                    record["hard_stop"] = "build started during measurement"
                    break
                if value not in ("", "1"):
                    active.terminate()
                    record["hard_stop"] = "memory pressure"
                    break
                if time.monotonic() - start > 900:
                    active.terminate()
                    record["hard_stop"] = "timeout"
                    break
                time.sleep(1)
            try: code = active.wait(timeout=30)
            except subprocess.TimeoutExpired:
                active.kill(); code = active.wait()
        stop_owned()
        record.update(exit_code=code, process_seconds=time.monotonic() - start, pressure=pressure, after=snapshot())
        with (out / "observations.jsonl").open("a") as log:
            log.write(json.dumps(record) + "\n")
        if code != 0 or not result_path.exists():
            raise SystemExit(f"Hard stop: {identifier}; inspect its log. No failed run counted as speed.")
        result = json.loads(result_path.read_text())
        print("  seconds=", result.get("stopSeconds", result.get("processingSeconds")), "rss=", result["peakRSSBytes"], flush=True)
finally:
    stop_owned()
