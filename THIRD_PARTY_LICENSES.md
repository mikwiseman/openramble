# Third-party components

OpenRamble distributes or downloads the following third-party components.

## Speech-recognition models

### Parakeet TDT 0.6B v3

Copyright NVIDIA. Licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

- Original model: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- Converted distribution:
  https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- Pinned revision: `aed02740059203c4a87495924f685de3722ae9ce`

Changes from the original: FluidInference converted the model to Core ML and
quantized the encoder with six-bit palettization and mixed precision. Open
Ramble downloads 21 files totaling 483,105,645 bytes and verifies each file's
SHA-256 checksum.

### Parakeet TDT-CTC 110M

Copyright NVIDIA. Licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

- Original model: https://huggingface.co/nvidia/parakeet-tdt_ctc-110m
- Converted distribution:
  https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml
- Pinned revision: `accdafd8cf8a2ff1cabe3c11e54416b405d409aa`

Changes from the original: FluidInference converted the vocabulary-prompt
model to Core ML with mixed precision. OpenRamble downloads 16 files totaling
102,803,869 bytes and verifies each file's SHA-256 checksum.

Model weights are not stored in this repository or bundled in the application.
The user downloads them explicitly from the app.

## Libraries bundled with the application

| Component | Version | License | Purpose |
|---|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.15.5 | Apache 2.0 | Core ML Parakeet runtime |
| [Sparkle](https://sparkle-project.org) | 2.9.4 | MIT | Application updates |

The dependencies are pinned by immutable commit:

- FluidAudio: `19600a485baa4998812e4654b70d2bab8f2c9949`
- Sparkle: `b6496a74a087257ef5e6da1c5b29a447a60f5bd7`

The DMG includes complete license texts as `FluidAudio-Apache-2.0.txt` and
`Sparkle-LICENSE.txt`.

FluidAudio also contains code from:

- fastcluster, copyright 2011 Daniel Müllner and later changes copyright
  Google Inc., BSD 2-Clause License;
- VBx, copyright 2021–2024 BUT Speech@FIT, Apache License 2.0.

OpenRamble does not use their speaker-separation features, but the code is
present in the distributed framework, so their full notices are included in the
DMG as `FluidAudio-fastcluster-BSD.txt` and `FluidAudio-vbx-Apache-2.0.txt`.

The CC BY 4.0 text for the model weights is included as
`Parakeet-CC-BY-4.0.txt`.

## Not covered by the source license

The OpenRamble name and application icon are not covered by the source-code
license.
