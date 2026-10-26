"""transcribe.py tests against a fake CLI and a local fake server: python3 -m unittest discover -s skills/openramble-meeting-page/tests"""
import http.server
import json
import os
import stat
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
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
for a in "$@"; do
  case "$a" in
    *.m4a) n=$(basename "$a" .m4a); [ "$n" = "broken" ] && continue
           printf '{"schemaVersion":1,"text":"Hi.","duration":3.0,"words":[{"text":"Hi.","start":0.5,"end":0.9}]}' > "$out/$n.json";;
  esac
done
"""


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
        self.assertEqual(transcribe.main([str(f) for f in files] + ["--out", str(out), "--cli", str(cli)]), 0)
        calls = (self.dir / "calls.txt").read_text().splitlines()
        self.assertEqual(calls[0], "--check-model")
        self.assertEqual(len(calls), 2)
        self.assertIn("--format json --output-dir", calls[1])
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
