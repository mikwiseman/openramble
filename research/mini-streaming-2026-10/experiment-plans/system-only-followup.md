# Conditional next hypothesis: quieter system audio, unchanged microphone

Registered after the capture echo falsifiers but before the speech/noise
inference results of quiet-meeting-v1 are inspected. The global 0.005 threshold
failed the sparse echo fixtures. The microphone threshold and CrossTalkGate
must not be relaxed to make that candidate pass.

The system channel is the tapped playback source, not the echo-contaminated
microphone. A channel-specific default could recognize quiet remote speech
while leaving the microphone's existing 0.02 behavior exactly intact. This is
a different, narrower candidate, not a reversal of the global rejection.

Proceed only if the complete registered speech/noise development map passes
all of its native gates. If it fails any native gate, reject this follow-up
without another threshold or noise-filter sweep: changing channel labels
cannot repair that failed quality, hallucination, memory or decode-budget
condition.

If eligible, use exactly 0.005 for the default system capture policy and 0.02
for the microphone, with every other parameter unchanged. Explicitly supplied
capture parameters must retain their old meaning. Do not change shared
dictation defaults, CrossTalkGate activation/correlation, or preserve-all.

Require a failing-then-passing default capture test: quiet system speech must
emit a system segment; equally quiet microphone-only input must retain the
old behavior; active loud independent microphone speech must remain present.
Both ordinary and sparse echo fixtures, with and without leading silence,
must emit only the system channel under the new per-channel default. Existing
capture lifecycle and cross-talk tests must pass. The same numeric policy has
already been fixed for speech/noise inference, so this step does not select a
new amplitude from the development outputs.

Only after these gates pass may this new candidate open the still-unread
second sealed selection of 50 RU and 50 EN phrases. Use each phrase once per
language composite, 0.5-second gaps, both 0.02 and 0.005 system-channel policies,
one pass each. Require the same fixed English gain of at least 10 percentage
points, no RU WER or deletion regression above 0.5 points, no English deletion
regression, no memory warning, and a maximum single decode of two seconds.
No retuning on this holdout. The original global candidate remains rejected.

The report must describe this as a system-audio improvement only, if it passes.
It would not solve quiet microphone speech or establish performance in every
real room, microphone, remote-call codec or simultaneous-talk condition.
