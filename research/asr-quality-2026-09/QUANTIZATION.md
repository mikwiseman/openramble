# Shipping-checkpoint precision screen

A separate exploratory extension, declared before inference. It tests the
five additional published precisions of the exact shipping 25-language
checkpoint at the original immutable revision, rather than changing its
training, language hint, decoder thread count or text pipeline. The original
Parakeet/Turbo/Breeze comparison stays frozen.

Source: [immutable model files](https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf/tree/85ac09ea12fc4b1112fa76810059364bc6adc9de), CC BY 4.0.
The API blob metadata was saved and its revision/Q8 hash agree with shipping.

| Preset | Bytes | SHA256 |
|---|---:|---|
| Q4_K_M | 485425504 | `b68557be1e3c40207fd7c4bd9d63f1d3316b963f15325bfb0cc16a8bb0ffd181` |
| Q5_K_M | 548946272 | `cc722e76adc1a629fc0b2535de879d99b8160d07ad4c0215e2ca7d7ea0ae4b8f` |
| Q6_K | 610342240 | `ab1bbcbe3e1c4c2ec12ca1df1aeafd22e9043ce7262e4b5f5c5d7d76418a9ae8` |
| F16 | 1255869856 | `d9ec7e2c39da7b4fec3e01e71e82c7f7bbe97741e08c0c054091bf3d520a41d3` |
| F32 | 2508435616 | `bbd36acd8c6fbb817e658e3acc9f75002cb6a74932c687e74fefccfcc7b9f47e` |

Plan SHA256: `6d2e1cc935a898f2c3a09dc166d834cd660b8c9770653b892045f95d0eb73126`. All use the sealed v2 CLI, one decoder thread
and the unchanged baseline Rust text binary on the same 100 RU + 100 EN
development inputs. Reuse exact existing v2 baseline outputs. Download and
verify every weight first; no downloads overlap inference. Preserve load or
inference failures. First-pass quality timing is a screen, not a fresh idle
speed gate. The original >=10% relative WER / <=0.5 pp other-language
regression and held-out/latency gates still apply. Any extension past this
screen must be declared before its inference. No published model-card score
is substituted for a measurement here.

## Measured development screen

All five additional presets completed the same 200 examples without failure.
The [aggregate comparison](parakeet-quant-dev/REPORT.md) and
[paired intervals / provenance](parakeet-quant-dev/comparison.json) reuse the
unchanged shipping Q8 baseline from the exact v2 development series.

| Preset | EN app WER | RU app WER | EN file p95 | RU file p95 | Process peak MiB |
|---|---:|---:|---:|---:|---:|
| Q8_0 shipping | 7.95% | 4.90% | 147 ms | 157 ms | 897.3 |
| Q4_K_M | 8.36% | 5.15% | 143 ms | 151 ms | 637.4 |
| Q5_K_M | 7.65% | 5.40% | 145 ms | 154 ms | 725.2 |
| Q6_K | 7.95% | 5.28% | 137 ms | 153 ms | 777.7 |
| F16 | 8.15% | 4.90% | 132 ms | 144 ms | 1399.1 |
| F32 | 8.05% | 4.90% | 140 ms | 153 ms | 2555.7 |

No preset reaches the declared 10% relative WER improvement. Q5_K_M's EN
reduction is only 3.85% relative; its RU point estimate is +0.5025 percentage
points, just above the other-language limit. Both paired intervals cross
zero, so this is not a claim of statistically established improvement or
regression. Higher precision does not establish an accuracy advantage here.
Equal aggregate WER is not a proof of identical transcripts.

Q4_K_M lowers peak process memory by about 29% on this screen, with a smaller
file. These first-pass timings use an earlier reused baseline and are not a
fresh idle speed gate. No candidate is promoted to a held-out replacement
trial merely because its file or memory is smaller. Keep shipping Q8_0;
this development result does not establish quality on the main/holdout sets.
