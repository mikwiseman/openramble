# First-word capture (October 2026)

Question: is the first word of a dictation ever cut, per microphone class?

Answer for the built-in mic: yes, on every take where speech starts 0-150 ms
after key-down. Real sound reaches the take a median 314 ms after key-down
today. Two things add up to that delay:

- About 135 ms of AVAudioEngine setup after key-down, before the device starts.
- 180 ms of device warm-up. After the microphone starts it gives about 20 ms of
  sound, then a fading near-silence, then the room. This happens with every
  API, so it belongs to the device.

A HAL I/O proc (branch `claude/first-word-onset`, not shipped) removes most of
the setup cost and brings real sound to 228 ms. Nothing that opens the
microphone at key-down can beat the 180 ms warm-up, so 100% at 0-150 ms is
impossible on this microphone without keeping it open. USB and Bluetooth are
not measured yet (none connected).

## How it was measured

`onset-harness` drives the shipping `MicrophoneCapture` with a scripted
key-down. Output is numbers only. Captured audio stays in memory and take files
are deleted.

- **Onset test** (`./run.sh`). A TTS sentence plus an alignment chirp plays
  through the built-in speakers so the first word reaches the microphone
  0-150 ms after key-down (500 ms as a control). Speaker-to-mic latency is
  calibrated first: 47.31 ms, spread 0.02 ms. The chirp places the first word
  inside the take.
- **Room mode** (`--room`). No sound plays. One second of room noise through
  `MicrophoneCapture`, cut into 10 ms windows, shows when the take reaches the
  room's settled level.
- **Breakdown** (`--breakdown`). Times each start step against input host
  timestamps, for AVAudioEngine, a bare HAL I/O proc and other variants, with
  the same room-level curve.
- Every take records whether another process already had the microphone
  running. Those takes are left out: a warm device is not a cold start.

## Results, built-in mic (MacBook Pro)

### Where real sound starts (room mode, 20 takes per path, interleaved)

| Path | `startRecording` returns | First sample to room level within 20 dB | Key-down to room level within 20 dB, p50 / p90 |
|---|---|---|---|
| Shipping (AVAudioEngine) | 135 ms | 180 ms | 314 / 360 ms |
| HAL I/O proc (proposed) | 48 ms | 180 ms | 228 / 238 ms |

Median level against the settled room level, from the take's first sample:

| ms | 0 | 20 | 40 | 60 | 80 | 100 | 120 | 140 | 160 | 180 | 200 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| dB | -1 | -18 | -32 | -51 | -65 | -84 | -99 | -117 | -51 | -12 | -1 |

The raw breakdown shows the same dip with no converter in the path
(`results/built-in-breakdown-room.jsonl`), so it comes from the device.

### First words (onset test, `results/built-in-2.jsonl`, 88 valid takes)

The first column scores a take against its first non-zero sample. The second
scores it against real sound, at first sample + 180 ms as room mode shows.

| Speech starts after key-down | Kept, vs first sample | Kept, vs real sound | Lost vs real sound, median (max) |
|---|---|---|---|
| 0 ms | 0/12 | 0/12 | 311 ms (368) |
| 25 ms | 0/11 | 0/11 | 368 ms (631) |
| 50 ms | 0/11 | 0/11 | 267 ms (430) |
| 75 ms | 0/11 | 0/11 | 239 ms (380) |
| 100 ms | 0/11 | 0/11 | 226 ms (347) |
| 125 ms | 1/11 | 0/11 | 193 ms (322) |
| 150 ms | 6/11 | 0/11 | 174 ms (248) |
| 500 ms (control) | 10/10 | 10/10 | 0 ms |

- Quick re-takes, 0.5 s after the last one, are no faster than cold ones.
- Stopping the speakers' own I/O does not change start times (137 vs 132 ms).
- The red dot appears when `startRecording` returns. That is within 2 ms of the
  first sample, so it comes about 180 ms before real sound.

### Start-up breakdown (`results/built-in-breakdown-2.jsonl`, `-3.jsonl`, `-room.jsonl`)

| Path, all work after key-down | Device's first sample, p50 |
|---|---|
| Shipping AVAudioEngine (`inputNode` 70-100 ms, tap ~20, prepare ~30-40, start ~40-50) | 157-218 ms |
| Previous take's engine left running ("lazy close" with a new engine) | 109-160 ms |
| Input-only AUHAL | 67-86 ms |
| Engine built and prepared before key-down, only `start()` after | 32-53 ms |
| Bare HAL I/O proc | 45-55 ms |

Real use (local SupportLogs, 1 s resolution, 270 gaps between takes): 14% of
takes start within 3 s of the previous key-up, and 18% within 5 s.

## What would keep the first word

| Move | Effect on this microphone |
|---|---|
| HAL I/O proc for dictation (on the branch, tested, not shipped) | Real sound 86 ms sooner at p50, 120 ms sooner at p90. |
| Red dot only once real sound arrives (first sample + the device's measured warm-up, measured on first use) | The dot stops showing 180 ms early. Anyone who waits for it keeps every word. |
| Keep the stream open a few seconds after a take | A quick re-take starts with no warm-up. That is about 1 take in 6 in real use. |

The microphone is never opened before key-down in any of these.

## Reproduce

    ./run.sh                                    # onset test, default input (plays sound)
    ./run.sh --device AirPods                   # a named input (AirPods out of the case, near the laptop)
    onset-harness/.build/release/first-word-onset --room 10 --gaps 3,0.5 --out results/x.jsonl
    onset-harness/.build/release/first-word-onset --breakdown 8 --gaps 3,0.5 --out results/y.jsonl
    python3 summarize.py results/x.jsonl

`results/built-in.jsonl` and `results/built-in-breakdown.jsonl` overlapped
another session's microphone benchmark and are kept only for the record. The
one take in `results/built-in-profile-engine.jsonl` shows the same dip with
noise played, before the speakers were muted.
