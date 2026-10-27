# Upstream issue: Parakeet Ultra long-form drops quiet speech next to loud speech

Filed on 27 October 2026 as
[handy-computer/transcribe.cpp#235](https://github.com/handy-computer/transcribe.cpp/issues/235).
It uses only public FLEURS audio.

---

**Title:** parakeet-ultra long-form: quiet speech next to louder speech is dropped as silence

**Version:** v0.4.1 (`4d7c1cce`); the same on main at `db678a03`. macOS arm64,
`--backend metal` and `--backend cpu` alike.

**Model:** `handy-computer/parakeet-ultra-gguf` at `a1539be1`,
`parakeet-ultra-Q4_K_M.gguf`.

**Audio:** four FLEURS `en_us` test utterances, 14944400645209157789,
10492135991603561867, 12953138808800823203 and 12517884865939916901, 16 kHz
mono 16-bit, each followed by 0.5 s of digital silence. The clip is the
33.13 s starting 2.51 s in (PCM SHA-256 `b39a522c1fdc336c…`). The first three
utterances are about 40 dB quieter than the fourth: RMS −65, −61 and
−61 dBFS against −22 dBFS.

```python
pcm = b''
for uid in ['14944400645209157789', '10492135991603561867',
            '12953138808800823203', '12517884865939916901']:
    with wave.open(f'{uid}.wav') as w:
        pcm += w.readframes(w.getnframes()) + b'\0' * 16000
clip = pcm[2 * round(2.51 * 16000): 2 * (round(2.51 * 16000) + round(33.13 * 16000))]
```

**Steps:** `transcribe-cli -m parakeet-ultra-Q4_K_M.gguf clip.wav`

**Expected:** all four sentences, 73 words ("CE, the Great Pyramid is one of
the many large pyramid structures built to honor dead Pharaoh. In some
areas, boiling water…").

**Actual:** 40 words, starting "With Kodali yoga…". The first two sentences
are missing, and the run returns `TRANSCRIBE_OK`. With `TRANSCRIBE_DUMP_DIR`
set, there is one segment, `[198400, 331680]`, and `vad.prob` stays under
0.6 (mean 0.06) for the first 24.8 s, then near 1.

**Cause:** `run_vad_block` scores a whole scan block at once, and the mel
features are normalized per feature over that block
(`stt.frontend.normalize = per_feature`). Next to the loud fourth utterance,
the quiet speech scores as silence. Scored without it, the first three
utterances are detected as speech. `pause_segments` then cuts at the midpoint
of the apparent 0–24.8 s pause (12.4 s) and drops the piece before the cut,
because `has_speech` is false for it.

**Fix:** before dropping a piece as silent, scan that piece on its own and
keep it if speech is heard. True silence is still skipped and cut points are
unchanged, so every case in `parakeet_longform_unit` still matches the Python
reference. With it the clip gives all 73 words on Metal and on the CPU. A
branch with the change and a unit test that fails without it is at
`mikwiseman/transcribe.cpp@openramble/v0.4.1`; we can open a PR.
