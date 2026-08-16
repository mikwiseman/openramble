# Lean JointDecision auto-language A/B (aed0274)

Decision: **REJECT / do not integrate or broaden**. The lean graph is a real
micro-optimization, but it misses the predeclared product gate (at least 10%
end-to-end with no slower fixture).

## Frozen setup

- OpenRamble HEAD: `f2b6e8cc66d20f7a07094f79af0faf3ba861af64`
- FluidAudio base: `ee9a7f12d91710da53de6d75f8b7160e09eccee4`
- Official model revision: `aed02740059203c4a87495924f685de3722ae9ce`
- Shipping A: `JointDecisionv3.mlmodelc`
- Candidate B: official `JointDecision.mlmodelc`, installed under the v3 file
  name only inside the isolated candidate tree.
- Four frozen real fixtures, 2 English + 2 Russian, all with `language = nil`.
- Persistent process per arm; 3 warmups and 5 timed repeats; ABBA order, giving
  10 A and 10 B timed observations per fixture.
- Shipping configuration: 15 s, `.all`, encoder `.all`, mel context off,
  concurrency 4, max tokens 600, dual arbitration off, resetData false.
- Harness SHA-256:
  `db6aed3be6c3521db3b695e2b5536a7d32bea87a82c1f9f8d33c4fbafc5b1049`.
- Auto manifest SHA-256:
  `2f35cb1e43f09a71b3e5a0656b5ad11ef2d2b11f4c927a9633cec7cc7e51e7f4`.

The two graphs have exactly the same two inputs and the same mandatory
`token_id`, `token_prob`, and `duration` outputs. Their weight file is
byte-identical (`4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e`,
12,642,764 bytes). The lean MIL omits exactly the v3 `topk` operation and the
mandatory `top_k_ids`/`top_k_logits` outputs. Its MIL SHA-256 is
`2cb084d7e0dc86ad3ddaa53a9631cdd5d97f19839218845b0e65ca065a4d1a5e`;
shipping v3 is
`be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d`.
This substitution is valid only for auto-language decoding; explicit-language
script filtering consumes top-K and must keep v3.

## Result

All four fixtures were stable within every arm. Transcript SHA and the full
token/timing/confidence SHA were bit-identical between A and B on 4/4 fixtures.

| Fixture | A wall p50 | B wall p50 | E2E win | A joint p50 | B joint p50 | Joint win |
|---|---:|---:|---:|---:|---:|---:|
| LibriSpeech EN | 45.677 ms | 45.123 ms | 1.21% | 10.240 ms | 6.542 ms | 36.11% |
| VOiCES EN | 37.542 ms | 35.677 ms | 4.97% | 5.961 ms | 3.721 ms | 37.58% |
| FLEURS RU 1 | 45.806 ms | 42.132 ms | 8.02% | 11.068 ms | 6.768 ms | 38.86% |
| FLEURS RU 6 | 44.954 ms | 41.864 ms | 6.87% | 9.973 ms | 6.280 ms | 37.03% |

The equal-fixture pooled arithmetic mean was 43.874 ms A versus 41.172 ms B,
a 6.16% end-to-end win. Joint prediction itself improved 37.67%, but the fixed
encoder and other work dominate the short path. The first unseen specialization
of B took 13.939 s and reached a 2,257,862,656-byte process high-water mark;
the already-specialized repeat loaded in 103.7 ms. Those cold figures are
diagnostic only because A's original first specialization was not re-created.

The result is exact and positive, but below the 10% product gate, applies only
to auto-language, and would require shipping/loading a second joint graph while
retaining v3 for explicit-language decoding. It is therefore not worth the
extra artifact, lifecycle, and routing complexity.

## Frozen raw reports

- A1 `af2b414e2d873c91ccc364345f7481646a39a4b84366f05b2039da537cf784cf`
- B1 `b058f57963dabb847bf6d5c16600b2e22afe5b3757f0f5617bfb080b40e71918`
- A2 `5bd7e752adf5fa3e8f9f7679156c1e5f234f59b294f532653cc54aec8c1122bb`
- B2 `d0b83160a744e5a9ef372d8bb08c9ceba035eba1f8dfbf2ca6cd45952dbd1cda`

No shared-repository file was changed. At handoff there was no phase-bench,
asr-bench, OpenRamble worker, or Core ML compiler process, and `pmset -g therm`
reported no thermal/performance/CPU-power warning.
