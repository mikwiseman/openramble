# Live quality gate

`reproducibility.json` freezes the pre-fix model, dependency, scorer, synthetic
fixture and known-gap baseline. Real voice files stay outside git.

1. Collect consented RU, EN and mixed RU/EN clips from at least five speakers,
   including first words, punctuation, numbers, negation, self-correction,
   names, developer vocabulary, built-in and external/Bluetooth microphones.
2. Freeze blind references before scoring and record the corpus SHA-256.
3. Score one frozen pipeline SHA with an empty user dictionary.
4. Fill `live-benchmark-template.json` and run:

   `./scripts/validate-live-benchmark.py report.json <pipeline-git-sha>`

Any failure blocks a model claim and triggers one corpus expansion followed by
the frozen Parakeet / Apple SpeechAnalyzer / WhisperKit large-v3-turbo bake-off.
Qwen3-ASR enters only with a proven fully local Mac/Swift runtime. GigaAM is a
RU-only comparison, not the mixed-language baseline. No report in this folder
means the real-speech gate has not been run.

Public beta release additionally requires a completed manual matrix for the
exact notarized DMG. Copy `release-evidence-template.json` to the ignored local
file `release-evidence.json`, fill it, then validate it with:

`./scripts/validate-release-evidence.py quality/release-evidence.json <git-sha> <dmg-path>`

`release.sh` checks both reports. After testing the signed DMG, rerun it with
`REUSE_VERIFIED_ARTIFACT=1` so the checked artifact is not rebuilt.
