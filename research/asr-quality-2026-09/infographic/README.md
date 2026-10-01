# Current-runtime benchmark infographic

[Benchmark infographic](benchmark-2026-10-01.png) summarizes the already measured
Q8 model configurations on the same M4 Mac mini. It compares model configurations
in the existing OpenRamble pipeline, rather than complete competing applications.

The table copies the rounded app WER point estimates and source counts from
[RESULTS](../RESULTS.md), [main](../main/REPORT.md),
[GigaAM main](../giga-main/REPORT.md) and [FLEURS](../holdout/REPORT.md).
A bold row minimum is not a statistical-significance statement. Different domains
are not averaged. Failure outcomes and numeral formatting remain in strict WER.

The latency panel uses the separate [repeated idle protocol](../runtime/idle-latency.json):
Parakeet RU p95 151–152 ms and GigaAM CTC 75 ms, with their fresh-process memory
rounded to about 896/332 MiB. It excludes model loading, file decoding, capture
and GUI insertion. Turbo/Breeze first-pass timings are not mixed into this panel.

The long-file panel is the single-parent offline RU diagnostic and the mixed
omission diagnosis, not the outstanding primary Eleven series. See
[RU](../system-long-diagnostic/PROTOCOL.md),
[mixed](../system-long-extra/PROTOCOL.md) and
[rejected 20-second windows](../window20-diagnostic/PROTOCOL.md).

Generated with the built-in image-generation tool. Its callable interface does
not expose a selectable or verifiable model version; no GPT-Image 2.5 identity
is asserted. The [exact prompt](benchmark-2026-10-01.prompt.txt) is retained.
The rendered labels, numerical values, sample counts and scope notes were
visually checked against those reports.

PNG: 1536 × 1024; 1,600,558 bytes.
SHA256: `2163e9da532911f8d3bd8559cffc532ef2da4c2333239ff87d63cc7f563e2d1a`.
