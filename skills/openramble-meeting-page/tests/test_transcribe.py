"""transcribe.py tests against a fake CLI and a local fake server: python3 -m unittest discover -s skills/openramble-meeting-page/tests"""
import array
import http.server
import io
import json
import math
import os
import shutil
import stat
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
import wave
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import transcribe  # noqa: E402

FAKE_CLI = """#!/bin/sh
echo "$@" >> "$(dirname "$0")/calls.txt"
if [ "$1" = "--check-model" ]; then exit 0; fi
out=""; prev=""
for a in "$@"; do
  if [ "$prev" = "--output-dir" ]; then out="$a"; fi
  prev="$a"
done
i=0
for a in "$@"; do
  case "$a" in
    *.m4a) i=$((i+1)); n=$(basename "$a" .m4a)
           for p in 5 10 15 50 100; do printf 'Transcribing %s/2: %s%%\n' "$i" "$p" >&2; done
           [ "$n" = "broken" ] && continue
           echo "Saved: $out/$n.json" >&2
           [ "$n" = "quiet" ] && { printf '{"schemaVersion":1,"text":"","duration":3.0,"words":[]}' > "$out/$n.json"; continue; }
           printf '{"schemaVersion":1,"text":"Hi.","duration":3.0,"words":[{"text":"Hi.","start":0.5,"end":0.9}]}' > "$out/$n.json";;
  esac
done
"""


# the Linux build: --segments in its help, pieces without word times, one piece per given span
FAKE_LINUX_CLI = """#!/bin/sh
echo "$@" >> "$(dirname "$0")/calls.txt"
if [ "$1" = "--help" ]; then echo "  --segments FILE  transcribe only these spans" >&2; exit 2; fi
if [ "$1" = "--check-model" ]; then exit 0; fi
out=""; spans=""; prev=""
for a in "$@"; do
  [ "$prev" = "--output-dir" ] && out="$a"
  [ "$prev" = "--segments" ] && spans="$a"
  prev="$a"
done
for a in "$@"; do last="$a"; done
n=$(basename "$last" .wav)
python3 -c "import json,sys; s=json.load(open(sys.argv[1])); json.dump({'model':'m','duration':10.0,
  'segments':[dict(x, label=None, text='piece') for x in s]}, open(sys.argv[2],'w'))" "$spans" "$out/$n.json"
"""


def tone_wav(path, bursts, seconds=10.0, rate=16000):
    """A track that is silent except for 220 Hz bursts at the given (start, end) seconds."""
    frames = array.array("h", [0] * int(seconds * rate))
    for a, b in bursts:
        for i in range(int(a * rate), int(b * rate)):
            frames[i] = int(9000 * math.sin(2 * math.pi * 220 * i / rate))
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(frames.tobytes())
    return path


class Server(http.server.BaseHTTPRequestHandler):
    seen, busy_once, active, peak, lock = [], set(), 0, 0, threading.Lock()

    def do_POST(self):
        cls = type(self)
        with cls.lock:
            cls.active += 1
            cls.peak = max(cls.peak, cls.active)
        body = self.rfile.read(int(self.headers["Content-Length"]))
        query = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(self.path).query))
        cls.seen.append({"path": urllib.parse.urlparse(self.path).path, "query": query,
                         "key": self.headers.get("xi-api-key"), "body": body})
        time.sleep(0.2)
        with cls.lock:
            cls.active -= 1
        if self.headers.get("xi-api-key") != "secret":
            return self.reply(401, {"detail": {"status": "invalid_api_key", "code": "invalid_api_key", "message": "no"}})
        if body == b"busy" and body not in cls.busy_once:
            cls.busy_once.add(body)
            return self.reply(429, {"detail": {"code": "system_busy", "message": "busy"}}, {"Retry-After": "0"})
        self.reply(200, {"text": "Привет, мир.", "words": [
            {"text": "Привет,", "start": 0.12, "end": 0.48, "type": "word", "speaker_id": None},
            {"text": " ", "start": 0.48, "end": 0.52, "type": "spacing", "speaker_id": None},
            {"text": "мир.", "start": 0.52, "end": 0.9, "type": "word", "speaker_id": None}]})

    def reply(self, code, obj, headers=None):
        data = json.dumps(obj).encode()
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class TranscribeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def audio(self, name, data=b"audio"):
        p = self.dir / name
        p.write_bytes(data)
        return p

    def test_local_cli_one_run_for_all_files(self):
        cli = self.dir / "openramble"
        cli.write_text(FAKE_CLI)
        cli.chmod(cli.stat().st_mode | stat.S_IEXEC)
        files = [self.audio("audioAnnaBelova1.m4a"), self.audio("audioDima2.m4a")]
        out = self.dir / "asr"
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            self.assertEqual(transcribe.main([str(f) for f in files] + ["--out", str(out), "--cli", str(cli)]), 0)
        # the CLI's percent-by-percent progress becomes one line per file, and no temporary paths
        said = err.getvalue().splitlines()
        self.assertEqual([l for l in said if l.startswith("transcribing")], ["transcribing 1/2", "transcribing 2/2"])
        self.assertFalse(any("%" in l or "Saved:" in l for l in said), said)
        self.assertEqual(len(said), 4, said)
        calls = (self.dir / "calls.txt").read_text().splitlines()
        self.assertEqual(calls[:2], ["--check-model", "--help"])
        self.assertEqual(len(calls), 3)
        self.assertIn("--format json --output-dir", calls[2])
        doc = json.loads((out / "audioAnnaBelova1.json").read_text())
        self.assertEqual(doc["words"], [{"text": "Hi.", "start": 0.5, "end": 0.9}])
        self.assertEqual(doc["audio"], str(files[0].resolve()))
        self.assertEqual(oct((out / "audioDima2.json").stat().st_mode & 0o777), "0o600")
        # a rerun skips finished files and only the failed one is tried again
        broken = self.audio("broken.m4a")
        self.assertEqual(transcribe.main([str(f) for f in files + [broken]] + ["--out", str(out), "--cli", str(cli)]), 1)
        last = (self.dir / "calls.txt").read_text().splitlines()[-1]
        self.assertTrue(last.endswith("broken.m4a"))
        self.assertNotIn("audioDima2", last)
        # someone who never spoke has a silent track: no words is a result, not a crash
        quiet = self.audio("quiet.m4a")
        self.assertEqual(transcribe.main([str(quiet), "--out", str(out), "--cli", str(cli)]), 0)
        self.assertEqual(json.loads((out / "quiet.json").read_text())["words"], [])

    @unittest.skipUnless(shutil.which("ffmpeg"), "needs ffmpeg, as the Linux CLI does")
    def test_linux_cli_transcribes_speech_spans_one_run_per_file(self):
        cli = self.dir / "openramble"
        cli.write_text(FAKE_LINUX_CLI)
        cli.chmod(cli.stat().st_mode | stat.S_IEXEC)
        anna = tone_wav(self.dir / "audio-anna.wav", [(1.0, 2.5), (6.0, 6.6)])
        dima = tone_wav(self.dir / "audio-dima.wav", [(3.0, 5.0), (8.0, 8.1)])  # the 0.1 s click is not speech
        out = self.dir / "asr"
        self.assertEqual(transcribe.main([str(anna), str(dima), "--out", str(out), "--cli", str(cli)]), 0)
        runs = [c for c in (self.dir / "calls.txt").read_text().splitlines() if c.startswith("--format")]
        self.assertEqual(len(runs), 2)
        self.assertTrue(all("--segments" in c for c in runs))
        spans = lambda name: [(s["start"], s["end"]) for s in json.loads((out / name).read_text())["segments"]]
        for got, want in ((spans("audio-anna.json"), [(0.4, 3.1), (5.4, 7.2)]),
                          (spans("audio-dima.json"), [(2.4, 5.6)])):
            self.assertEqual(len(got), len(want), got)
            for (a, b), (x, y) in zip(got, want):
                self.assertAlmostEqual(a, x, delta=0.05)
                self.assertAlmostEqual(b, y, delta=0.05)

    def test_server_api_parallel_limit_and_retry(self):
        Server.seen, Server.busy_once, Server.peak = [], set(), 0
        httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Server)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        try:
            files = [self.audio(f"track{i}.m4a", f"audio{i}".encode()) for i in range(6)] + [self.audio("q.m4a", b"busy")]
            env = {"OPENRAMBLE_SERVER": f"http://127.0.0.1:{httpd.server_port}/", "OPENRAMBLE_SERVER_KEY": "secret"}
            with mock.patch.dict(os.environ, env), mock.patch.object(transcribe, "find_cli", return_value=None):
                code = transcribe.main([str(f) for f in files] + ["--out", str(self.dir / "asr")])
            self.assertEqual(code, 0)
            self.assertLessEqual(Server.peak, 4)
            self.assertEqual(len(Server.seen), 8)  # seven files, one of them retried after 429
            first = Server.seen[0]
            self.assertEqual(first["path"], "/v1/speech-to-text")
            self.assertEqual(first["key"], "secret")
            self.assertEqual(first["query"], {"timestamps_granularity": "word", "diarize": "false", "deadline_s": "14400"})
            self.assertEqual({s["body"] for s in Server.seen}, {f"audio{i}".encode() for i in range(6)} | {b"busy"})
            doc = json.loads((self.dir / "asr" / "track3.json").read_text())
            self.assertEqual([w["text"] for w in doc["words"]], ["Привет,", "мир."])
            with mock.patch.dict(os.environ, dict(env, OPENRAMBLE_SERVER_KEY="wrong")), \
                    mock.patch.object(transcribe, "find_cli", return_value=None):
                self.assertEqual(transcribe.main([str(self.audio("x.m4a"))] + ["--out", str(self.dir / "asr2")]), 1)
        finally:
            httpd.shutdown()

    def test_no_backend_and_duplicate_names(self):
        a = self.audio("a.m4a")
        sub = self.dir / "sub"
        sub.mkdir()
        b = sub / "a.m4a"
        b.write_bytes(b"x")
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(transcribe, "find_cli", return_value=None):
            self.assertEqual(transcribe.main([str(a), "--out", str(self.dir / "o")]), 1)
            self.assertEqual(transcribe.main([str(a), str(b), "--out", str(self.dir / "o")]), 1)


if __name__ == "__main__":
    unittest.main()
