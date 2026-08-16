#!/usr/bin/env python3
"""Protocol-only smoke test for the private ASR child.

This deliberately does not load model files. It proves that the exact helper
inside an artifact starts, speaks the bounded binary protocol, authenticates
its parent pipe, and exits when commanded without publishing a socket/service.
"""

from __future__ import annotations

import json
import os
import select
import struct
import subprocess
import sys
import time


MAGIC = b"ORAS"
VERSION = 2
HEADER = struct.Struct(">4sHHQIQ")
HELLO = 1
HELLO_ACKNOWLEDGED = 2
SHUTDOWN = 11
MAX_METADATA = 4 * 1024 * 1024
MAX_PAYLOAD = 5 * 60 * 16_000 * 4


def frame(kind: int, request_id: int, metadata: object, payload: bytes = b"") -> bytes:
    encoded = json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode()
    return HEADER.pack(MAGIC, VERSION, kind, request_id, len(encoded), len(payload)) + encoded + payload


def read_exact(stream: object, size: int) -> bytes:
    chunks = bytearray()
    deadline = time.monotonic() + 5
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


def read_frame(stream: object) -> tuple[int, int, dict[str, object], bytes]:
    magic, version, kind, request_id, metadata_size, payload_size = HEADER.unpack(
        read_exact(stream, HEADER.size)
    )
    if magic != MAGIC or version != VERSION:
        raise RuntimeError("worker returned an incompatible protocol header")
    if metadata_size > MAX_METADATA or payload_size > MAX_PAYLOAD:
        raise RuntimeError("worker returned an unbounded protocol frame")
    metadata = json.loads(read_exact(stream, metadata_size))
    payload = read_exact(stream, payload_size)
    return kind, request_id, metadata, payload


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: test-asr-worker.py /path/to/openramble-asr-worker", file=sys.stderr)
        return 2

    helper = os.path.abspath(sys.argv[1])
    process = subprocess.Popen(
        [helper],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdin is not None
    assert process.stdout is not None

    try:
        request_id = 0xC0DEC0DE
        process.stdin.write(
            frame(
                HELLO,
                request_id,
                {
                    "appBuild": "artifact-smoke",
                    "parentProcessIdentifier": os.getpid(),
                    "protocolVersion": VERSION,
                },
            )
        )
        process.stdin.flush()
        kind, response_id, metadata, payload = read_frame(process.stdout)
        if kind != HELLO_ACKNOWLEDGED or response_id != request_id or payload:
            raise RuntimeError("worker returned an invalid handshake response")
        if metadata.get("protocolVersion") != VERSION:
            raise RuntimeError("worker acknowledged the wrong protocol version")
        if metadata.get("workerProcessIdentifier") != process.pid:
            raise RuntimeError("worker acknowledged the wrong process identifier")

        process.stdin.write(frame(SHUTDOWN, request_id + 1, {}))
        process.stdin.flush()
        process.stdin.close()
        return_code = process.wait(timeout=5)
        if return_code != 0:
            raise RuntimeError(f"worker exited with status {return_code}")
    except BaseException:
        process.kill()
        process.wait(timeout=5)
        raise

    print(f"ASR worker protocol smoke: handshake and shutdown OK (pid {process.pid}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
