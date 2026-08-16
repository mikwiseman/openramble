# macOS 26 DictationTranscriber smoke — rejected

Date: 2026-08-14 (Europe/Moscow)

This was a bounded, on-device smoke of Apple's `DictationTranscriber` using
`progressiveShortDictation`. It was not integrated into OpenRamble. The input
was the frozen 16 kHz Float32 FLEURS fixture
`fleurs-en_us-0185-1554.f32le` (2.7 s), converted once to the analyzer's
required 16 kHz mono Int16 format and supplied in timestamped 20 ms buffers at
real-time pace. The asset was already installed; the harness never downloaded
one.

## Result

- Reference: `he built a wifi door bell he said`
- Final system text: `He bought the Wi-Fi doorbell. He died.`
- Analyzer prepare: 153.416 ms
- Audio feed wall: 2701.967 ms
- Stop to finalized result: 81.497 ms
- Thermal/performance warnings before and after: none
- Residual probe/model processes after shutdown: none

The candidate is rejected: its stop tail is slower than OpenRamble's existing
roughly 45 ms short path on this host, and the one preregistered real utterance
already has a material semantic transcription error. No broader run, Russian
asset installation, or product integration is justified.

## Frozen evidence

- Fixture SHA-256:
  `35e1ce4c8a1238d9439f4a86a600f228ae1c194be1b79e5d86d4893a3769eade`
- Harness source SHA-256:
  `4ecf80a076c43886a186756423f1517e90c3d9ac5274adf1353654d0039ec06a`
- Harness binary SHA-256:
  `ab1434d61f77717e187f63485935fb2c9472b8e08c6270868b7a88cb1fbafbd0`
- Raw report: `en-2.7-paced.json`
- Raw report SHA-256:
  `6d52a9461ed57cd952f3bd377706dcde4f42fe6afadc2cd43f54cf4a8568698e`
