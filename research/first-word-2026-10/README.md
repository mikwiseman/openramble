# First-word capture (October 2026)

Question: is the first word of a dictation ever cut, and if so where does the
time go? Answer for the built-in mic: yes, almost always when speech starts
0-150 ms after key-down, and the cause is AVAudioEngine setup after key-down,
not the microphone.

## Method

`onset-harness` calls the shipping `MicrophoneCapture.startRecording` at a
scripted key-down and plays a TTS sentence (plus an alignment chirp) through the
built-in speakers so the first word reaches the mic 0-150 ms later (500 ms as a
control). Speaker-to-mic latency is calibrated first (47.3 ms, spread 0.02 ms).
The chirp places the first word inside the 16 kHz take. A take "keeps the first
word" only if the word's onset is at or after the first live sample. Output is
numbers only; captured audio stays in memory and take files are deleted.
`--breakdown` times each start step with input host timestamps (no playback).
`--profile` (written, not yet run) plays steady noise across the key-down to
find when the take reaches full level.

## Results, built-in mic (MacBook Pro, load average ~30 from other sessions)

`results/built-in.jsonl`, 87 valid takes:

| Speech starts after key-down | Takes that kept the first word | Lost, median (max) |
|---|---|---|
| 0 ms | 0/12 | 202 ms (287) |
| 25 ms | 0/11 | 184 ms (296) |
| 50 ms | 0/11 | 165 ms (397) |
| 75 ms | 0/10 | 132 ms (484) |
| 100 ms | 0/11 | 116 ms (238) |
| 125 ms | 0/11 | 120 ms (164) |
| 150 ms | 3/11 | 53 ms (119) |
| 500 ms (control) | 10/10 | 0 ms |

Key-down to first live sample: p50 ~210 ms, p90 ~290 ms, max 559 ms. Quick
re-takes (0.5 s gap) are no faster than cold ones. The red dot (set when
`startRecording` returns) appears within ~1 ms of the first live sample, so it
already tells the truth. Some of these takes overlapped another session's mic
benchmark, which can only have made starts faster.

Start-up breakdown, `results/built-in-breakdown-2.jsonl` and `-3.jsonl`, ms
from the start call to the first live sample, p50:

| Path | First live sample |
|---|---|
| Shipping AVAudioEngine (`inputNode` ~70-100 ms, tap ~20, prepare ~30-40, start ~40-50) | 157-218 |
| Previous take's engine still running ("lazy close") | 109-160 |
| Input-only AUHAL built at key-down | 67-86 |
| Engine prebuilt and prepared before key-down, `start()` at key-down | 32-53 |
| Bare HAL I/O proc, created at key-down | 45-50 |

Real use (local SupportLogs, 1 s resolution, 270 gaps): 14% of takes start
within 3 s of the previous key-up, 18% within 5 s. Lazy close would reach
about one take in six and save ~40 ms on it.

Open finding: on the shipping path the audio right after the first live sample
is far below its settled level (median -11 dB at 0-25 ms, -34 dB at 25-50 ms,
-58 dB at 50-100 ms, -13 dB at 100-200 ms, `results/built-in-2.jsonl`). The
real deaf window may be longer than the table says. `--profile` measures it.

USB: none connected. AirPods: not connected during the run. Run either with
`./run.sh --device <name>` (AirPods must be out of the case near the laptop).

## Reproduce

    ./run.sh                               # onset test, default input
    ./run.sh --breakdown 8 --gaps 3,0.5    # start-up breakdown
