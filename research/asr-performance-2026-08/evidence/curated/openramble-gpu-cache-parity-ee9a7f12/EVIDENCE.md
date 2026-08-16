# Cross-device closed-window cache falsifier

Decision: **REJECT** GPU/CPU speculation as the producer of an exact ANE final
cache. No product or shared-repository integration.

## Question and hard gate

Could a speculative process run the shipping Parakeet graph without using ANE,
then hand completed raw token windows to the ordinary ANE final path without
changing any transcript, token ID, timestamp, duration, or confidence bit?

The predeclared gate was exact full token/timing/confidence parity on all four
frozen real EN/RU fixtures. Any crash or bit mismatch stopped the experiment
before building the portable long-form cache.

## Setup

- OpenRamble HEAD `f2b6e8cc66d20f7a07094f79af0faf3ba861af64`
- FluidAudio `ee9a7f12d91710da53de6d75f8b7160e09eccee4`
- Exact shipping model revision `aed02740059203c4a87495924f685de3722ae9ce`
- Shipping route A: configuration/encoder/decoder/joint `.all`
- Independent route B: configuration+encoder `.cpuAndGPU`, decoder+joint
  `.cpuOnly`; therefore no component is allowed to choose ANE
- 15 s model, mel context off, concurrency 4, max tokens 600, forced EN/RU
- 6 warmups + 5 timed repeats per fixture in a persistent process
- Harness SHA-256
  `1c7507c913a554a5ab8e20616d8215f79b5bd2ffb2f8f901959c24957d837ed6`

A stricter all-`.cpuAndGPU` route was attempted first and aborted inside
MPSGraph before producing a report:
`MPSGraphTensorData.mm:223: failed assertion shape.count = 0 != strides.count = 3`.
Its stderr SHA-256 is
`46b513778ddfcb73897ef5ac652d6f4256e86665f41bbb955f6a1e01c4906c1d`.

## Result

The GPU-encoder/CPU-decoder route was deterministic within itself and produced
the same final text on 4/4 fixtures, but failed the exact cache gate on all 4:

- full token/timing/confidence hash: 0/4 exact;
- confidence bits: 0/4 exact (maximum absolute per-fixture deltas ranged from
  0.00048826 to 0.02661134);
- token IDs/text/start/end only: 3/4 exact; LibriSpeech shifted one token
  boundary by 80 ms (`af` ended at 1.92 s instead of 1.84 s).

It was also much slower: fixture p50s were 100.69–108.54 ms versus
37.64–46.43 ms on A. Initial B model loading took 5.250 s and the process
high-water mark reached 2,629,615,616 bytes.

Therefore an imported B window would not be the same semantic artifact that A
would have produced. Treating only final text as equivalent would silently
change word timing, confidence, downstream candidate-region/vocabulary input,
and long-window merge behavior. The proposed cross-device cache is closed.

## Raw evidence

- A report SHA-256
  `54e18d171bdf988d0e225613abb5712a361f53938c96d457185f6336fcedc5f8`
- B report SHA-256
  `544d3e882d45c42bf0d1a278a43eee8d703301bc94fed2ba5974a1d109a447c8`

At handoff no phase-bench/asr-bench/OpenRamble worker/Core ML compiler process
remained, `pmset -g therm` reported no warnings, and the shared checkout was
clean.
