#!/usr/bin/env python3
"""Transcribe audio files with OpenRamble: one normalized JSON per file.

    transcribe.py AUDIO... --out DIR [--backend cli|server] [--cli PATH]

Backends, in this order unless --backend names one:
  cli     the local `openramble` command (macOS app, or the Linux build of apps/cli);
  server  an OpenRamble server, only when OPENRAMBLE_SERVER (its base URL) and
          OPENRAMBLE_SERVER_KEY are set. Audio goes to that server and nowhere else.

Each DIR/<stem>.json is {"schemaVersion":1, "audio", "asr", "duration", "words":[{text,start,end}]}
(or "segments" from the Linux CLI, which has no word times). A file that is already
there is skipped, so a rerun redoes only what failed. Waits as long as the job takes;
transcript text is never printed.

The macOS CLI gets every file in one run, so the model loads once. The Linux CLI
has no word times, so its pieces are its only times: left alone it cuts fixed
windows from 0 s, and a piece starts up to 20 s before the speech in it. So each
file first gets its speech spans, where it has sound above its own noise floor
(on a participant's track: where that person talks), and the CLI transcribes
exactly those (--segments), one run per file. A piece then starts with the
speech, one turn is not glued to the next, and silence is never transcribed.
"""
import argparse
import array
import concurrent.futures
import json
import math
import operator
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import wave
from pathlib import Path

CLI_PATHS = ["~/.local/bin/openramble", "/Applications/OpenRamble.app/Contents/MacOS/openramble-cli"]
SERVER_PARALLEL = 4
DEADLINE_S = 14400
RETRIES = 4
VAD_RATE = 4000      # Hz; speech energy is well below 2 kHz
FRAME_S = 0.02       # the Linux CLI's frame
SPAN_GAP = 0.8       # quieter than this between two sounds keeps them in one span
SPAN_PAD = 0.6       # seconds on each side: soft onsets and trailing words stay in (measured on the samples)


class Fail(Exception):
    pass


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# ------------------------------------------------------------------ common

def duration_of(path):
    """Seconds of audio, from the file itself when a local tool can tell; None otherwise."""
    p = str(path)
    if p.lower().endswith(".wav"):
        try:
            with wave.open(p) as w:
                return w.getnframes() / float(w.getframerate())
        except (wave.Error, OSError, EOFError):
            pass
    for cmd in (["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", p],
                ["afinfo", p]):
        if not shutil.which(cmd[0]):
            continue
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        for line in out.splitlines():
            line = line.strip()
            if cmd[0] == "afinfo" and "estimated duration:" in line:
                line = line.split("estimated duration:")[1].split()[0]
            try:
                return float(line)
            except ValueError:
                continue
    return None


def write_normalized(out_dir, audio, asr, raw):
    doc = {"schemaVersion": 1, "audio": str(Path(audio).resolve()), "asr": asr}
    if raw.get("words") is not None:
        words = []
        for w in raw["words"]:
            if w.get("type", "word") != "word":
                continue
            text = str(w.get("text", "")).strip()
            if text:
                words.append({"text": text, "start": float(w["start"]), "end": float(w["end"])})
        doc["words"] = words
        last = max([w["end"] for w in words] or [0])
    else:
        doc["segments"] = raw.get("segments") or []
        last = max([float(s["end"]) for s in doc["segments"]] or [0])
    doc["duration"] = float(raw.get("duration") or duration_of(audio) or last)
    target = Path(out_dir) / (Path(audio).stem + ".json")
    tmp = target.with_suffix(".json.part")
    tmp.write_text(json.dumps(doc, ensure_ascii=False) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(target)
    n = len(doc["words"] if "words" in doc else doc["segments"])  # zero for someone who never spoke
    log(f"ok {Path(audio).name} -> {target} ({n} {'words' if 'words' in doc else 'pieces'}, {doc['duration']:.0f} s)")
    return target


# ------------------------------------------------------------------ local CLI

def find_cli(explicit):
    if explicit:
        return explicit
    for c in [shutil.which("openramble")] + [os.path.expanduser(p) for p in CLI_PATHS]:
        if c and os.access(c, os.X_OK):
            return c
    return None


def cli_asr(cli):
    real = Path(os.path.realpath(cli))
    for parent in real.parents:
        if parent.suffix == ".app":
            try:
                info = plistlib.loads((parent / "Contents/Info.plist").read_bytes())
                return f"OpenRamble {info.get('CFBundleShortVersionString', '')} (Parakeet)".replace("  ", " ")
            except (OSError, plistlib.InvalidFileException):
                break
    return "OpenRamble command-line tool"


def takes_spans(cli):
    """The Linux CLI transcribes given spans (--segments); the macOS CLI has word times and no such option."""
    try:
        r = subprocess.run([cli, "--help"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return "--segments" in r.stdout + r.stderr


def speech_spans(path):
    """[{start, end}] where the file has sound above its own noise floor, by the Linux CLI's own test
    (a 20 ms frame is voiced above 3x the quietest fifth, and at least 0.003); None without ffmpeg."""
    if not shutil.which("ffmpeg"):
        return None
    proc = subprocess.Popen(["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-vn", "-ac", "1",
                             "-ar", str(VAD_RATE), "-f", "s16le", "-"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    n = round(VAD_RATE * FRAME_S)
    rms, rest = array.array("f"), b""
    while True:
        chunk = proc.stdout.read(1 << 20)
        if not chunk:
            break
        data = rest + chunk
        cut = len(data) - len(data) % (2 * n)
        frames, rest = array.array("h", data[:cut]), data[cut:]
        if sys.byteorder == "big":
            frames.byteswap()
        for i in range(0, len(frames), n):
            f = frames[i:i + n]
            rms.append(math.sqrt(sum(map(operator.mul, f, f)) / n) / 32768)
    if proc.wait() != 0:
        return None
    if not rms:
        return []
    voiced = max(sorted(rms)[len(rms) // 5] * 3, 0.003)
    runs = []  # [first frame, last frame, voiced frames]
    for k, r in enumerate(rms):
        if r > voiced:
            if runs and (k - runs[-1][1]) * FRAME_S <= SPAN_GAP:
                runs[-1][1:] = [k, runs[-1][2] + 1]
            else:
                runs.append([k, k, 1])
    end, spans = len(rms) * FRAME_S, []
    for a, b, v in runs:
        if v < 10:  # under 0.2 s of sound: a click, a breath
            continue
        a, b = max(0.0, a * FRAME_S - SPAN_PAD), min(end, (b + 1) * FRAME_S + SPAN_PAD)
        if spans and a <= spans[-1]["end"]:
            spans[-1]["end"] = round(b, 2)
        else:
            spans.append({"start": round(a, 2), "end": round(b, 2)})
    return spans


PROGRESS = re.compile(r"^Transcribing\b(?: (\d+/\d+):)?")


def run_quiet(cmd):
    """Run the CLI with its progress cut to one line per file. It prints a line per few percent (macOS) or
    rewrites one with \\r (Linux), and "Saved:" lines name a temporary folder: none of it helps whoever waits.
    Other lines, such as errors, pass through. stdout is dropped, so no transcript text can reach the log."""
    shown, rest = set(), b""

    def say(raw):
        line = raw.decode("utf-8", "replace").strip()
        m = PROGRESS.match(line)
        if m:
            if m.group(1) and m.group(1) not in shown:
                shown.add(m.group(1))
                log(f"transcribing {m.group(1)}")
        elif line and not line.startswith(("Saved: ", "wrote ")):
            log(line)

    with subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) as proc:
        for chunk in iter(lambda: proc.stderr.read1(4096), b""):
            *lines, rest = re.split(rb"[\r\n]", rest + chunk)
            for line in lines:
                say(line)
        say(rest)
    return proc.returncode


def run_cli(cli, files, out_dir):
    check = subprocess.run([cli, "--check-model"], capture_output=True, text=True)
    if check.returncode != 0:
        raise Fail(f"the OpenRamble model is not ready: {(check.stderr or check.stdout).strip()}\n"
                   "Install or repair it in OpenRamble Settings; do not download another model.")
    asr = cli_asr(cli)
    # absolute paths never start with "-", and the Linux build has no "--"
    paths = [str(Path(f).resolve()) for f in files]
    with tempfile.TemporaryDirectory(dir=out_dir, prefix=".raw-") as raw_dir:
        codes = []
        if takes_spans(cli):
            for f, path in zip(files, paths):  # --segments applies to a whole run: one run per file
                spans = speech_spans(f)
                if spans is None:
                    raise Fail(f"{Path(f).name}: cannot read its audio with ffmpeg, which the Linux CLI needs too")
                spans_file = Path(raw_dir) / (Path(f).stem + ".spans.json")
                spans_file.write_text(json.dumps(spans), encoding="utf-8")
                log(f"{Path(f).name}: {len(spans)} speech spans, {sum(s['end'] - s['start'] for s in spans):.0f} s")
                codes.append(run_quiet([cli, "--format", "json", "--output-dir", raw_dir,
                                        "--segments", str(spans_file), path]))
        else:
            # one run for every file, so the model loads once
            codes.append(run_quiet([cli, "--format", "json", "--output-dir", raw_dir] + paths))
        failed = []
        for f in files:
            raw = Path(raw_dir) / (Path(f).stem + ".json")
            if not raw.exists():
                failed.append(f)
                continue
            data = json.loads(raw.read_text(encoding="utf-8"))
            write_normalized(out_dir, f, asr if data.get("words") is not None else
                             "OpenRamble command-line tool (Linux)" + (f", {data['model']}" if data.get("model") else ""),
                             data)
    if failed:
        raise Fail(f"the CLI exited {max(codes, key=abs)}; not transcribed: " + ", ".join(Path(f).name for f in failed))


# ------------------------------------------------------------------ OpenRamble server

def post_server(url, key, path):
    query = urllib.parse.urlencode({"timestamps_granularity": "word", "diarize": "false", "deadline_s": DEADLINE_S})
    endpoint = url.rstrip("/") + "/v1/speech-to-text?" + query
    size = os.path.getsize(path)
    for attempt in range(1, RETRIES + 1):
        try:
            with open(path, "rb") as body:
                req = urllib.request.Request(endpoint, data=body, method="POST", headers={
                    "xi-api-key": key, "Content-Type": "application/octet-stream", "Content-Length": str(size)})
                with urllib.request.urlopen(req, timeout=DEADLINE_S + 120) as resp:
                    return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            try:
                detail = json.loads(e.read().decode("utf-8")).get("detail", {})
            except (ValueError, AttributeError):
                detail = {}
            message = detail.get("message") or e.reason
            if e.code == 429 and attempt < RETRIES:
                wait = float(e.headers.get("Retry-After") or 30)
                log(f"busy: {Path(path).name} waits {wait:.0f} s ({detail.get('code', '')})")
                time.sleep(min(wait, 900))
                continue
            if e.code >= 500 and attempt < RETRIES:
                time.sleep(10 * attempt)
                continue
            raise Fail(f"{Path(path).name}: server said {e.code} {detail.get('code', '')}: {message}")
        except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
            if attempt < RETRIES:
                time.sleep(10 * attempt)
                continue
            raise Fail(f"{Path(path).name}: cannot reach the server ({e})")
    raise Fail(f"{Path(path).name}: the server stayed busy")


def run_server(url, key, files, out_dir):
    def one(f):
        return write_normalized(out_dir, f, "OpenRamble server (Parakeet)", post_server(url, key, f))
    errors = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=SERVER_PARALLEL) as pool:
        for f, fut in [(f, pool.submit(one, f)) for f in files]:
            try:
                fut.result()
            except Fail as e:
                errors.append(str(e))
    if errors:
        raise Fail("; ".join(errors))


# ------------------------------------------------------------------ main

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("audio", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--backend", choices=["cli", "server"])
    ap.add_argument("--cli", help="path to the openramble command")
    a = ap.parse_args(argv)
    files = [Path(f) for f in a.audio]
    missing = [str(f) for f in files if not f.is_file()]
    if missing:
        log("error: not found: " + ", ".join(missing))
        return 1
    stems = [f.stem for f in files]
    dupes = sorted({s for s in stems if stems.count(s) > 1})
    if dupes:
        log("error: two inputs share a name, so their outputs would collide: " + ", ".join(dupes)
            + ". Run them into separate --out folders.")
        return 1
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    todo = [f for f in files if not (out / (f.stem + ".json")).exists()]
    for f in files:
        if f not in todo:
            log(f"skip {f.name}: {out / (f.stem + '.json')} exists")
    if not todo:
        return 0
    url, key = os.environ.get("OPENRAMBLE_SERVER"), os.environ.get("OPENRAMBLE_SERVER_KEY")
    cli = find_cli(a.cli)
    backend = a.backend or ("cli" if cli else "server" if url and key else None)
    try:
        if backend == "cli":
            if not cli:
                raise Fail("no openramble command found (PATH, ~/.local/bin, /Applications/OpenRamble.app)")
            run_cli(cli, todo, out)
        elif backend == "server":
            if not (url and key):
                raise Fail("set OPENRAMBLE_SERVER (base URL) and OPENRAMBLE_SERVER_KEY to use a server")
            run_server(url, key, todo, out)
        else:
            raise Fail("no transcription backend: install the openramble command, "
                       "or set OPENRAMBLE_SERVER and OPENRAMBLE_SERVER_KEY for your own OpenRamble server")
    except Fail as e:
        log(f"error: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
