# The OpenRamble transcription server

`openramble serve` turns audio files into text for other applications on a Linux server with no graphics card. It speaks the same request and response shape as ElevenLabs Scribe, so a caller written for Scribe needs a new address and key and little else. It runs Parakeet Ultra through transcribe.cpp on every core, keeps nothing, and makes no outbound connections.

This page describes the API, how to install and run the server, what the callers must change, and what to check on the day it goes live.

## How it works

1. A caller uploads one file per request.
2. ffmpeg decodes it to 16 kHz mono in a temporary file that has no name on disk.
3. Silence is left out. A per-participant meeting track is mostly other people talking, which reaches that track as silence, so this removes most of the work.
4. What is left is cut at pauses into pieces of at most 20 seconds.
5. One engine per core recognizes pieces in parallel. Each engine is a separate copy of the model on one thread, because one loaded model runs one piece at a time.
6. A request whose caller waits at most 10 minutes, such as a voice note, is interactive: it goes ahead of every meeting track at the next piece boundary, so it never waits behind a long job for more than the pieces already running. The class comes from how long the caller waits, never from how much speech the file has, so a quiet participant's meeting track still queues as a meeting track.
7. The response carries the text and, if asked, every word with its time in the file.

## API

### Routes

- `POST /v1/speech-to-text`, with the key in the `xi-api-key` header. The body is either `multipart/form-data` with the audio in the field `file` (its file name and content type are ignored), or the raw audio with the parameters in the query string.
- `GET /health` needs no key and returns `{"draining":false,"engines":4,"jobs":0,"queued_seconds":0.0}`. `jobs` counts requests in progress, uploads included. `queued_seconds` is the speech still waiting or being recognized. While the engines load it answers 503 `starting`.
- Any other path gets 404 `not_found`, and a wrong method gets 405 `method_not_allowed`.

Every response closes its connection.

### Request fields

| Field | Handling |
|---|---|
| `file` | The audio: any format ffmpeg reads from mp4/m4a/mov, Ogg (Opus, Vorbis), Matroska/WebM, WAV, MP3, FLAC, AAC, CAF, AIFF, ASF/WMA or AMR, video included. Up to 2 GiB and 12 hours. |
| `model_id` | Any value or none; ignored. |
| `timestamps_granularity` | `word` (the default) or `none`. `character` gets 400 `unsupported_parameter`. |
| `diarize` | `true` gets 400 `diarization_unsupported`: the server cannot separate speakers. Send one file per speaker with `diarize=false`. |
| `no_verbatim` | `true` removes hesitations and stutters with the Mac app's Clean Verbatim. Words that remain keep their times. |
| `tag_audio_events`, `num_speakers`, `language_code`, `keyterms` | Accepted and ignored. Key terms are never logged. |
| `cloud_storage_url`, `webhook=true`, `use_multi_channel=true`, `file_format` other than `other` | 400 `unsupported_parameter`. |
| `output_format` | `openramble` returns the command-line tool's JSON instead of Scribe's shape. |
| `deadline_s` | How long the caller waits in all, upload included, at most 86400. Without it, the wait set for the caller's key applies, and without that, 1620. At most 600 makes the request interactive. A request that cannot finish in time is refused at once rather than timing out. |
| Anything else | Ignored. |

Booleans accept `true`, `false`, `1`, `0`, `yes` and `no` in any case. Anything else gets 400.

### The response

```json
{"language_code":null,"language_probability":null,"text":"Привет, мир.","transcription_id":"or_…","words":[
 {"end":0.48,"speaker_id":null,"start":0.12,"text":"Привет,","type":"word"},
 {"end":0.52,"speaker_id":null,"start":0.48,"text":" ","type":"spacing"},
 {"end":0.9,"speaker_id":null,"start":0.52,"text":"мир.","type":"word"}]}
```

- Times are seconds from the start of the file, with at most three decimals, and they never go backwards.
- Words alternate with spacing entries, so joining the `text` of every entry gives `text` exactly.
- `language_code`, `language_probability` and `speaker_id` are null, because the model does not detect the language or the speaker. There is no `logprob`.
- With `timestamps_granularity=none`, `words` is empty and `text` is the same.
- Silence gives `"text":""` and `"words":[]`.
- The `request-id` response header equals `transcription_id`.

With `output_format=openramble`:

```json
{"duration":61.2,"elapsed":7.9,"model":"parakeet-ultra-Q4_K_M","segments":[{"end":14.1,"label":null,"start":0.0,"text":"…"}],"text":"…"}
```

### Errors

Every error body is `{"detail":{"status":"…","code":"…","message":"…"}}`. The message is fixed English and never repeats a file name or anything the audio said. A 200 response never contains `detail` or `error`.

| Status | `detail.status` | Meaning |
|---|---|---|
| 400 | `invalid_parameters`, `unsupported_parameter`, `diarization_unsupported` | The request asks for something the server does not do. Do not retry. |
| 401 | `invalid_api_key` | The key is missing or wrong. |
| 413 | `file_too_large` | The upload is over 2 GiB. |
| 422 | `invalid_audio`, `audio_too_long`, `audio_too_long_for_deadline` | No audio in the file, more than 12 hours, or too long to finish within `deadline_s` even on an idle server. |
| 429 | `system_busy`, `starting`, `shutting_down` | Retry after the `Retry-After` seconds. |
| 500 | `internal_error` | The recognizer, ffmpeg or the disk failed. |

The server never bills and keeps nothing, so no response is ever an outcome to reconcile: after a 5xx, a 502 from the proxy or a dropped connection, nothing happened and the same request can be sent again.

The port answers from the moment the process starts until it exits: 429 `starting` while the engines load, and 429 `shutting_down` while it stops. Between the old process and the new one during a restart the port is closed for well under a second, and Caddy retries the connection meanwhile instead of answering 502 ([`Caddyfile`](../apps/cli/deploy/Caddyfile)).

A wrong key and a declared upload over 2 GiB are answered before the body is read. A 429 for a full server comes after the body has been read, so a caller always sees it, unless the caller sent `Expect: 100-continue`.

### Admission

The server counts the speech ahead of a job in its class and its measured speed, and promises only what it can keep:

```
cost  = running average of engine seconds per audio second (starts at 0.45)
class = interactive if deadline ≤ 600, otherwise batch
ahead = speech of the jobs of the same class already queued or running
        (meeting work is never ahead of an interactive job)
elapsed + 1.15 × mine × cost / engines > deadline → 422 audio_too_long_for_deadline
elapsed + 1.15 × (ahead + mine) × cost / engines > deadline → 429, Retry-After = 1.15 × ahead × cost / engines
otherwise                                         → accepted
```

At most 8 requests are in progress at once; the 9th gets 429. A client that disconnects cancels its job: pieces not yet started are dropped, and the one running finishes and is discarded.

## Keys

`/etc/openramble/keys` holds one line per caller: a label and the SHA-256 of its key. The server never stores a key itself.

```bash
key=$(openssl rand -hex 32)
printf 'meetings %s\n' "$(printf %s "$key" | sha256sum | cut -d' ' -f1)" >> /etc/openramble/keys
echo "$key"   # give this to the caller, once
```

Use one label per caller: `meetings`, `openstrudel` and `ssh`. The label appears in the log, so you can tell the callers apart. A third column sets how long that caller waits in all, in seconds, for requests that send no `deadline_s`. Give OpenStrudel `170`, a little under its 180-second limit, so its voice notes are interactive without any change on its side:

```
openstrudel 5f0c…e1 170
```

After editing the file, restart the service.

The `ssh` key goes in `/etc/openramble/ssh.header` as the line `xi-api-key: <key>`, owned by root with mode 0600.

## Install

On the server, as root, with Rust, ffmpeg and curl installed and the model at `/opt/openramble/models/parakeet-ultra-gguf/`:

```bash
git clone https://github.com/mikwiseman/openramble.git && cd openramble
apps/cli/deploy/install.sh
```

`install.sh` builds on the machine itself (ggml tunes itself to the processor), checks the model's size and SHA-256 with the new binary before replacing the old one, keeps the previous binary as `.prev`, installs and enables `openramble.service`, restarts it only once no job is running, waits for `/health`, and only then replaces `transcribe-stdin`.

The server is the only process on the machine that keeps engines loaded. A second set, such as a command-line run with `--workers 3`, would not fit in memory next to its four, and the kernel would kill the server. `install.sh` creates `/var/lib/openramble/engines.lock` for that: the server holds it while its engines are loaded, a file-mode run of the command-line tool refuses to start while the server holds it, and a server that starts while a file-mode run is going waits for it to finish, answering 429 `starting` meanwhile. Send files to the server instead, as `transcribe-stdin` does.

The service ([`apps/cli/deploy/openramble.service`](../apps/cli/deploy/openramble.service)) runs as a dynamic user with a read-only system, no home, no devices and `IPAddressDeny=any` except localhost, so neither the server nor ffmpeg can reach another machine. It reads the keys through `LoadCredential`, keeps its temporary files in a private `/var/tmp`, and is limited to 7 GB of memory. On a stop, new jobs get 429 `shutting_down` and jobs in flight get up to 25 minutes.

### HTTPS and the firewall

Caddy terminates HTTPS and forwards to `127.0.0.1:8080` ([`apps/cli/deploy/Caddyfile`](../apps/cli/deploy/Caddyfile)). Replace the example name, install Caddy, and copy the file to `/etc/caddy/Caddyfile`. Caddy obtains its certificate itself.

Allow ssh, and HTTPS only from the callers:

```bash
ufw default deny incoming
ufw allow 22/tcp
ufw allow from <meetings-server-ip> to any port 443 proto tcp
ufw allow from <openstrudel-server-ip> to any port 443 proto tcp
ufw enable
```

Caddy needs port 80 or 443 reachable once from Let's Encrypt to get its certificate; open port 80 for that moment, or use the DNS challenge. If the callers share a private network with this machine, WireGuard is the simpler alternative to HTTPS.

### The ssh path

WaiWeb reaches the server with ssh and the forced command `/opt/openramble/bin/transcribe-stdin`: one audio file on standard input, OpenRamble JSON on standard output. That script is now a curl client of the local server ([`apps/cli/deploy/transcribe-stdin`](../apps/cli/deploy/transcribe-stdin)), so the ssh path shares the server's engines instead of loading its own copies, which would not fit in memory next to them. Nothing changes for WaiWeb. A hung-up ssh session cancels its job.

## What the callers change

**Meetings (waiwai `meeting-stt-scribe.service.ts`). Required before switching.**

- Read the URL and the timeout from the environment: `SCRIBE_URL`, and a timeout of 4 hours.
- Node's fetch gives up after 300 seconds without response headers, and the server answers only when the transcript is ready. Pass an undici `Agent` with `headersTimeout` and `bodyTimeout` equal to that timeout. Without it, any track with more than about 45 minutes of speech fails on the client and locks the meeting for 24 hours.
- Send `deadline_s` equal to the timeout in seconds.
- Label the model `openramble-parakeet-ultra`.
- Stop sending `diarize=true` for single mixed files: it now gets 400.
- Clear the pending receipt after any response from this server, 5xx included, and after a dropped connection. Today only some 4xx and 429 clear it, and anything else locks the track for 24 hours as an outcome that cannot be confirmed. This server never bills, so there is nothing to confirm: a 500 or a crash would otherwise lock the track for a day for no reason.

**OpenStrudel.** Point speech-to-text at the server with its own key, which carries the 170-second wait (see Keys), and keep text-to-speech and key checks on ElevenLabs. A note that the queue of other notes would make late gets 429 at once instead of a timeout. Telegram voice notes (Ogg Opus), m4a and mp4 video notes work as they are. A 30-second note takes about 7 seconds on 4 engines.

## Capacity

Defaults for a 4-core, 8 GB machine (Hetzner CAX21): 4 engines with Q4_K_M, pieces of up to 20 seconds, callers who wait up to 600 s treated as interactive, 8 jobs, 32 connections, uploads up to 2 GiB and audio up to 12 hours. Each engine takes about 1.15 GB on transcribe.cpp 0.2.0, so four take about 5 GB. Disk use per job is the upload until it is decoded, plus 230 MB per hour of audio.

Estimates at 4 engines and 0.44 engine seconds per audio second, from the 20.8-minute track that took 184 s on 3 engines:

| Work | About |
|---|---|
| 30 s or 60 s voice note | 7 s; at most 16 s while a meeting runs |
| 4-minute voice note | 28 s |
| Three 4-minute notes at once | the last done at 85 s |
| 20.8-minute track, all speech | 137 s |
| 1-hour participant track | 3.3 min |
| 9.2-hour track, the speaker talking a third of the time | 24 min |

Meeting time and long notes scale with 1/engines; a single piece still takes about 7 seconds, so a short note does not get faster. Use one engine per core while engines × 1.2 GB + 1 GB fits in memory.

## Deploy-day checks

These are for the operator after review, on the real server:

1. `/usr/bin/time -v openramble --workers 3` and `--workers 4` on the 20.8-minute track, with Q4_K_M and with Q8_0. Choose the engine count and quantization from the wall time and the maximum resident memory.
2. Compare the server with today's command-line run on that track: word differences and wall time.
3. Three real Zoom tracks with `--no-gate` and without it: the gate must keep at least 99% of the words.
4. 30-second, 60-second and 4-minute Opus notes, on an idle server and with a 9-hour job running.
5. A client that disconnects through Caddy cancels its job.
6. `kill -9` during a job: the service is back within 10 seconds and no disk space is left behind.
7. `systemctl show -p IPAddressDeny,IPAddressAllow openramble`, and an outbound `curl` from inside the sandbox that must fail: `systemd-run -p IPAddressDeny=any -p IPAddressAllow=localhost --wait --pty curl -sS https://example.com`.
8. `systemctl restart openramble` during a job: the job finishes, then the service restarts.

## Not done yet

- transcribe.cpp 0.4.1 maps the model file into memory, so engines share the weights (about 420 MB each instead of 1.15 GB), can be cancelled mid-piece, and use bounded memory on long audio. Moving to it needs the same validation on the Mac, which links the same runtime.
- Speaker separation (Sortformer) for `diarize=true`.
- `/v1/models`, only if a caller turns out to need it.
