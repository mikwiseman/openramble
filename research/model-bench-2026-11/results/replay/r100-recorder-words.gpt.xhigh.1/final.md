Fixed both recording bugs in local commit `07e04f9`.

- The pause detector skipped one second of retained audio in its frame count, cutting into the last words. Cuts now land inside the pause.
- Quiet callers were filtered out by the microphone’s speech threshold. System audio now has a lower threshold, and I lowered the health-check tone to keep it out of transcription.

All 818 DictationCore package tests passed, including speaker-echo rejection. Live-call verification requires dependencies unavailable in this offline checkout.
