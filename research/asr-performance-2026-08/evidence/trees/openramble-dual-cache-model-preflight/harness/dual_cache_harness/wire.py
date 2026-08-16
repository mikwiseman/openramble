from __future__ import annotations

import asyncio
import enum
import io
import json
import struct
from dataclasses import dataclass
from typing import Any, BinaryIO, Mapping

from .schema import MAX_CACHE_INPUT_BYTES, MAX_FINAL_SAMPLES


MAGIC = b"DCHF"
VERSION = 2
HEADER = struct.Struct(">4sHHIQ")
MAX_METADATA_BYTES = 4 * 1024 * 1024
MAX_FINAL_PCM_BYTES = MAX_FINAL_SAMPLES * 4


class Kind(enum.IntEnum):
    HELLO = 1
    HELLO_ACK = 2
    SPECULATE = 3
    CACHE_RECORD = 4
    PREDICTION_STARTED = 5
    TRANSCRIBE = 6
    RESULT = 7
    FAILURE = 8
    SHUTDOWN = 9
    ACK = 10
    PING = 11
    PREPARE = 12
    MODEL_READY = 13
    PREDICTION_COMPLETED = 14
    TRACE_MARKER = 15
    PREPARE_STARTED = 16


PAYLOAD_CAPS = {
    Kind.HELLO: 0,
    Kind.HELLO_ACK: 0,
    Kind.SPECULATE: MAX_FINAL_PCM_BYTES,
    Kind.CACHE_RECORD: MAX_CACHE_INPUT_BYTES,
    Kind.PREDICTION_STARTED: 0,
    Kind.TRANSCRIBE: MAX_FINAL_PCM_BYTES,
    Kind.RESULT: 0,
    Kind.FAILURE: 0,
    Kind.SHUTDOWN: 0,
    Kind.ACK: 0,
    Kind.PING: 0,
    Kind.PREPARE: 0,
    Kind.MODEL_READY: 0,
    Kind.PREDICTION_COMPLETED: 0,
    Kind.TRACE_MARKER: 0,
    Kind.PREPARE_STARTED: 0,
}


class WireError(ValueError):
    pass


@dataclass(frozen=True)
class Frame:
    kind: Kind
    request_id: int
    metadata: bytes
    payload: bytes = b""

    @classmethod
    def json(
        cls,
        kind: Kind,
        request_id: int,
        metadata: Mapping[str, Any],
        payload: bytes = b"",
    ) -> "Frame":
        return cls(
            kind=kind,
            request_id=request_id,
            metadata=json.dumps(
                metadata,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8"),
            payload=payload,
        )

    def decoded_metadata(self) -> dict[str, Any]:
        value = json.loads(self.metadata)
        if not isinstance(value, dict):
            raise WireError("metadata must be a JSON object")
        return value


def _validate_counts(kind: Kind, metadata_count: int, payload_count: int) -> None:
    if metadata_count > MAX_METADATA_BYTES:
        raise WireError(f"metadata too large: {metadata_count}")
    maximum = PAYLOAD_CAPS[kind]
    if payload_count > maximum:
        raise WireError(f"payload too large for {kind.name}: {payload_count}>{maximum}")


def encode(frame: Frame) -> bytes:
    _validate_counts(frame.kind, len(frame.metadata), len(frame.payload))
    if not 0 <= frame.request_id <= 0xFFFF_FFFF:
        raise WireError("request id out of range")
    return (
        HEADER.pack(
            MAGIC,
            VERSION,
            int(frame.kind),
            frame.request_id,
            len(frame.payload),
        )
        + struct.pack(">I", len(frame.metadata))
        + frame.metadata
        + frame.payload
    )


def _decode_header(header: bytes, metadata_count_bytes: bytes) -> tuple[Kind, int, int, int]:
    magic, version, raw_kind, request_id, payload_count = HEADER.unpack(header)
    if magic != MAGIC:
        raise WireError("invalid magic")
    if version != VERSION:
        raise WireError(f"unsupported version {version}")
    try:
        kind = Kind(raw_kind)
    except ValueError as error:
        raise WireError(f"unknown kind {raw_kind}") from error
    metadata_count = struct.unpack(">I", metadata_count_bytes)[0]
    # Crucially this happens before either variable-size body is allocated.
    _validate_counts(kind, metadata_count, payload_count)
    return kind, request_id, metadata_count, payload_count


def _read_exact(stream: BinaryIO, count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < count:
        chunk = stream.read(count - len(chunks))
        if not chunk:
            raise EOFError("truncated frame")
        chunks.extend(chunk)
    return bytes(chunks)


def read_sync(stream: BinaryIO) -> Frame | None:
    header = stream.read(HEADER.size)
    if not header:
        return None
    if len(header) != HEADER.size:
        raise EOFError("truncated frame header")
    metadata_count_bytes = _read_exact(stream, 4)
    kind, request_id, metadata_count, payload_count = _decode_header(
        header, metadata_count_bytes
    )
    metadata = _read_exact(stream, metadata_count)
    payload = _read_exact(stream, payload_count)
    return Frame(kind=kind, request_id=request_id, metadata=metadata, payload=payload)


def write_sync(stream: BinaryIO, frame: Frame) -> None:
    stream.write(encode(frame))
    stream.flush()


async def read_async(reader: asyncio.StreamReader) -> Frame | None:
    try:
        header = await reader.readexactly(HEADER.size)
    except asyncio.IncompleteReadError as error:
        if not error.partial:
            return None
        raise EOFError("truncated frame header") from error
    metadata_count_bytes = await reader.readexactly(4)
    kind, request_id, metadata_count, payload_count = _decode_header(
        header, metadata_count_bytes
    )
    metadata = await reader.readexactly(metadata_count)
    payload = await reader.readexactly(payload_count)
    return Frame(kind=kind, request_id=request_id, metadata=metadata, payload=payload)


async def write_async(writer: asyncio.StreamWriter, frame: Frame) -> None:
    writer.write(encode(frame))
    await writer.drain()
