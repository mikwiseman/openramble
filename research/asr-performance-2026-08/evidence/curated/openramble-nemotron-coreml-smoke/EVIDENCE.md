# Official Nemotron multilingual CoreML stop-tail smoke

Decision: **REJECT / do not broaden or integrate**.

## Frozen inputs

- FluidAudio revision: `ee9a7f12d91710da53de6d75f8b7160e09eccee4`
- Model repository: `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`
- Model revision: `1a41b75758b0337ff67db7d5408280aaaf23074e`
- Variant: `multilingual/2240ms`, full 13,087-token vocabulary
- Compute route requested: `MLComputeUnits.cpuAndNeuralEngine`
- FLEURS revision: `70bb2e84b976b7e960aa89f1c648e09c59f894dd`
- Fixture manifest SHA-256: `5ed6aa08789ad8d526f414d2261e527f29fab62377d2e7a66a4c99e367a01d3a`
- Harness source SHA-256: `1d3dc373bcab0d960e0a6b9a160aad129bfcc227212f7d7a4ffae4134357e3e2`
- Harness binary SHA-256: `8edfc42e423b2606d46e82041d75f55899577d51492cddc3334dcd4ea154fe3c`
- Report SHA-256: `d697d7d652179dcd2a42c0fc5a3de2815d38bb0544a5ea13be96760e34233b6`

The exact metadata maps both `ru` and `ru-RU` to prompt id 11; `en` and
`en-US` map to prompt id 0. Model assets were downloaded from immutable
`resolve/<revision>/...` URLs. The two large LFS files matched the repository
SHA-256 values:

- encoder weight: `2e00be98049a22e095452c020f183d2b23728e145cc814ba031436931b4f2e8f`
- fused decoder/joint weight: `01f21eb747fbc53bd0ed7efebea1bf0aa655ebf2816f21d0bb6554c9b7fcfc0b`

OpenMDW-1.1 permits commercial use and redistribution, subject to retaining
the license and applicable origin/copyright notices. The pinned license copy
has SHA-256 `2ab44b68365473c112f5092211a38f231cb23e50de68b75a13369adbd76a74df`.

## Method

One persistent manager loaded and internally warmed the model. Each of four
real 16 kHz Float32 fixtures ran once as a warmup, then three measured times.
For every session, all complete 2.24-second chunks were processed before the
Stop boundary; only `finishWithTokenTimings()` was included in `finish_ms`.
This is the relevant product stop-tail measurement, not total offline RTFx.

## Performance

- Cold load including built-in model warmup: 9,473.930 ms
- Process high-water RSS: 0.596 GiB
- Warm `finish()` across 12 measurements: median 36.505 ms, min 29.701 ms,
  small-sample p95 39.925 ms, max 40.490 ms
- Pre-Stop complete-chunk processing: median 65.679 ms, max 88.269 ms; this
  work is eligible to run under speech in a real streaming capture path
- No model process remained and macOS recorded no thermal/performance warning

This is only about 20% below the current roughly 45 ms short-dictation path,
not a 10x gain.

## Quality falsification

All three measured repetitions were exactly stable per fixture, but the four
fixture smoke already showed a material quality regression:

| Fixture | Frozen reference | Current shipping TDT | Nemotron streaming |
|---|---|---|---|
| EN 0000 | when you call someone who is thousands of miles away you are using a satellite | When you call someone who is thousands of miles away, you are using a satellite. | When you call someone who is thousands of miles away, you're using a satellite |
| EN 0003 | then lakkha singh took the lead in singing the bhajans | Then Laka Singh took the lead in singing the Bashams. | Then lock a thing to delete and singing the Pashans |
| RU 0006 | о первых случаях заболевания в этом сезоне было сообщено в июле | О первых случаях заболевания в этом сезоне было сообщено в июле. | О первых случаях заболевания в этом сезоне было сообщено в июле |
| RU 0012 | как только вы выйдете из течения плыть обратно будет не труднее чем обычно | Как только вы выйдете из течения, плыть обратно будет нетруднее, чем обычно. | Как только вы выйдете из течение, плыть обратно будет не труднее, чем обычно |

A simple frozen Unicode/lowercase/punctuation-stripped word edit score was
4/49 errors for shipping versus 10/49 for Nemotron. The exact percentage is
not a publishable quality estimate at n=4; it is only a hard-stop falsifier.
The severe EN 0003 semantic corruption is sufficient to reject broadening.
Every emitted token reported confidence 1.0, including the corrupted output,
so confidence cannot safely select a fallback.

## Product conclusion

Do not integrate this backend, do not advertise its timing, and do not spend a
broad blinded corpus run on it. A hybrid selector has no reliable confidence
signal, while running the shipping model as a universal verifier would erase
the small stop-tail gain. Long-form exact closed-window caching remains the
stronger route because it preserves the shipping transcript/token semantics.
