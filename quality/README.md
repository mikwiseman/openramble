# Optional release evidence

Automated release checks validate the signed artifact directly. Live voice
benchmarks and a manually completed installer matrix are not release gates.

For a large installer or updater change, copy
`release-evidence-template.json` to the ignored local file
`release-evidence.json`, record real observations for the exact notarized DMG,
and validate it with:

```bash
./scripts/validate-release-evidence.py \
  quality/release-evidence.json <git-sha> <dmg-path>
```

Never fabricate observations or automatically replace missing evidence with
`pass`. `reproducibility.json` documents the frozen synthetic benchmark setup
used for model comparisons; it does not block application releases.
