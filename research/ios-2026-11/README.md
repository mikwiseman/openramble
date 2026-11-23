# OpenRamble for iPhone, November 2026

The iPhone app in `apps/ios` records a take, writes its words on the iPhone,
and keeps it there. This note says which recognition engine it uses and why,
with the measurements, and what the design took from the best iPhone apps.

## The engine: our own, not transcribe.cpp on Metal

The iPhone recognizes with OpenRamble's own engine (`engine/`), through
LocalASR's `OreAdapter`, on the processor. The Mac on Apple silicon keeps
transcribe.cpp on Metal. Six reasons, the first four measured.

1. **The same words.** The engine built for iOS gives byte-identical output
   to the Mac build on all 1,422 FLEURS test clips: text, token ids, token
   times and confidences. It gets 1,472 of 29,586 words wrong (4.98%):
   723 of 14,481 in English and 749 of 15,105 in Russian. On the same clips
   the Mac app, transcribe.cpp on Metal, gets 1,470 wrong (4.97%), and
   transcribe.cpp on the processor 1,473 (ledger P1 in
   `research/own-engine-2026-11`). On 200 English clips run in the Simulator,
   transcribe.cpp on the iOS processor got 231 wrong and the engine 230.
2. **About twice as fast** on the same processor. Whole recognitions in the
   iOS Simulator, both engines interleaved round by round, best of three
   rounds of three runs, load average 10 to 15:

   | Clip | engine, 2 threads | transcribe.cpp, 2 threads | engine, 4 threads | transcribe.cpp, 4 threads |
   |---|---|---|---|---|
   | 2 s | 109 ms | 192 ms | 57 ms | 111 ms |
   | 8 s | 385 ms | 784 ms | 204 ms | 457 ms |
   | 30 s | 1,502 ms | 3,084 ms | 794 ms | 1,931 ms |

3. **A third of the memory.** Peak footprint of a 30-second recognition in
   the Simulator, read with `footprint(1)`: 149 MB for the engine, 515 MB for
   transcribe.cpp. The engine maps the model file and reads the weights where
   they lie, so iOS counts them as file pages it may drop, not as the app's
   memory; transcribe.cpp copies them. The app itself, model open, after three
   takes: 131 MB.
4. **Opens in milliseconds.** Model load with the file in the system's cache:
   17 to 25 ms for the engine, 75 to 96 ms for transcribe.cpp.
5. **The GPU is not there when it matters.** iOS refuses GPU work from an app
   in the background. On the iPhone a take is started from the Action button,
   Control Center or Siri and stopped from the Dynamic Island or the Lock
   Screen, so it often ends with the app in the background. A Metal engine
   would need a processor engine for exactly those takes: two engines in one
   app. The engine works the same in both cases; the Dynamic Island's Stop
   was tested this way in the Simulator.
6. **No binary to build and publish.** The pinned transcribe.cpp framework
   has only a macOS slice. An iOS slice would mean a new build, a new public
   release on the fork and the binary audit. The engine compiles from the
   repository's C sources for iOS as it is, with no change.

In the app, an 11-second take was written 0.3 s after it stopped (the take
page shows this time for every take).

**What was not measured: a real iPhone.** The Simulator runs iOS code on the
Mac's processor, an M4 Pro, so every time above is the M4 Pro's. An iPhone
has two performance cores and four efficiency cores, and the engine uses four
threads by default; a take will be slower than these figures. A run on a
device is the first thing to do once the app is signed for one. A lead for
then: iPhones with the A18 or later may have the matrix unit the M4 has (the
M4 Pro here reports `FEAT_SME`; check `hw.optional.arm.FEAT_SME` on the
device), and the engine's research kernel set `sme` on branch
`claude/engine-notes-m4` targets it.

## What changed outside `apps/ios`

- `Packages/DictationCore` and `Packages/LocalASR` declare iOS 17. The app
  links DictationCore's pure logic, not DictationAudio, whose capture is the
  Mac's Core Audio HAL.
- LocalASR links the CTranscribe binary only on macOS, and
  `TranscribeCppAdapter.swift` compiles to nothing on iOS. The three facts both
  adapters need (sample rate, shortest clip, the model file in a folder) moved
  to `ParakeetInput.swift`; the Metal adapter's own names for them remain.
- `LocalTranscriber.shippingEngine()` picks `OreAdapter` on iOS.
- `ProcessDiskReads` returns `nil` on iOS, whose SDK has no `proc_pid_rusage`.
- Nothing in `engine/` or `core/` changed.

## How a person gets the words out

- **Copied by default.** Each take's words go to the clipboard the moment they
  are written, local to this iPhone (`.localOnly`), so the usual flow is: talk,
  stop, switch app, paste. One switch in Settings turns it off.
- **Share** and **Copy** on every take; the take page is editable.
- **The Dynamic Island and the Lock Screen** show a take while it records,
  with a running time and Stop, then "Written and copied" with the word count,
  never the words.
- **The Action button, Control Center and the Lock Screen** get a Dictate
  control. **Siri and Shortcuts** get Dictate, Write Audio as Text (any audio
  file in, words out) and Get Latest Take.
- **Files and share sheets** can open any audio file in OpenRamble.

A custom keyboard was considered and not built: iOS gives keyboard extensions
no microphone, so a keyboard cannot record at all, whatever its memory limit.
The apps that dictate from a keyboard switch to their own app to record and
rely on getting back to the previous app, which iOS does not provide.

## Design

Studied by looking at their screens, not descriptions: Voice Memos, Journal,
Wispr Flow, Superwhisper, Whisper Memos, Aiko, Just Press Record, Granola,
Flighty (an Apple Design Award winner) and Wabi, which Mik named as the style
reference. What the app took:

- One page. The takes are the page, newest at the bottom by the thumb, set in
  New York (the system serif) at regular weight with generous leading; times
  and days in small SF. No cards, no boxes, no list chrome (Aiko and Granola
  show how far plain words carry).
- One control. A single piece of Liquid Glass with a red mark, the only red
  in the app. While recording, Discard and the running time flow out of it
  (`GlassEffectContainer`), and the page clears for the voice alone: thin
  bars, newest on the right, older ones fading (Superwhisper and Voice Memos
  give the voice the whole screen).
- Glass only where it floats: the button, the notices, the toolbars. Words
  never sit on glass.
- Quiet motion: the words arrive with a blur, "Writing…" breathes, a haptic
  marks start, stop and arrival.
- Settings is three rows and a promise.

## Reproducing the numbers

`tools/` holds the scripts. They expect the model at
`~/.openramble/release-models/…`, the FLEURS clips at
`~/.openramble/polish-loop/fleurs/`, a simulator whose id is in
`~/.openramble/ios/sim-udid`, and `ore-cli` and `tcpp-probe` built for the
Simulator: `cmake -S engine -B <dir> -DCMAKE_SYSTEM_NAME=iOS
-DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_ARCHITECTURES=arm64
-DORE_TCPP_PREFIX=<transcribe.cpp built by build-tcpp-sim.sh>`. They run the
tools inside the Simulator with `xcrun simctl spawn`. `data/` has the results;
the word dumps themselves are in `~/.openramble/ios/data/` and match the Mac's
in `~/.openramble/own-engine/parity/` byte for byte.
