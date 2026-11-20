# Third-party components

OpenRamble distributes or downloads the following third-party components.

## Speech-recognition models

### Parakeet Ultra, GGUF conversion

Copyright Moondream. A post-trained version of NVIDIA's Parakeet TDT 0.6B v3.
Licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

- Original model: https://huggingface.co/moondream/parakeet-ultra
- Based on: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- Converted distribution:
  https://huggingface.co/handy-computer/parakeet-ultra-gguf
- Pinned revision: `a1539be1b849ea7463b88343e5277b373d0c4ea9`

Changes from the original: handy-computer converted the model to GGUF and
quantized it. On macOS OpenRamble uses the Q4_K_M quantization, one file of
486,280,096 bytes; on Windows and Linux it uses Q8_0, one file of 740,363,168
bytes. Each is verified against its SHA-256 checksum, and both are mirrored
byte for byte as release assets of this repository (`models-a1539be1`), which
the app tries first.

### Parakeet TDT 0.6B v3, GGUF conversion

Earlier versions of OpenRamble downloaded this model. An existing install keeps
using it until Parakeet Ultra is downloaded and verified, and then removes it.

Copyright NVIDIA. Licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

- Original model: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- Converted distribution:
  https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf
- Pinned revision: `85ac09ea12fc4b1112fa76810059364bc6adc9de`

Changes from the original: handy-computer, the authors of transcribe.cpp,
converted the model to GGUF for transcribe.cpp. OpenRamble used the Q8_0
quantization: one file of 739,508,576 bytes, verified against its SHA-256
checksum. The same file is mirrored byte for byte as a release asset of this
repository (`models-85ac09ea`), which the app tries first.

Model weights are not stored in this repository or bundled in the application.
The user downloads them explicitly from the app.

## Libraries bundled with the application

| Component | Version | License | Purpose |
|---|---|---|---|
| [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) by CJ Pais and the Handy team | 0.4.1 with three changes, from [our fork](https://github.com/mikwiseman/transcribe.cpp/releases/tag/v0.4.1-dacdba09) | MIT | GGUF speech-recognition runtime on Metal |
| [Sparkle](https://sparkle-project.org) | 2.9.4 | MIT | Application updates |

The dependencies are pinned immutably:

- transcribe.cpp: the `TranscribeCpp.xcframework.zip` asset of our fork's release
  `v0.4.1-dacdba09`, SHA-256
  `f181b34da5aa9896bced3d9d0da4ad3a2b7d3b8028f0174abeb9c74449bf7d3d`
- Sparkle: `b6496a74a087257ef5e6da1c5b29a447a60f5bd7`

transcribe.cpp vendors three libraries, whose notices ship with it:

- ggml, MIT License — the tensor library the runtime is built on;
- miniz, MIT License — used for reading model archives;
- Silero VAD, MIT License — the runtime's voice-activity segmentation is
  translated from it.

The DMG includes the complete license texts as `transcribe-cpp-MIT.txt`,
`ggml-MIT.txt`, `miniz-MIT.txt`, `silero-vad-MIT.txt` and
`Sparkle-LICENSE.txt`.

The CC BY 4.0 text for the model weights is included as
`Parakeet-CC-BY-4.0.txt`.

## Not covered by the source license

The OpenRamble name and application icon are not covered by the source-code
license.
