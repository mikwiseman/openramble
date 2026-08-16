# Source-only audit: a genuine EN+RU cache-aware streaming ASR candidate

Audit time: 2026-08-14T21:14:43Z

Scope:

- Read-only OpenRamble/FluidAudio inspection.
- Primary model cards, source repositories, build files, and API metadata only.
- No model weights, ONNX files, GGUF files, Core ML models, or inference were downloaded or run.
- No Core ML/ANE/model slot was used.
- All temporary checkouts are under $TMP/openramble-asr-candidate-audit-f2b6ee9a.

Evidence labels used below:

- OBSERVED: directly present in pinned source or primary API metadata.
- CALCULATED: arithmetic from observed shapes/sizes.
- UNVERIFIED: requires the separately authorized model smoke.

## Decision

Select exactly one candidate for a future bounded smoke:

1. **PengChengStarling multilingual streaming Zipformer transducer**, using the
   official sherpa-onnx optimized ONNX package and sherpa-onnx CPU runtime.

This is a **conditional Stage-1 candidate**, not a product feasibility finding.
It satisfies the architectural screen: English and Russian are explicitly
trained/supported, the encoder is causal and exports reusable state tensors, the
model license is Apache-2.0, the native runtime is local/offline on macOS arm64,
and the product payload is 339,349,396 bytes (323.629 MiB).

Two issues must hard-stop the future smoke if they cannot be resolved exactly:

1. The model requires an explicit language tag as the decoder's initial token.
   Current upstream sherpa-onnx initializes streaming transducers with blank ID
   0 and exposes no generic online-transducer language field.
2. The primary model card publishes aggregate claims and results for six other
   languages, but **does not publish EN or RU WER/CER**. EN/RU quality must be
   measured on our frozen fixtures before any broader lane.

The smallest acceptable runtime seam is a fail-closed
CreateOnlineStreamWithInitialToken-style API in a temporary sherpa-onnx fork.
It must verify that the pinned tokens.txt maps exactly to the requested EN/RU
tags before seeding the decoder result, and it must seed the token before the
first decoder call. No graph or weight rewrite is needed.

No second candidate is recommended for a smoke.

## Exact pins

Local state:

- OpenRamble HEAD:
  f2b6e8cc66d20f7a07094f79af0faf3ba861af64
- FluidAudio checkout:
  ee9a7f12d91710da53de6d75f8b7160e09eccee4
- Both repositories were clean at the end of the audit.

Source-only checkouts:

- PCL-Voice/PengChengStarling:
  fddb2ca9aef2da252ebc88957f25a62eb8a32a49
- k2-fsa/sherpa-onnx:
  3e409338959097c6518998c9b72757db257f5f6f
- PCL-Voice/sherpa-onnx author fork:
  1f007f546562d0e8dbecdf0d6c29bf2c6733fe3e
- QwenLM/Qwen3-ASR:
  7c6daf77a2421100f5fb066495372c00129d39ff
- alphacep/vosk-api:
  05adbfcc0df27a1535913c6accd4b7fc60ffd59d

Model and package revisions:

- Original model:
  https://huggingface.co/stdo/PengChengStarling
- Original exact revision:
  3afca1d0cdbda6b0cde440e31539be81df5d1301
- Optimized sherpa-onnx package:
  https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10
- Optimized exact revision:
  c6726c1147387ad2a11148b33973135d92a55e6c
- sherpa-onnx provenance workflow was introduced at
  d5da9430e89a6ac05ead12ef01e7d501e5192904 and fixed to include tokens.txt at
  8b8ef1090b70785d47750190f493964b7b0ef471.

## Why this is genuinely trained streaming

### Explicit language coverage

OBSERVED:

- The pinned original model card declares Apache-2.0 and languages
  zh, en, vi, ru, ja, th, id, ar.
- The project README calls the released checkpoint a multilingual streaming ASR
  model supporting Chinese, English, Russian, Vietnamese, Japanese, Thai,
  Indonesian, and Arabic, with approximately 2,000 training hours per language.
- The pinned training config includes GigaSpeech English and Datatang Russian
  train/test manifests.
- The decoder is explicitly conditioned by replacing its start token with
  one of the language tags. The project documents EN and RU tags.

Primary evidence:

- https://huggingface.co/stdo/PengChengStarling/tree/3afca1d0cdbda6b0cde440e31539be81df5d1301
- https://github.com/PCL-Voice/PengChengStarling/blob/fddb2ca9aef2da252ebc88957f25a62eb8a32a49/README.md
- PengChengStarling/config_train/example.yaml:8-29,52-53,95-96
- PengChengStarling/config_bpe/example.yaml:16-25
- PengChengStarling/zipformer/streaming_decode.py:74-83,486-496
- PengChengStarling/zipformer/decode_stream.py:28-87

Important limit:

- This is explicit forced-language support, not proven automatic language
  detection or code-switching. A product path must pass the requested language
  explicitly and report that configured language separately from recognized
  text.

### Causal, limited-context training

OBSERVED in the pinned training config:

- causal: 1
- training chunk_size choices: 16,32,64,-1
- training left_context_frames choices: 64,128,256,-1
- released/decode configuration: chunk size 16, left context 128
- stage layout: 2,2,4,5,4,2 encoder layers

The selected exported encoder metadata is constructed with:

- decode_chunk_len = chunk_size * 2 = 32 feature frames
- T = 45 feature frames, including the subsampling/ConvNeXt padding
- a bounded left context, downsampled per Zipformer stage

The inclusion of -1 among randomized training contexts does not make the
released graph full-context: the selected ONNX export fixes chunk 16 and left
context 128 and exports explicit bounded caches.

### Reusable acoustic encoder state

OBSERVED in export-onnx-streaming.py and zipformer.py:

- Each encoder layer accepts and returns six state tensors:
  cached_key, cached_nonlin_attn, cached_val1, cached_val2, cached_conv1,
  cached_conv2.
- The subsampling front end additionally accepts/returns embed_states.
- processed_lens is advanced and returned.
- On every step OnnxEncoder calls encoder_embed.streaming_forward and
  encoder.streaming_forward, then returns the new states.
- Attention explicitly concatenates cached keys with the current chunk and
  retains only the bounded left context.

This is recurrent acoustic state reuse. It is not full-audio replay or an
overlapping fixed-window wrapper.

Primary source pointers:

- PengChengStarling/zipformer/export-onnx-streaming.py:143-242,295-443
- PengChengStarling/zipformer/zipformer.py:422-535,877-992,1087-1151
- PengChengStarling/zipformer/subsampling.py:338-406
- PengChengStarling/zipformer/onnx_pretrained-streaming.py:132-330

CALCULATED batch-1 persistent encoder state:

- Stage bytes:
  422,912; 354,304; 581,632; 675,840; 581,632; 354,304
- Layer-state floats:
  742,656
- Subsampling embed-state floats:
  7,296
- Total:
  749,952 float32 values = 2,999,808 bytes = 2.861 MiB
- processed_lens adds 8 bytes.

This count excludes transient ORT tensors and decoder search state.

## Exact payload and provenance

The future smoke should use only these files from optimized revision
c6726c1147387ad2a11148b33973135d92a55e6c:

| File | Bytes | Primary metadata digest |
|---|---:|---|
| encoder-epoch-75-avg-11-chunk-16-left-128.int8.onnx | 296,583,597 | SHA-256 f9001ed7a9e46d0294438c1a30cd7c72d1cc4bdd4e7880edbcda36f67081e32e |
| decoder-epoch-75-avg-11-chunk-16-left-128.onnx | 33,837,085 | SHA-256 7ebc63f34b21c8efb4a41a5a2eee7fe1448829ce0230ecc5369e67fc14d90d48 |
| joiner-epoch-75-avg-11-chunk-16-left-128.int8.onnx | 8,257,421 | SHA-256 db88e3172323551abaa99b91b18fb422a27ea4a834fd0db10389f9478816f917 |
| bpe.model | 476,049 | SHA-256 027731f33cff7266f2878c6fb7e478cf4af983962e311bb565112792794c13cd |
| tokens.txt | 195,244 | Git blob SHA-1 454ab79768a10f166536da754c39259c817df839 |

Product payload total:

- 339,349,396 bytes
- 339.349 MB decimal
- 323.629 MiB
- 0.316 GiB

The tokens file is not stored with LFS, so the primary API exposes its Git blob
ID rather than a SHA-256. On the first authorized download, verify that exact
Git blob ID and seal a SHA-256 before any load.

For comparison, the corresponding original non-quantized ONNX product files
total 1,220,027,670 bytes (1,163.509 MiB):

- encoder: 1,152,686,825 bytes,
  SHA-256 8c326918bd35a3b70556e8b6666471c94ee39256c08b536c5d85f7c6af13953e
- decoder: 33,837,085 bytes, same digest as above
- joiner: 32,832,467 bytes,
  SHA-256 5c64aaa48e4d296f0b60415fcb97dd9578ac3d13133e4eebbed11786f9417cb6
- bpe.model and tokens.txt as above

OBSERVED provenance chain:

1. The original model card at revision 3afca1... declares Apache-2.0.
2. sherpa-onnx workflow 8b8ef109... downloads the named original files from
   stdo/PengChengStarling, runs quantize_models.py, removes the full-size
   encoder and joiner, and publishes the optimized package.
3. The optimized decoder and bpe hashes exactly match the original package.
4. The optimized repository card links back to PengChengStarling.

License caveat:

- The optimized derivative card has no YAML license field and contains only a
  source link. Packaging must therefore retain the pinned original Apache-2.0
  model card/license attribution and sherpa-onnx Apache-2.0 LICENSE/NOTICE.
- Fail closed if the release artifact omits that provenance/notice chain.
- This is an engineering license audit, not legal advice.

## macOS arm64 offline runtime

The source-proven runtime path is **sherpa-onnx + ONNX Runtime CPU**.

OBSERVED:

- sherpa-onnx is Apache-2.0.
- Its C API states that the online recognizer runs locally without Internet.
- The C API provides recognizer/stream creation, waveform append, readiness,
  decode, immutable result snapshots, token timestamps, input-finished, reset,
  and deterministic destruction.
- sherpa-onnx documents macOS arm64 support.
- CMake sets macOS deployment target 10.14.
- At pinned sherpa-onnx commit 3e409338..., the arm64 shared-runtime recipe
  pins ONNX Runtime 1.27.1:
  https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.27.1/onnxruntime-osx-arm64-1.27.1.zip
- Exact ORT archive SHA-256:
  8258cf05abc011df06706646f73bdddb735d90348ae3d211bd5c471c20a617b0

Core ML / Metal status:

- CPU is the only source-proven acceptance path for this candidate.
- sherpa-onnx includes an ONNX Runtime CoreML execution-provider branch on
  Apple when ORT API version is at least 15.
- The static macOS ORT recipe explicitly disables CoreML; the shared recipe is
  needed to inspect that provider.
- Model-specific CoreML partition coverage, cache I/O behavior, compile cost,
  and parity are UNVERIFIED.
- No direct Metal execution path was found in the pinned source.
- A future CPU smoke must not be represented as CoreML/ANE feasibility.

Footprint:

- CALCULATED model payload is 323.629 MiB.
- CALCULATED persistent encoder state is 2.861 MiB.
- Actual ORT load RSS, transient activations, native dylib size, and cold load
  time are UNVERIFIED.
- The payload and bounded state make a sub-16-GB process realistic, but the
  future smoke must measure RSS. Recommended product hard gate: peak RSS under
  4 GiB, in addition to the absolute 16-GB requirement.

Product integration cost:

- FluidAudio has no package dependencies and does not currently embed ONNX
  Runtime. This candidate introduces a second native runtime and a new
  approximately 324-MiB model payload.
- That cost is acceptable only for a gated research lane; it is not a default
  recommendation.

## Language-start blocker

The released model is not a generic blank-start transducer.

OBSERVED in the model-author source:

- The README says the target language replaces the decoder start token.
- streaming_decode.py obtains the language token from SentencePiece for each
  utterance.
- DecodeStream initializes greedy decoding with
  context_size - 1 sentinel values followed by that language token.
- The author's sherpa-onnx fork maps EN to 3 and RU to 5 and modifies the
  greedy decoder to read OnlineStream.lang_id.

OBSERVED in current upstream sherpa-onnx:

- OnlineTransducerGreedySearchDecoder::GetEmptyResult hard-codes blank ID 0.
- The online C API has no transducer language/initial-token field.

The author's fork is not safe to adopt as-is:

- Its websocket server calls create_stream first.
- create_stream immediately calls InitOnlineStream and seeds the decoder result.
- Only after that does the websocket server assign stream.lang_id.
- No reset/reinitialization follows, so the already-created result retains the
  old initial token.

The future harness must use current upstream sherpa-onnx plus a small explicit
API seam, not the old websocket server.

Minimum acceptable temporary patch:

1. Add a typed C/C++ stream factory that accepts initial_token_id.
2. Create the normal transducer stream and seed the initial decoder result
   before any AcceptWaveform/Decode call.
3. Refuse use for a non-transducer recognizer.
4. Parse the pinned tokens.txt and require exact unique EN and RU tag mappings.
   The author fork's numeric values are evidence, not a value to trust blindly.
5. Keep the selected language outside recognized text and include it in the
   result hash.
6. Add unit tests that first decode observes the expected initial token and
   blank-start behavior is unchanged for ordinary Zipformer models.

## Finalization and determinism protocol

The runtime exposes the necessary lifecycle, but output determinism remains a
smoke gate.

Fixed Stage-1 protocol:

1. Keep one recognizer loaded in a persistent worker.
2. Create a fresh stream with the verified EN or RU initial token.
3. Disable endpoint-reset behavior and hotwords for the initial gate.
4. Feed canonical 16-kHz mono float PCM in bounded 20-ms frames.
5. Whenever IsOnlineStreamReady is true, drain DecodeOnlineStream.
6. On Stop, append exactly 4,800 zeros (0.3 s), call InputFinished exactly
   once, and drain while ready.
7. Take exactly one final result snapshot.
8. Hash configured language, normalized and raw text, token strings/IDs, and
   timestamps.
9. Destroy stream; reuse recognizer; finally destroy recognizer and worker.

Why this protocol is deterministic by construction:

- Greedy search is fixed.
- sherpa feature dither defaults to 0.
- Input framing, tail padding, and drain order are fixed.
- InputFinished is explicit.

What remains UNVERIFIED:

- Bit/output stability across runs and process launches.
- Whether 0.3-s tail padding is sufficient for every chunk phase.
- Tail-word preservation.
- Timestamp stability and correct word derivation.

The native result exposes token timestamps. The transducer result conversion
uses 10-ms feature shift and subsampling factor 4, so expected token timing
granularity is 40 ms. Word timings would be derived from SentencePiece word
boundaries; they are not a separate native word-alignment output and must be
validated.

## Ranked shortlist

| Rank | Candidate | Genuine acoustic state | EN+RU | License/runtime | Decision |
|---:|---|---|---|---|---|
| 1 | PengChengStarling streaming Zipformer | Yes: explicit per-layer attention/convolution caches plus front-end cache | One trained 8-language model; forced language tag | Apache-2.0; sherpa-onnx CPU on macOS arm64 | **Select one conditional smoke** |
| 2 | Vosk small EN + small RU | Yes: Kaldi online recognizer state and explicit final flush | Two separate monolingual models | Apache-2.0; native CPU | Reject for this lane: no single bilingual state, no mixed/auto-language semantics, materially weak published small-RU accuracy, no CoreML/Metal path |
| 3 | Qwen3-ASR-0.6B | No reusable acoustic state in official streaming API | Explicit multilingual EN/RU | Apache-2.0; 1,876,091,704-byte BF16 model | Hard reject: re-feeds all accumulated audio every chunk, vLLM-only streaming, no streaming timestamps |
| 4 | T-one | Yes: explicit hidden state per 300-ms chunk | Russian only | Apache-2.0; CPU/ONNX path | Hard reject: fails English requirement |

Vosk primary model-page evidence:

- Small EN model: 40 MB, Apache-2.0, published WER 9.85 on LibriSpeech
  test-clean and 10.38 on TED-LIUM.
- Small RU model: 45 MB, Apache-2.0, published WER 22.71 on OpenSTT
  audiobooks, 31.97 on OpenSTT YouTube, 29.89 on SOVA devices, and 11.79
  on Golos crowd.
- The C API has accept-waveform, partial/result/final-result, word times,
  reset, and free.
- Primary sources:
  https://alphacephei.com/vosk/models
  https://github.com/alphacep/vosk-api/blob/05adbfcc0df27a1535913c6accd4b7fc60ffd59d/src/vosk_api.h

Qwen3-ASR primary rejection evidence:

- Model revision:
  5eb144179a02acc5e5ba31e748d22b0cf3e303b0
- model.safetensors:
  1,876,091,704 bytes,
  SHA-256 79d6cbd4c98c7bbffe9db2edac07f56cd6637d0d5944b27f6c2b8353840323ea
- qwen_asr.py explicitly says every ready chunk is appended to audio_accum and
  all audio seen so far is re-fed to the model.
- The implementation permits streaming only on vLLM and says streaming has no
  timestamps.
- Source:
  https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/inference/qwen3_asr.py

## FluidAudio/pinned-dependency audit

No overlooked new FluidAudio model satisfies all requirements.

OBSERVED at FluidAudio ee9a7f12...:

- StreamingModelVariant lists Parakeet EOU, English Nemotron, and Parakeet
  Unified tiers.
- Parakeet EOU is a genuine cache-aware loopback encoder, but NVIDIA's primary
  model card says it supports only English.
- English Nemotron is English-only.
- StreamingNemotronMultilingualAsrManager is genuinely stateful: it maintains
  channel/time/length encoder caches and optional Core ML MLState. It is the
  already evaluated/excluded Nemotron 3.5 multilingual family, not a new
  candidate.
- Parakeet Unified is explicitly a stateless encoder re-run over a
  left/chunk/right window.
- Parakeet TDT uses an offline encoder in overlapping sliding windows and does
  not conform to StreamingAsrManager.
- Cohere Transcribe uses a fixed 35-s encoder and resets decoder cache per
  long-form chunk; the local language enum also lacks Russian.
- SenseVoice Small is excluded by task and is a non-autoregressive fixed-window
  encoder.
- Paraformer in this checkout is Chinese.
- FluidAudio Package.swift has no external package dependencies. No
  sherpa-onnx, ONNX Runtime, Vosk, or PengChengStarling implementation is
  already embedded.

Primary EOU card:

- revision a7e2b4629593dce0ec19f600e00e9904353fda2d
- explicitly English-only
- https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1

## Preregistered one-candidate Stage-1 smoke

Do not execute without a separate GO and model-slot coordination.

### Build-only preparation

Use:

- sherpa-onnx 3e409338959097c6518998c9b72757db257f5f6f
- a temporary, reviewed initial-token patch with an exact diff hash
- macOS arm64
- Release
- shared ONNX Runtime 1.27.1 archive with the pinned SHA above
- C API on
- Python, websocket, PortAudio, binaries, examples, and tests off where the
  build permits
- provider forced to CPU for the first gate
- one ORT intra-op thread and one inter-op thread initially

Representative source-only build command after the patch is frozen:

    cmake -S sherpa-onnx -B build-arm64 \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DBUILD_SHARED_LIBS=ON \
      -DSHERPA_ONNX_ENABLE_C_API=ON \
      -DSHERPA_ONNX_ENABLE_BINARY=OFF \
      -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
      -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
      -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF
    cmake --build build-arm64 --config Release --parallel

### First authorized model download

Download only the five named product files from exact revision c6726c... into
an isolated temporary staging directory, verify all available hashes before an
atomic rename, and store the pinned original model card for attribution.

Representative command, not run in this audit:

    hf download \
      csukuangfj/sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10 \
      --revision c6726c1147387ad2a11148b33973135d92a55e6c \
      --include encoder-epoch-75-avg-11-chunk-16-left-128.int8.onnx \
      --include decoder-epoch-75-avg-11-chunk-16-left-128.onnx \
      --include joiner-epoch-75-avg-11-chunk-16-left-128.int8.onnx \
      --include bpe.model \
      --include tokens.txt \
      --local-dir STAGING_DIR

Expected transfer/product bytes: 339,349,396, excluding HTTP/cache overhead and
the small license/model-card files.

### Tiny real gate

Fixtures:

- Four frozen real fixtures only: two EN and two RU.
- Per language: one 1-4-s fixture and one longer than a 320-ms encoder stride
  with a non-aligned tail.
- Canonical PCM and frozen references.

Runs:

- One cold process/load observation.
- Two symmetric warmups.
- Five measured repeats per fixture in one persistent process.
- Twenty deterministic Stop offsets spanning one full 320-ms chunk stride,
  including exact and boundary-near offsets, if base smoke passes.

Measure:

- download bytes/time, binary and dylib bytes
- cold recognizer load and first-decode latency
- steady under-speech duty and RTF
- Stop to final p50/p95/max, with worst offset reported
- encoder-step count and state-progress fingerprints
- peak and steady RSS, file descriptors, process reap
- raw and normalized transcript, configured language, token strings/IDs,
  token timestamps, derived word timings, and stable SHA-256
- WER against each frozen EN/RU reference

Hard stops:

- any file/revision/license/hash mismatch
- initial-token mapping is absent, ambiguous, or not EN/RU exact
- wrong-script or wrong-language output
- empty/catastrophic output
- any evidence of full-audio replay instead of bounded state advancement
- duplicate or missing final result
- nondeterministic language/text/token/timing hash for identical PCM/config
- any Stop-offset change in final language/text/token/timing hash
- tail-word loss, duplicate tail, invalid/non-monotonic timestamps
- RTF at or above 1.0 on any base fixture
- peak RSS above 4 GiB
- crash, leak, unreaped worker, or unbounded file-descriptor growth
- EN/RU quality materially worse than the frozen shipping reference

Only if every tiny gate passes should a preregistered broad quality/latency lane
be considered. No CoreML provider experiment is implied by a CPU pass.

## Claims deliberately not made

- No weight, ONNX, GGUF, or Core ML artifact was downloaded in this audit.
- No model was loaded or run.
- No M4 latency, RTF, RSS, quality, transcript parity, or timestamp parity was
  measured.
- No CoreML/ANE or Metal compatibility is claimed.
- No automatic language detection or mixed-language quality is claimed.
- No EN/RU quality advantage is claimed; primary published EN/RU scores are
  absent.
- No product integration or default is recommended.
