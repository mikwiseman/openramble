# Bounded follow-up: quiet speech and echo, registered before its inference

The completed coverage study located substantial English speech loss before
recognition. Correcting the retained-prefix offset does not fix this. The
existing imported-audio preservation flag recovers much of the speech but is
not automatically appropriate for live two-channel capture.

## First falsifier: preserve-all and cross-channel echo

MeetingCapture records the original microphone waveform and masks only its
peak values when cross-talk is classified as echo. MeetingSegmentPolicy's
preserveQuietAudio option ignores the absence of speech evidence. Therefore
turning this imported-audio option on for live capture may re-submit the very
microphone intervals that the echo gate suppressed.

After the current frozen native cohorts finish, run the two existing capture
echo fixtures with preserveQuietAudio enabled, retaining their assertion that
only the system channel produces a segment. Keep the expected negative result
as hypothesis evidence, not as a permanently failing test in the main suite.
If it reproduces, reject globally enabling preserve-all without further ASR
measurements: the preserved microphone samples contain the original echo.

## One narrower candidate, no threshold sweep

Compare the corrected meeting policy at speechPeak 0.02 versus 0.005, with
preserveQuietAudio false in both. This is a single fourfold amplitude change
(about 12 dB), fixed before candidate inference, not a fitted detector or a
claim that amplitude alone identifies voice. All pause lengths, caps and
cross-talk rules stay unchanged. Masked echo remains a zero peak and does not
become positive speech evidence at either threshold.

Use the four existing original-level RU/EN minute and six-minute inputs, one
pass per policy in alternating order, in the same new binary. Record every
submitted interval, coverage, transcript, word errors, deletions, decode-call
durations and resource failure. Do not pool timing with earlier binary cohorts.

Add five deterministic 20-second negative inputs, with frozen PCM hashes:
digital silence; seeded uniform noise bounded by 0.003; seeded uniform noise
bounded by 0.01; a 50 Hz sine with peak 0.01; and 1 ms clicks of peak 0.3 every
two seconds. Use the same sample rate and sample format as the speech inputs.
The candidate must produce no normalized words on every negative input.
Count decoder calls and their total time explicitly: correct empty text does
not imply zero background work. Empty-reference cases use emitted word counts,
not a fabricated WER denominator.

Development gate: English minute and six-minute WER must each fall by at least
10 percentage points; neither RU WER nor RU deletion rate may rise by more
than 0.5 points; English deletion rates must not rise. Require no new memory
warning, no nonempty negative-input transcript, and no single decode above the
existing two-second meeting queue budget on this normal-desktop experiment.
The measured extra background work remains a reported tradeoff.

Run both existing echo fixtures at 0.005, plus their lower-amplitude equivalent
(system samples 0.03 peak, delayed microphone echo 0.015 peak), with
preserveQuietAudio false. Only the system channel may emit speech segments.
Keep silence-only and lifecycle tests intact. No global SpeechSegmenter default
or dictation pause rule is changed by this experiment.

Only if all development/negative/echo gates pass, validate the fixed candidate
on another sealed set of 50 unique RU and 50 unique EN phrases, disjoint by
recording ID, normalized phrase and audio hash from both development and the
first file-policy holdout. Seal metadata before reading its audio or outputs.
Build one composite per language containing all 50 whole phrases exactly once,
with the existing 0.5-second gaps, and report its actual duration;
evaluate both thresholds. Require the same English gain and mono regression
gates. Do not adjust the threshold after inspecting that set.

This would still be a bounded public-speech and synthetic-noise test, not a
claim covering real meetings, every microphone, room noise or acoustic echo.
An adoption decision must retain these limitations and actual background cost.
If any gate fails, preserve the negative result and leave the live default
unchanged. No extra amplitude/threshold sweep is implied.
