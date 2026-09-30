# Current-runtime ASR quality study (2026-09-30)

The target is the Apple M4 Mac mini (16 GiB), not the checkout that hosts the
chat. Base: `ed1d0fe14bda180e7f6977b664f0d9d14e0455fc`, OpenRamble 0.31.2.
Worktree: `Documents/Code/openramble-asr-quality`. Audio, weights, references,
credentials and per-example results stay outside Git. Nothing uploads recorded
speech. Only fictional synthesis inputs go to ElevenLabs.

## Frozen sequence and decision rule

1. Common Voice 19 dev: 100 RU + 100 EN, selected by SHA256 rank before inference.
2. Main: 500 each Golos Crowd, Golos Farfield, CV19 RU test and CV19 EN test.
3. Freeze the candidate configuration before opening FLEURS test results:
   all 775 RU and 647 EN examples. No tuning from these outcomes.
4. Synthetic diagnostics: 12 scenarios × two distinct texts × three actual
   library voices = 72. Split by text, keeping all voices of a text together.
   Separate continuous fictional RU, EN and mixed tracks, approximately fifteen
   minutes each; derive 4/5/8/15-minute variants at word boundaries. Repeating
   a short loop or padding silence is not a substitute for these tracks.
5. The five existing private History recordings may establish runtime behavior
   or latency. Saved app text is not gold. Accuracy requires an independently
   verified reference. Recordings and recovered audio are currently empty.

Compare the shipping Parakeet with Whisper Turbo and Breeze-ASR-25 using the
same `LocalTranscriber`, decoder, PCM and text core. One ASR process at a time,
one model load and warm-up per series, one inference per quality example.
Parakeet uses its shipping one-thread decoder; the Whisper-family research
configuration explicitly uses four. Shipping defaults and public APIs remain
unchanged. Alternate thread counts and the retired Core ML experiments are
not part of this study.

A model replacement needs at least 10% relative WER improvement on its target
set, confirmed on the unopened holdout, no RU/EN regression over 0.5 percentage
points, no short p95 increase over 300 ms and no long-file increase over 20%.
Lost negations, changed numbers and dropped fragments block shipping. A large
quality/speed trade-off outside these bounds is a user decision. Investigate
the model first, then measured text corrections, supported prompt/context
options, measured seam losses and finally profiling of the surviving choice.
Do not expand settings, model menus, services or networking.

## Measurement contract

`asr-bench quality-benchmark` calls the current `LocalTranscriber`: direct
recognition up to 30 seconds and the shipping pause-aware timed joins above it.
It never uses the removed `serve-jsonl` protocol. `canonicalize` uses the same
`AudioFileReader` as the app, writes mono Float32 16 kHz WAV and verifies a
round-trip PCM digest. Each source, reference, canonical file, model and binary
has a SHA256. Resume refuses a changed experiment identity.

The Rust example calls the same `ramble_text::TextPipeline` behind the macOS
FFI: StarterDictionary on, personal dictionary off, phonetic matching on,
Return command off, trailing space off. Raw and app text come from the **same**
inference, rather than two model calls. Record changed dictionary outputs and
false replacements separately. Conformance checks validate the Swift/Rust
boundary; no shipping text behavior is changed by this harness.

Report WER and CER for each language and dataset, S/D/I, retained failure
outcomes, terms, numbers, negations and seam losses. Strict normalization is
NFC, lowercase, ё→е, punctuation/whitespace removal; script and digits remain
distinct. Formatting differences such as spelled-out numbers must be shown
as such, not silently repaired or counted as a semantic number change.
Punctuation is outside these WER/CER measurements.

Paired confidence intervals resample source groups with a fixed seed and use
word-weighted WER. CV groups use source speaker IDs; FLEURS groups use source
sentence IDs. Other sources must declare their grouping and any missing
speaker identity rather than invent independence. Related duration variants
belong to their parent track, not independent observations.

Model load, warm-up, file wall time and GUI Stop→insertion are separate scopes.
The first quality pass's file timing includes decode and recognition, excludes
the GUI, and may overlap corpus preparation. It is screening evidence. A
candidate latency gate requires an otherwise idle lane and repeated paired
measurements. Alignment/scoring happens after the ASR process exits.
Memory is the process high-water RSS of a fresh process per model, including
load and warm-up; it is never a per-file increment or Metal allocator estimate.

## Sources and limits

| Model | Pinned revision | Quantization |
|---|---|---|
| Parakeet | `85ac09ea12fc4b1112fa76810059364bc6adc9de` | Q8_0, shipping manifest |
| Whisper Turbo | `ceea6c8a94a21ab85be244d311e874a39344dbf5` | Q8_0 |
| Breeze-ASR-25 | `6b7a53cea9265a2cf2b19e37b3ceadeb2927d3ba` | Q8_0 |

CV19 uses the explicitly labeled `fsicoli/common_voice_19_0` mirror at
`590c8abec6cf7c8d06e650f1438e60332a796e11` (CC0). FLEURS is the official
`google/fleurs` repository at `70bb2e84b976b7e960aa89f1c648e09c59f894dd`
(CC BY 4.0). Golos uses its custom source license. The official short download
link currently returns HTTP 403; alternate distributions must preserve the
documented test splits and be labeled explicitly.

The implemented WAV distribution is `bond005/sberdevices_golos_10h_crowd` at
`e634b6b810e4d30c81b4c6d8262379fe8b9f708c` and
`bond005/sberdevices_golos_100h_farfield` at
`c93949f7140beef4adc404e7b54841e957f81c54`. The pinned mirror cards identify
the full original test splits, and downloaded row counts match 9994/1916.
Their Parquet representation cannot verify the original test.tar MD5. Crowd
has 98 absent references and one duplicate audio; Farfield has one absent
reference. Eligibility requires unique audio and nonempty source gold and is
decided before inference. Select 500 eligible recordings in each domain by
the declared SHA256 rank. The mirror has no speaker IDs: group repeated source
prompts together and disclose that these intervals do not establish speaker
independence. Quick/main canonical audio overlap is zero, and all 2000 main
inputs have distinct canonical hashes.

Breeze's model card validates Mandarin/English, not Russian. Its retention of
a multilingual tokenizer does not establish RU quality. Public test corpora
can overlap model pretraining; they establish this comparison, not an unseen
training-independent generalization claim.

Eleven synthesis uses explicit `eleven_v4`, fictional text and actual library
voices. Freeze text/voice/settings before generation; save response and audio
hashes. One generation per text/voice. Total authorized cost is $20 including
failed/uncertain attempts and any repeats; estimate before paid requests.
Do not change account billing, clone voices or use private text to clear a
quota limitation. Synthesis is clearly labeled AI-generated and cannot replace
human-speech evidence.

## Initial validation

Before inference, the harness compiled against the pinned runtime. DictationCore
644 tests passed; the Rust text core and conformance passed. In a pristine
archive of the base commit, two installed-model tests reproduced: the final
English “send it” was lost and one repeated name was missing in the long-file
fixture. The latency test passed in that isolated run. These are recorded
baseline limitations, not passing checks or a reason to weaken the tests.
Benchmark-only work needs no new application release. Any product change must
pass its regression checks, then follow the repository's normal CI/ship flow.
