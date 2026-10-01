# Current-runtime benchmark infographic

[Current benchmark infographic](benchmark-2026-10-01-v2.png) summarizes the already measured
Q8 model configurations on the same M4 Mac mini. It compares model configurations
in the existing OpenRamble pipeline, rather than complete competing applications.

The table copies the rounded app WER point estimates and source counts from
[RESULTS](../RESULTS.md), [main](../main/REPORT.md),
[GigaAM main](../giga-main/REPORT.md) and [FLEURS](../holdout/REPORT.md).
A bold row minimum is not a statistical-significance statement. Different domains
are not averaged. Failure outcomes and numeral formatting remain in strict WER.

The two speed panels keep their measurement scopes separate:

- The left panel copies the CV19 RU file p95 values from the
  [first-pass main report](../main/REPORT.md): Parakeet 146 ms,
  Turbo 1378 ms and Breeze 2190 ms, each on the same 500 files.
  These screening measurements include file decoding and ASR and may overlap
  corpus preparation. They are not repeated idle or GUI measurements.
- The right panel uses the [repeated idle protocol](../runtime/idle-latency.json):
  Parakeet RU p95 151–152 ms and GigaAM CTC 75 ms. It excludes model loading,
  file decoding, capture and GUI insertion. The Parakeet bar uses 152 ms.

Parakeet and GigaAM use one CPU decoder thread; Turbo and Breeze use four.
The table compares different model configurations. It does not isolate the
effect of changing a model's thread count or compare OpenAI/GigaChat cloud
services or competing complete applications. No universal winner is asserted.

The second version removes the recommendation badge, long-recording and memory
panels and explanatory cards, retaining benchmark metrics and scope labels.
The [first version](benchmark-2026-10-01.png) and its
[prompt](benchmark-2026-10-01.prompt.txt) remain available for provenance.

Generated with the built-in image-generation tool. Its callable interface does
not expose a selectable or verifiable model version; no GPT-Image 2.5 identity
is asserted. The [exact redesign prompt](benchmark-2026-10-01-v2.prompt.txt) is retained.
The rendered labels, numerical values, sample counts and scope notes were
visually checked against those reports.

Current PNG: 1536 × 1024; 1,488,695 bytes.
SHA256: `e44ef6c58e3e2d3c49325d07d7bf9487289578f8eba22c91de2103e96468bf92`.

First-version PNG: 1536 × 1024; 1,600,558 bytes.
SHA256: `2163e9da532911f8d3bd8559cffc532ef2da4c2333239ff87d63cc7f563e2d1a`.
