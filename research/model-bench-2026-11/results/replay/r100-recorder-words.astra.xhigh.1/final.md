Fixed both recording bugs in local commit `424dd23` on `work`.

- After a long silence, transcript cuts could land one second early and clip the last words. They now land inside the pause.
- Quiet callers now reach transcription through the system-audio channel. I used the recorder’s existing audibility threshold there and kept the microphone’s sensitivity and echo filtering intact.

All 816 DictationCore tests passed, including both regressions and the speaker-leak tests. End-to-end recognition and Rust bridge tests were blocked by frameworks missing from the offline checkout.
