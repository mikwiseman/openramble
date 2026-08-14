#!/usr/bin/env python3
"""Exercise recognition through the exact private worker shipped in an app.

The caller is responsible for placing this process in a deny-network sandbox.
No transcript is printed: the synthetic expected phrase is compared in memory.
"""

from __future__ import annotations

import json
import math
import os
import re
import select
import struct
import subprocess
import sys
import time
from typing import BinaryIO


MAGIC = b"ORAS"
VERSION = 1
HEADER = struct.Struct(">4sHHQIQ")

HELLO = 1
HELLO_ACKNOWLEDGED = 2
PREPARE_MAIN = 3
WARM_INFERENCE = 5
TRANSCRIBE_FILE = 7
ACKNOWLEDGED = 8
RESULT = 9
FAILURE = 10
SHUTDOWN = 11

MAX_METADATA = 4 * 1024 * 1024
MAX_PAYLOAD = 5 * 60 * 16_000 * 4


def canonical_words(value: str) -> str:
    return " ".join(re.findall(r"\w+", value.casefold(), flags=re.UNICODE))


def frame(kind: int, request_id: int, metadata: object, payload: bytes = b"") -> bytes:
    encoded = json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode()
    return HEADER.pack(MAGIC, VERSION, kind, request_id, len(encoded), len(payload)) + encoded + payload


def read_exact(stream: BinaryIO, size: int, deadline: float) -> bytes:
    chunks = bytearray()
    descriptor = stream.fileno()
    while len(chunks) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([descriptor], [], [], remaining)[0]:
            raise RuntimeError("worker protocol response timed out")
        chunk = os.read(descriptor, size - len(chunks))
        if not chunk:
            raise RuntimeError(f"worker closed its protocol pipe after {len(chunks)}/{size} bytes")
        chunks.extend(chunk)
    return bytes(chunks)


def read_frame(stream: BinaryIO, timeout: float) -> tuple[int, int, dict[str, object], bytes]:
    deadline = time.monotonic() + timeout
    magic, version, kind, request_id, metadata_size, payload_size = HEADER.unpack(
        read_exact(stream, HEADER.size, deadline)
    )
    if magic != MAGIC or version != VERSION:
        raise RuntimeError("worker returned an incompatible protocol header")
    if metadata_size > MAX_METADATA or payload_size > MAX_PAYLOAD:
        raise RuntimeError("worker returned an unbounded protocol frame")
    metadata = json.loads(read_exact(stream, metadata_size, deadline))
    payload = read_exact(stream, payload_size, deadline)
    return kind, request_id, metadata, payload


def send(stream: BinaryIO, kind: int, request_id: int, metadata: object) -> None:
    stream.write(frame(kind, request_id, metadata))
    stream.flush()


def expect_response(
    stream: BinaryIO,
    expected_kind: int,
    expected_request_id: int,
    timeout: float,
) -> dict[str, object]:
    kind, request_id, metadata, payload = read_frame(stream, timeout)
    if kind == FAILURE:
        code = metadata.get("code", "unknown")
        raise RuntimeError(f"worker request failed with code {code}")
    if kind != expected_kind or request_id != expected_request_id or payload:
        raise RuntimeError("worker returned an unexpected protocol response")
    return metadata


def main() -> int:
    if len(sys.argv) != 5:
        print(
            "usage: packaged-worker-offline.py WORKER MODEL_DIRECTORY FIXTURE EXPECTED_TEXT",
            file=sys.stderr,
        )
        return 2

    worker = os.path.abspath(sys.argv[1])
    model_directory = os.path.abspath(sys.argv[2])
    fixture = os.path.abspath(sys.argv[3])
    expected = canonical_words(sys.argv[4])

    if not os.access(worker, os.X_OK):
        raise RuntimeError("packaged worker is missing or not executable")
    if not os.path.isdir(model_directory):
        raise RuntimeError("installed model directory is missing")
    if not os.path.isfile(fixture):
        raise RuntimeError("offline recognition fixture is missing")
    if not expected:
        raise RuntimeError("expected synthetic phrase is empty")

    process = subprocess.Popen(
        [worker],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        # Inherit stderr so worker diagnostics cannot fill an unread pipe and
        # deadlock the release gate during model loading or inference.
        stderr=None,
    )
    assert process.stdin is not None
    assert process.stdout is not None

    try:
        request_id = 0xA11CE000
        send(
            process.stdin,
            HELLO,
            request_id,
            {
                "appBuild": "packaged-offline-smoke",
                "parentProcessIdentifier": os.getpid(),
                "protocolVersion": VERSION,
            },
        )
        hello = expect_response(process.stdout, HELLO_ACKNOWLEDGED, request_id, 10)
        if hello.get("protocolVersion") != VERSION:
            raise RuntimeError("worker acknowledged the wrong protocol version")
        if hello.get("workerProcessIdentifier") != process.pid:
            raise RuntimeError("worker acknowledged the wrong process identifier")

        request_id += 1
        send(process.stdin, PREPARE_MAIN, request_id, {"modelDirectory": model_directory})
        expect_response(process.stdout, ACKNOWLEDGED, request_id, 180)

        request_id += 1
        send(process.stdin, WARM_INFERENCE, request_id, {})
        expect_response(process.stdout, ACKNOWLEDGED, request_id, 120)

        request_id += 1
        send(
            process.stdin,
            TRANSCRIBE_FILE,
            request_id,
            {"languageHint": "en", "path": fixture},
        )
        result = expect_response(process.stdout, RESULT, request_id, 120)
        recognized = canonical_words(str(result.get("text", "")))
        if expected not in recognized:
            raise RuntimeError("worker did not recognize the expected synthetic phrase")
        audio_duration = float(result.get("audioDuration", -1))
        processing_duration = float(result.get("processingDuration", -1))
        if not math.isfinite(audio_duration) or audio_duration <= 0:
            raise RuntimeError("worker returned an invalid audio duration")
        if not math.isfinite(processing_duration) or processing_duration < 0:
            raise RuntimeError("worker returned an invalid processing duration")

        request_id += 1
        send(process.stdin, SHUTDOWN, request_id, {})
        process.stdin.close()
        return_code = process.wait(timeout=10)
        if return_code != 0:
            raise RuntimeError(f"worker exited with status {return_code}")
    except BaseException:
        process.kill()
        process.wait(timeout=10)
        raise

    print("Packaged ASR worker recognized the synthetic fixture.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
