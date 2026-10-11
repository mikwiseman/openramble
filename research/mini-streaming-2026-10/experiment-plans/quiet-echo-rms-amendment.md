# Additional echo falsifier, before quiet-candidate tests or inference

Source inspection on 11 October found that CrossTalkGate activates at system
RMS 0.005, while the proposed meeting activity threshold is a peak of 0.005.
They are different quantities. A sparse waveform can cross the proposed peak
threshold while remaining below the echo gate's RMS threshold. Therefore the
existing continuous-noise echo fixtures do not cover this specific interaction.

Add two fixed cases, using the existing echo fixtures with and without their
leading silence. Keep their seed, three-second length, 30 ms echo delay,
one-half microphone gain, block sizes, policy minimum and only-system-segment
assertion. Use system peak 0.03, as in the already registered quiet echo case,
but retain only the first 80 samples of each 1600-sample period, setting the
rest to zero. The microphone remains the delayed half-amplitude copy.

The system noise's long-window RMS is approximately 0.00387, below 0.005;
its microphone peaks can still exceed the candidate activity threshold.
Run both the current 0.02 activity threshold and the candidate 0.005 on these
two cases. Both must emit only the system segment. A new microphone segment
rejects changing the meeting threshold alone, regardless of public-speech WER.

No production echo parameter is changed. Do not fit a different RMS threshold
to make these cases pass. This is an additional prospective falsification of
the one fixed candidate, not an amendment that relaxes its original gates.
The original quiet protocol and its seal remain unchanged. Complete the
registered speech/noise map for diagnosis even if this echo gate fails, but
keep the second heldout set sealed after any failed development or echo gate.
