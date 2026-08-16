# Parakeet v3 int8 encoder smoke

Decision: **REJECT; do not broaden or integrate.**

## Frozen scope

- Application HEAD: `f2b6e8cc66d20f7a07094f79af0faf3ba861af64`
- FluidAudio base: `ee9a7f12d91710da53de6d75f8b7160e09eccee4`
- Candidate model history revision: `e2c244912d3eeb1b8e0ffd841e9262a6376b05c3`
- Candidate `Encoder.mlmodelc/model.mil`: `a8857cf864a550445d1186aa16c558d495dcc9417feac778a10ae954af9e25e1`
- Candidate int8 weight: `c6bd24219a0fe9951da53911a2f79f4a0e8180f787ec5917462d270569dcbe3c`, 594,675,904 bytes
- Shipping 6-bit weight: `e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421`, 445,187,200 bytes
- Decoder, `JointDecisionv3`, preprocessor, and vocabulary were APFS clones of the installed shipping bundle.
- Both arms used `.all`, 15-second fixed shape, `melChunkContext=false`, concurrency 4, `maxTokensPerChunk=600`, four frozen real EN/RU fixtures, 3 warmups and 5 measurements per fixture.

## Result

| Fixture | Shipping p50 | int8 p50 | int8 regression | Shipping encoder p50 | int8 encoder p50 |
|---|---:|---:|---:|---:|---:|
| EN LibriSpeech | 46.706 ms | 52.586 ms | +12.59% | 26.134 ms | 31.802 ms |
| EN VOiCES | 37.726 ms | 41.558 ms | +10.16% | 25.844 ms | 29.124 ms |
| RU FLEURS 1 | 46.167 ms | 46.808 ms | +1.39% | 25.927 ms | 26.633 ms |
| RU FLEURS 6 | 45.196 ms | 46.075 ms | +1.95% | 25.848 ms | 26.734 ms |

Text hashes matched on all four fixtures, but all four complete token-timing/confidence hashes differed. The candidate therefore failed both the predeclared exact-output requirement and the `>=10%` speed screen. No broader run was made.

Process high-water RSS was 1,256,620,032 bytes for int8 versus 2,258,518,016 bytes for the shipping run, but this process-first high-water comparison is not sufficient to promote a model that is slower and not timing-exact. No thermal or macOS performance warning was recorded.

## Artifacts

- Shipping report: `results/shipping-a-smoke.json`, SHA-256 `36a08c9cc8bd3e47ee0dac3bcc75cd2118f21a66299bb904f76505e386b6cfaf`
- Candidate report: `results/int8-a-smoke.json`, SHA-256 `b797f35d5a1c9eaf1d87f71045111ace7015f98b65633be177f26edd9bb481f3`
