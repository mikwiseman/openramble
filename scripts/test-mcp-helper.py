#!/usr/bin/env python3
"""Process-level smoke test for the packaged OpenRamble MCP helper."""

import json
import hashlib
import os
import queue
import subprocess
import sys
import threading


def fail(message: str) -> None:
    raise SystemExit(f"MCP helper smoke failed: {message}")


if len(sys.argv) < 2:
    fail("pass the path to openramble-mcp, optionally followed by audio files")

helper = sys.argv[1]
audio_files = sys.argv[2:]
cancel_audio = os.environ.get("OPENRAMBLE_MCP_CANCEL_AUDIO")
disabled_audio = os.environ.get("OPENRAMBLE_MCP_EXPECT_ACCESS_DISABLED_AUDIO")

process = subprocess.Popen(
    [helper],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)
response_lines = queue.Queue()
response_timeout = float(os.environ.get("OPENRAMBLE_MCP_SMOKE_TIMEOUT_SECONDS", "120"))


def read_responses() -> None:
    assert process.stdout is not None
    for line in process.stdout:
        response_lines.put(line)
    response_lines.put(None)


threading.Thread(target=read_responses, name="mcp-smoke-stdout", daemon=True).start()


def send(payload: dict) -> None:
    assert process.stdin is not None
    process.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
    process.stdin.flush()


def receive() -> dict:
    try:
        line = response_lines.get(timeout=response_timeout)
    except queue.Empty:
        fail(f"no response within {response_timeout:g} seconds")
    if not line:
        stderr = process.stderr.read() if process.stderr is not None else ""
        fail(f"helper closed stdout unexpectedly: {stderr.strip()}")
    try:
        return json.loads(line)
    except json.JSONDecodeError as error:
        fail(f"stdout was not JSON: {error}")


try:
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 0, "method": "tools/list", "params": {}})
    premature = receive()
    if premature.get("id") != 0 or premature.get("error", {}).get("code") != -32600:
        fail(f"initialized notification bypassed lifecycle: {premature}")

    send(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "artifact-smoke", "version": "1"},
            },
        }
    )
    initialized = receive()
    if not (
        initialized.get("id") == 1
        and initialized.get("result", {}).get("protocolVersion") == "2025-11-25"
        and "tools" in initialized.get("result", {}).get("capabilities", {})
    ):
        fail(f"unexpected initialize response: {initialized}")

    send({"jsonrpc": "2.0", "id": 8, "method": "tools/list", "params": {}})
    early_tools = receive()
    if early_tools.get("id") != 8 or early_tools.get("error", {}).get("code") != -32600:
        fail(f"tools were available before notifications/initialized: {early_tools}")

    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    tools = receive()
    listed = tools.get("result", {}).get("tools", [])
    if tools.get("id") != 2 or not listed or listed[0].get("name") != "openramble_transcribe_audio":
        fail(f"unexpected tools/list response: {tools}")

    send(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": "openramble_transcribe_audio", "arguments": {}},
        }
    )
    invalid = receive()
    if invalid.get("id") != 3 or invalid.get("error", {}).get("code") != -32602:
        fail(f"unexpected malformed-arguments error: {invalid}")

    send(
        {
            "jsonrpc": "2.0",
            "id": 9,
            "method": "tools/call",
            "params": {
                "name": "openramble_transcribe_audio",
                "arguments": {"path": ""},
            },
        }
    )
    invalid_value = receive()
    error = invalid_value.get("result", {}).get("structuredContent", {}).get("error", {})
    if invalid_value.get("id") != 9 or invalid_value.get("result", {}).get("isError") is not True or error.get("code") != "invalid_path":
        fail(f"unexpected tool validation error: {invalid_value}")

    send(
        {
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": {
                "name": "openramble_transcribe_audio",
                "arguments": {"path": "/tmp/voice.wav", "timestamps": "yes"},
            },
        }
    )
    wrong_type = receive()
    if wrong_type.get("id") != 10 or wrong_type.get("error", {}).get("code") != -32602:
        fail(f"unexpected wrong-type response: {wrong_type}")

    send({"jsonrpc": "2.0", "id": 4, "method": "ping", "params": {}})
    ping = receive()
    if ping.get("id") != 4 or ping.get("result") != {}:
        fail(f"unexpected ping response: {ping}")

    send(
        [
            {"jsonrpc": "2.0", "id": 5, "method": "ping", "params": {}},
            {"jsonrpc": "2.0", "id": 11, "method": "tools/list", "params": {}},
        ]
    )
    batch = receive()
    if batch.get("id", "missing") is not None or batch.get("error", {}).get("code") != -32600:
        fail(f"current MCP protocol accepted a JSON-RPC batch: {batch}")

    assert process.stdin is not None
    process.stdin.write("x" * (4 * 1024 * 1024 + 1) + "\n")
    process.stdin.flush()
    oversized = receive()
    if oversized.get("id", "missing") is not None or oversized.get("error", {}).get("code") != -32700:
        fail(f"unexpected oversized-request response: {oversized}")

    send({"jsonrpc": "2.0", "id": 6, "method": "ping", "params": {}})
    recovered = receive()
    if recovered.get("id") != 6 or recovered.get("result") != {}:
        fail(f"helper did not recover after an oversized line: {recovered}")

    send(
        {
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": {"name": "not_an_openramble_tool", "arguments": {}},
        }
    )
    unknown = receive()
    if unknown.get("id") != 7 or unknown.get("error", {}).get("code") != -32602:
        fail(f"unexpected unknown-tool response: {unknown}")

    if disabled_audio:
        send(
            {
                "jsonrpc": "2.0",
                "id": 60,
                "method": "tools/call",
                "params": {
                    "name": "openramble_transcribe_audio",
                    "arguments": {"path": str(os.path.abspath(disabled_audio))},
                },
            }
        )
        denied = receive()
        denied_error = denied.get("result", {}).get("structuredContent", {}).get("error", {})
        if denied.get("id") != 60 or denied_error.get("code") != "access_disabled":
            fail(f"disabled access did not fail before app launch and staging: {denied}")

    if cancel_audio:
        send(
            {
                "jsonrpc": "2.0",
                "id": 50,
                "method": "tools/call",
                "params": {
                    "name": "openramble_transcribe_audio",
                    "arguments": {"path": str(os.path.abspath(cancel_audio))},
                    "_meta": {"progressToken": "cancellation-smoke"},
                },
            }
        )
        while True:
            update = receive()
            if update.get("id") == 50:
                fail(f"cancellation fixture completed before it could be cancelled: {update}")
            params = update.get("params", {})
            if (
                update.get("method") == "notifications/progress"
                and params.get("progressToken") == "cancellation-smoke"
                and params.get("progress", 0) >= 50
            ):
                break
        send(
            {
                "jsonrpc": "2.0",
                "method": "notifications/cancelled",
                "params": {"requestId": 50, "reason": "artifact smoke"},
            }
        )
        send({"jsonrpc": "2.0", "id": 51, "method": "ping", "params": {}})
        after_cancel = receive()
        if after_cancel.get("id") != 51 or after_cancel.get("result") != {}:
            fail(f"cancelled request leaked a response or blocked the connection: {after_cancel}")
        send({"jsonrpc": "2.0", "id": 52, "method": "ping", "params": {}})
        healthy = receive()
        if healthy.get("id") != 52 or healthy.get("result") != {}:
            fail(f"connection was not healthy after cancellation: {healthy}")

    if audio_files:
        request_ids = list(range(100, 100 + len(audio_files)))
        for request_id, path in zip(request_ids, audio_files):
            send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "method": "tools/call",
                    "params": {
                        "name": "openramble_transcribe_audio",
                        "arguments": {
                            "path": path,
                            "timestamps": request_id == request_ids[-1],
                        },
                    },
                }
            )

        completed = {}
        for _ in request_ids:
            response = receive()
            completed[response.get("id")] = response
        if set(completed) != set(request_ids):
            fail(f"concurrent calls returned unexpected ids: {sorted(completed)}")

        summaries = []
        for request_id in request_ids:
            result = completed[request_id].get("result", {})
            if result.get("isError") is not False:
                fail(f"real transcription {request_id} failed: {result}")
            structured = result.get("structuredContent", {})
            text = structured.get("text", "")
            if not text or structured.get("audioDurationSeconds", 0) <= 0:
                fail(f"real transcription {request_id} had an empty result")
            if request_id == request_ids[-1] and not structured.get("words"):
                fail("timestamps=true did not return word timings")
            summaries.append(
                {
                    "id": request_id,
                    "text_sha256": hashlib.sha256(text.encode()).hexdigest(),
                    "audio_seconds": round(structured["audioDurationSeconds"], 4),
                    "processing_seconds": round(
                        structured["processingDurationSeconds"], 4
                    ),
                    "queue_seconds": round(structured["queueWaitSeconds"], 4),
                    "total_seconds": round(structured["totalDurationSeconds"], 4),
                }
            )
        print("MCP real-audio concurrency: " + json.dumps(summaries, separators=(",", ":")))
finally:
    if process.stdin is not None:
        process.stdin.close()
    try:
        return_code = process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.terminate()
        return_code = process.wait(timeout=5)
    if return_code != 0:
        stderr = process.stderr.read() if process.stderr is not None else ""
        fail(f"helper exited with {return_code}: {stderr.strip()}")

print("MCP helper smoke: lifecycle, discovery, validation and protocol bounds OK.")
