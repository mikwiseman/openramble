# macOS 26 SpeechTranscriber smoke — rejected

Date: 2026-08-14 (Europe/Moscow)

This was one bounded, on-device smoke of Apple's newer `SpeechTranscriber`
using `timeIndexedProgressiveTranscription`. It was not integrated into
OpenRamble. The input was the frozen 16 kHz Float32 FLEURS fixture
`fleurs-en_us-0185-1554.f32le` (2.7 s), converted once to the analyzer's
required 16 kHz mono Int16 format and supplied in timestamped 20 ms buffers at
real-time pace. The English asset was already installed; the harness never
downloaded one.

## Result

- Reference: `he built a wifi door bell he said`
- Final system text: `He built a Wi-Fi doorbell.  he said.`
- Analyzer prepare: 114.485 ms
- Audio feed wall: 2705.056 ms
- Stop to finalized result: 60.732 ms
- Thermal/performance warnings before and after: none
- Residual probe/model processes after shutdown: none

The candidate is rejected. Its stop tail is slower than OpenRamble's existing
roughly 45 ms short path on this host, so it cannot improve the product's
current latency, let alone approach the requested order-of-magnitude gain.
`SpeechTranscriber` also does not expose a `ru_RU` locale on this machine, so
it cannot be a universal English/Russian route. The transcript quality on this
single English utterance was good; that does not justify a broader quality run
after the latency and locale gates failed.

## Frozen evidence

- Fixture SHA-256:
  `35e1ce4c8a1238d9439f4a86a600f228ae1c194be1b79e5d86d4893a3769eade`
- Generic harness source SHA-256:
  `e39cd66da0c0836ca5f341931bbbda0bde8fa33f7a31ec02cd699dbcd69d46e0`
- Harness binary SHA-256:
  `5838b829b337ce0f6a60ac52b9667d1870f0dabf733fce0bb98d47cda77170d0`
- Raw report: `en-2.7-speech-paced.json`
- Raw report SHA-256:
  `541376540e89e073c29e0656623058a49a369b5ce5664ac3433b6f251718e5d6`
