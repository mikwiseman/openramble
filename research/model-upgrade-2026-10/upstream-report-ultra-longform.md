# Draft upstream report: Parakeet Ultra long-form drops speech at the start of a run

Draft for handy-computer/transcribe.cpp. Not filed: posting on the public
repository waits for Mik's OK.

---

**Title:** parakeet-ultra: long-form segmenter drops the first 12 s of speech when a run over 30 s starts mid-sentence

**Version:** v0.4.1 (`4d7c1cce`), the release `TranscribeCpp.xcframework.zip`
(SHA-256 `fb5646e5…`), macOS arm64, Metal. The same output from upstream main
at `db678a03`.

**Model:** `handy-computer/parakeet-ultra-gguf` at `a1539be1`,
`parakeet-ultra-Q4_K_M.gguf` (SHA-256 `c69b7a5f…`). The GGUF sets
`stt.parakeet.segmenter.max_segment_seconds = 30`.

**Audio:** four public FLEURS `en_us` test utterances,
14944400645209157789, 10492135991603561867, 12953138808800823203 and
12517884865939916901, joined with 0.5 s of digital silence after each, 16 kHz
mono 16-bit. The clip is 33.13 s starting 2.51 s into the first utterance, so
it begins mid-sentence ("…century BCE, the Great Pyramid is one of the many
large pyramid structures…"). The PCM's SHA-256 starts `b39a522c1fdc336c`.

```python
pcm = b''
for uid in ['14944400645209157789', '10492135991603561867',
            '12953138808800823203', '12517884865939916901']:
    with wave.open(f'{uid}.wav') as w:          # FLEURS en_us test, 16 kHz mono
        pcm += w.readframes(w.getnframes()) + b'\0' * 16000
clip = pcm[2 * round(2.51 * 16000): 2 * round(2.51 * 16000 + 33.13 * 16000)]
```

**Steps:** one `transcribe_run_batch` (or `transcribe_run`) on the 33.13 s
clip, Metal, `n_threads = 1`, timestamps `TOKEN` or `NONE`.

**Expected:** the four sentences, as the first 30 s of the same clip gives
(67 words, starting "The Great Pyramid is one of the many large pyramid
structures built to honor dead pharaoh. In some areas boiling water…").
transcribe.cpp 0.2.0, which has no Ultra segmenter, gives 73 words.

**Actual:** 40 words, starting "With Kodali yoga…". The first two sentences,
about 12 s of clear speech, are missing, and the call returns
`TRANSCRIBE_OK`. With debug logging and `TRANSCRIBE_DUMP_DIR`:

```
parakeet long-form: 1 scan blocks, 1 segments
longform.segments = [198400, 331680]   (start 12.40 s, 20.73 s long)
decoder: … T_enc=260 …
```

The segmenter cut at the pause at 12.4 s and kept only the piece after it.
In `pause_segments`, a piece is kept only if `has_speech(regions, cut)`, so
the VAD head found no speech in 0 to 12.4 s, which is a false negative here.

**Impact for us:** an hour of joined FLEURS English lost 142 words (deleted
words 0.88% on 0.2.0 against 2.71% on 0.4.1) where our file chunker gave the
engine 33–34 s runs. Every run kept at or under 30 s decodes normally. We now
cut audio ourselves so the engine never sees more than 30 s.

**Suggestion:** when the VAD finds no speech in a piece that the
pause-to-speech logic says is followed by speech, decoding it rather than
dropping it would turn a silent deletion into at worst a few extra words.
