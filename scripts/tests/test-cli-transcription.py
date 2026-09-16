#!/usr/bin/env python3
"""Exercise the packaged CLI, using a synthetic spoken fixture and real weights.

Run under the release smoke test's deny-network sandbox. No audio is uploaded.
"""
import argparse
import array
import fcntl
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import wave


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--audio", required=True)
    args = parser.parse_args()
    cli = str(Path(args.cli).resolve())

    def run(*arguments, code=0):
        result = subprocess.run([cli, *map(str, arguments)], capture_output=True, text=True, timeout=90)
        assert result.returncode == code, (result.returncode, result.stderr)
        return result

    with tempfile.TemporaryDirectory(prefix="OpenRamble CLI checks ") as directory:
        root = Path(directory)
        audio = root / "spoken fixture.wav"
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", args.audio, str(audio)], check=True)
        run("--check-model")
        text = run(audio).stdout.strip()
        assert text
        timed = json.loads(run(audio, "--format", "json").stdout)
        assert timed["text"] == text and timed["words"]
        previous = 0
        for word in timed["words"]:
            assert previous <= word["start"] <= word["end"] <= timed["duration"]
            previous = word["start"]
        assert " --> " in run(audio, "--format", "srt").stdout
        assert run(audio, "--format", "vtt").stdout.startswith("WEBVTT\n")

        with wave.open(str(audio), "rb") as source:
            frames = source.readframes(source.getnframes())
            rate = source.getframerate()
        mono = array.array("h", frames)
        stereo = array.array("h", (v for sample in mono for v in (0, sample)))
        right = root / "right only.wav"
        with wave.open(str(right), "wb") as target:
            target.setparams((2, 2, rate, 0, "NONE", "not compressed"))
            target.writeframes(stereo.tobytes())
        assert run(right).stdout.strip().lower() == text.lower(), "right channel speech was lost"

        broken = root / "broken.wav"
        broken.write_text("not audio")
        output = root / "separate results"
        mixed = run(audio, broken, audio, "--format", "json", "--output-dir", output, code=1)
        assert not mixed.stdout
        first = output / "spoken fixture.json"
        assert json.loads(first.read_text())["text"] == text
        assert (output / "spoken fixture-2.json").exists()
        assert not (output / "broken.json").exists()
        original = first.read_bytes()
        run(audio, "--format", "json", "--output-dir", output, code=1)
        assert first.read_bytes() == original
        assert not list(output.glob(".openramble-*.tmp"))

        long_audio = root / "long fixture.wav"
        with wave.open(str(long_audio), "wb") as target:
            target.setparams((1, 2, rate, 0, "NONE", "not compressed"))
            for _ in range(max(1, int(190 / timed["duration"]))):
                target.writeframes(frames)
        began = time.monotonic()
        baseline = run(long_audio, "--format", "json").stdout
        finish_budget = max(2, 2 * (time.monotonic() - began))
        lock = Path.home() / "Library/Application Support/OpenRamble/dictation-priority.lock"
        with lock.open("a+b") as priority, (root / "resumed.json").open("w+") as resumed:
            process = subprocess.Popen([cli, str(long_audio), "--format", "json"],
                                       stdout=resumed, stderr=subprocess.PIPE, text=True)
            try:
                assert "Transcribing" in process.stderr.readline()
                fcntl.lockf(priority, fcntl.LOCK_EX | fcntl.LOCK_NB, 1)
                # Longer than this entire job took without priority. stdout is
                # a file, so a full pipe cannot masquerade as a successful yield.
                time.sleep(finish_budget)
                assert process.poll() is None, "CLI did not yield to interactive dictation"
                fcntl.lockf(priority, fcntl.LOCK_UN, 1)
                _, error = process.communicate(timeout=90)
                assert process.returncode == 0, error
                resumed.seek(0)
                assert resumed.read() == baseline, "resume lost or repeated a fragment"
            finally:
                fcntl.lockf(priority, fcntl.LOCK_UN, 1)
                if process.poll() is None:
                    process.kill()
                    process.wait()

            fcntl.lockf(priority, fcntl.LOCK_EX | fcntl.LOCK_NB, 1)
            process = subprocess.Popen([cli, str(long_audio)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                time.sleep(0.2)
                process.send_signal(signal.SIGINT)
                result, error = process.communicate(timeout=3)
                assert process.returncode == 130 and not result, (process.returncode, error)
            finally:
                fcntl.lockf(priority, fcntl.LOCK_UN, 1)
                if process.poll() is None:
                    process.kill()
                    process.wait()
        interrupted = root / "interrupted"
        process = subprocess.Popen([cli, str(audio), str(long_audio), "--output-dir", str(interrupted)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            while True:
                line = process.stderr.readline()
                assert line, "CLI exited before the first file was saved"
                if line.startswith("Saved:"):
                    break
            process.send_signal(signal.SIGINT)
            result, error = process.communicate(timeout=10)
            assert process.returncode == 130 and not result, (process.returncode, error)
            assert (interrupted / "spoken fixture.txt").read_text().strip() == text
            assert not (interrupted / "long fixture.txt").exists()
            assert not list(interrupted.glob(".openramble-*.tmp"))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
        print("Packaged CLI: formats, stereo, partial failure, no overwrite, priority resume and cancellation passed.")


if __name__ == "__main__":
    main()
