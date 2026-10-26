# The slow first take after an idle gap

On 23 October 2026, between 08:39 and 10:28 Moscow time, OpenRamble 0.33.1
spent 1.4–7.1 s in the engine on six takes whose engine normally needs about
0.24 s. A seventh, at 09:33, took 3.7 s in total beside a 0.36 s engine. Every
slow take followed an idle gap of 266 s or more, swap peaked at 26.8 GB, and
each slow take read 365–819 MB from disk where ordinary takes read 1–60 MB.
A controlled test with the model resident ruled out CPU and GPU contention
(1.1–1.3× at the median).

## Mechanism

The weights, 486 MB of Parakeet Ultra Q4_K_M, live in anonymous memory, not a
mapped file. ggml's Metal backend keeps them resident for three minutes after
its last graph (`GGML_METAL_RESIDENCY_KEEP_ALIVE_S`, default 180 s) and then
stops asking. On a Mac short of memory macOS then compresses them and moves
them to swap, and the next run reads them back after key-up.

The seventh take was the same thing, hidden by the log: a piece recognized
while the person was still speaking paid for the read, the take waited for
that piece at key-up, and `engineMilliseconds` described only the tail.

## The change

1. The log now carries the full engine time (`engineTotalMilliseconds`,
   `enginetotal=`), the bytes the process read from disk between key-down and
   the text (`diskReadBytes`, `diskread=`), and how long the engine had been
   idle at key-down (`engineIdleSeconds`, `idle=`).
2. When the engine has been idle for more than 150 s, the press runs the
   existing warm-up, one silent inference, as soon as the microphone is open.
   The weights page back in while the person speaks, and the take waits only
   for what is left. The warm-up's duration is logged as `engine idle warm-up`.
   150 s sits below the 180 s keep-alive, so no take whose weights may have
   gone is left out. The keep-alive itself is unchanged: holding 486 MB wired
   on a Mac that is already swapping is the cost this avoids.

## Reproduction

25 October 2026, MacBook Pro M4 Pro (14 cores, 24 GB), macOS 27.0.1, the
release `asr-bench` from this branch and the installed Parakeet Ultra GGUF.
The Mac was a working desktop with other sessions running; swap stood at
12.5–18 GB before each trial. The take is a 3.79 s English sentence made with
`say` at 16 kHz (SHA-256 `dff2cfce…2721`).

Each trial loads four lanes, gives each one take, starts an 8 GB hog, waits
240 s, then runs one take per lane, one lane at a time, in balanced order
(before, after, after, before, then reversed). `Key-up → text` is the bench's
own clock around `LocalTranscriber.transcribe(samples:)`, the call a finished
take makes; for an `after` lane it includes waiting for the warm-up.
`Read during take` is the process's `ri_diskio_bytesread` from the previous
take to this one; resident takes read 0–5 MB.

| Trial | # | Lane | Idle s | RSS MB | Warm-up s | Key-up → text s | Take engine s | Read during take MB |
|---|---:|---|---:|---:|---:|---:|---:|---:|
| 22:19:46 | 1 | before1 | 245 | 9 | – | 1.24 | 1.23 | 153 |
| 22:19:46 | 2 | after1 | 246 | 9 | 0.74 | 0.12 | 0.12 | 104 |
| 22:19:46 | 3 | after2 | 250 | 9 | 0.82 | 0.17 | 0.17 | 135 |
| 22:19:46 | 4 | before2 | 258 | 9 | – | 0.88 | 0.88 | 143 |
| 22:24:10 | 1 | after1 | 242 | 10 | 3.55 | 0.12 | 0.12 | 572 |
| 22:24:10 | 2 | before1 | 249 | 10 | – | 1.27 | 1.27 | 187 |
| 22:24:10 | 3 | before2 | 254 | 10 | – | 2.55 | 2.55 | 534 |
| 22:24:10 | 4 | after2 | 257 | 10 | 1.19 | 0.15 | 0.15 | 211 |
| 22:28:35 | 1 | before1 | 247 | 472 | – | 0.66 | 0.65 | 68 |
| 22:28:35 | 2 | after1 | 247 | 472 | 0.59 | 0.14 | 0.14 | 63 |
| 22:28:35 | 3 | after2 | 251 | 8 | 0.64 | 0.14 | 0.14 | 62 |
| 22:28:35 | 4 | before2 | 259 | 8 | – | 0.64 | 0.63 | 58 |

| Condition | Takes | Median key-up → text s | Max s | Median read MB |
|---|---:|---:|---:|---:|
| 0.33.1: page-in after key-up | 6 | 1.06 | 2.55 | 148 |
| This change: warm-up at key-down | 6 | 0.14 | 0.17 | 119 |

Every `before` take paged in after key-up and waited 0.64–2.55 s. Every
`after` take waited 0.12–0.17 s, its ordinary engine time, because its
warm-up (0.59–3.55 s, up to 572 MB read) finished while the sentence was
still being spoken. A fourth trial with a 12 GB hog (`data/heavy-pressure.jsonl`,
swap to 30 GB) gave 0.66 and 0.70 s against 0.12 and 0.14 s.

### The limit

The warm-up hides at most the time the person spends speaking. An earlier run
the same morning, under heavier background load, showed the edge: a `before`
take spent 3.80 s in the engine reading 209 MB, and the `after` lane's warm-up
took 8.17 s reading 339 MB, so its take still waited 4.56 s (engine 0.19 s).
The warm-up removed 3.8 s, the whole sentence, from an 8.4 s page-in. That
run's JSON was lost with the session's scratch folder; the numbers are from
its log. On 23 October the slow takes carried 1.7–25.8 s of audio against
page-ins of 1.4–7.1 s, so most would have been hidden completely.

### Short takes

The warm-up runs only after more than 150 s of idleness, so takes in a run of
dictation are untouched. On a resident engine it costs 0.03 s
(`data/short-resident.jsonl`: 160 s idle, no hog, a 1.47 s clip). Sending
the take the instant the warm-up starts, which a person cannot do, gave
0.06 s against 0.04–0.05 s without it. With 0.5 s of speech the two were
0.04–0.05 and 0.06–0.07 s, within noise.

To rerun, from the repository root after
`swift build -c release --product asr-bench --package-path Packages/LocalASR`:

```bash
clang -O2 -o /tmp/hog research/idle-swap-2026-10/hog.c
say -o /tmp/take.wav --data-format=LEI16@16000 "Please move the meeting to Thursday afternoon and send the notes to the team."
ORDER=before1,after1,after2,before2 python3 -I research/idle-swap-2026-10/repro.py "$PWD/Packages/LocalASR/.build/release/asr-bench" "<engine folder>" /tmp/take.wav /tmp/hog /tmp/out.jsonl
```

Run the binary where SwiftPM built it: it finds its runtime framework by a
relative path.

## Files

- `repro.py`: the harness. It loads N `asr-bench serve` lanes, gives each one
  steady-state take, starts `hog`, waits 240 s, then runs one take per lane in
  the given order. `before…` lanes send the take at key-up only; `after…`
  lanes send `{"mode":"warm"}` at key-down and the take 3.79 s later.
- `hog.c`: allocates the given gigabytes (8 here, 12 in the heavy trial) of
  incompressible pages and writes one byte per 16 KB page in a loop, so they
  stay active. It stops itself; the harness stops it early if the swap volume
  falls below 8 GiB free.
- `summarize.py`: the tables above, from a `data/*.jsonl` file.
- `data/`: one JSON object per trial. Numbers only; transcripts are dropped.
