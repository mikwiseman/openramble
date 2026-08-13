# Local transcription MCP

OpenRamble ships a small stdio [Model Context Protocol](https://modelcontextprotocol.io/)
server named `openramble-mcp`. It lets a local agent transcribe an existing
audio file with the same on-device model used for dictation.

Nothing is exposed until you enable **Settings → Agents → Let local agents
transcribe audio files**. This permission is off by default.

## Connect a client

The Agents settings tab copies the command using the exact path of the running
application. For a normal installation, the equivalent commands are:

```bash
codex mcp add openramble -- '/Applications/OpenRamble.app/Contents/MacOS/openramble-mcp'
claude mcp add --scope user openramble -- '/Applications/OpenRamble.app/Contents/MacOS/openramble-mcp'
```

For any stdio MCP client, use:

```json
{
  "mcpServers": {
    "openramble": {
      "command": "/Applications/OpenRamble.app/Contents/MacOS/openramble-mcp"
    }
  }
}
```

Restart the client after changing its MCP configuration. The helper launches
OpenRamble without activating a window if the app is not running.

## Tool contract

The server exposes one read-only, idempotent tool:
`openramble_transcribe_audio`.

| Argument | Required | Meaning |
|---|---:|---|
| `path` | yes | Absolute path to a regular local audio file |
| `language` | no | Supported BCP-47 hint such as `en` or `ru`; omit for automatic mixed-language recognition |
| `timestamps` | no | Include word timings when `true` |

Successful calls return the transcript and measured durations:

```json
{
  "text": "The locally recognized text.",
  "audioDurationSeconds": 12.4,
  "processingDurationSeconds": 0.31,
  "queueWaitSeconds": 0.0,
  "totalDurationSeconds": 0.34
}
```

`languageHint` and `words` are included only when they have values.

Tool errors have a stable code, human-readable message, and `retryable` flag.
For example, a request interrupted by live dictation returns
`preempted_by_dictation` with `retryable: true`. MCP cancellation stops a
queued job immediately and requests cancellation of active decoding or
recognition.

## Scheduling and limits

- Recognition uses one serial agent lane because concurrent inference on one
  model increases latency and memory rather than throughput.
- Up to four jobs may wait behind the active agent job. Additional work gets a
  retryable `busy` result instead of growing an unbounded queue.
- Starting live dictation reserves the recognizer synchronously, cancels the
  active agent job, and pauses queued work. The interrupted agent call receives
  a retryable error; it is never silently restarted with stale assumptions.
- A file must be an absolute, readable, nonempty regular file. Symbolic links
  are rejected. The input limit is 1 GiB and decoded audio is limited to 30
  minutes per call; split larger recordings.
- The MCP transport accepts newline-delimited JSON-RPC requests up to 4 MiB,
  plus progress notifications and request cancellation.

Several MCP clients may start helpers at the same time. Every helper remains a
thin protocol adapter; the application is the single owner of the model and
the queue.

## Privacy and security

The stdio helper has no network transport. It talks to OpenRamble through a
Unix domain socket in the current user's protected Darwin runtime directory:
the directory is mode `0700`, the socket is mode `0600`, and both sides verify
the peer UID. Requests from another macOS account are rejected.

The helper opens the file you explicitly pass and stages a private temporary
copy in the current user's protected runtime directory. APFS uses a
copy-on-write clone; other local filesystems use a data-only copy. This lets an
agent-authorized file in Documents, Desktop, or a cloud-provider folder reach
the app without granting the app broad folder access. Both helper and app try
to delete the staging file after every success, error, or cancellation, and the
app removes abandoned staging files after a crash when it next starts. The
staging directory is mode `0700`; files are mode `0600`.

Agent transcripts are returned to the MCP client and are not added to Recent
Dictations, the clipboard, app logs, or disk. The MCP client may keep tool
inputs or outputs under its own privacy and retention policy.

The helper intentionally does not use the official Swift SDK because that SDK's
HTTP/SSE target links `Network.framework` even for a stdio-only executable.
OpenRamble implements the narrow JSON-RPC stdio surface it needs so the shipped
helper preserves the application's auditable no-recognition-network boundary.

## Verify a build

The process smoke test exercises initialization, discovery, validation,
protocol and input bounds, and recovery after malformed input. Pass one or more
audio files to add concurrent, real-inference coverage; the test prints only
transcript hashes and timings:

```bash
./scripts/test-mcp-helper.sh \
  '/Applications/OpenRamble.app/Contents/MacOS/openramble-mcp' \
  /absolute/path/to/voice.wav /absolute/path/to/another.m4a
```

The normal repository checks also verify that the helper does not link
`Network.framework`, and the installed-artifact smoke test checks its signature
inside the signed application bundle.
