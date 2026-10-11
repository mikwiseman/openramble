# Regression proof

These patches restore the pre-candidate behavior while retaining the new
optional parameters so the tests compile. They are research artifacts, not
production source. evidence.json records assertion failures observed before
the implementation. A failed compilation does not count as a red test.

In a separate clean checkout of the candidate commit, with no inference
running, apply the exact zero-context patch and run:

```bash
git apply --unidiff-zero research/mini-streaming-2026-10/regression-red/tail.patch
swift test --package-path Packages/DictationCore \
  --filter StreamedDictationTests/testFileBackedReaderRequestsOnlyTheRequiredSuffix
```

Restore that exact patch with git apply -R --unidiff-zero before running other tests. The
cancellation regression requires the callback to run and belongs to the green
suite. Apply boundaries.patch separately and run:

```bash
git apply --unidiff-zero research/mini-streaming-2026-10/regression-red/boundaries.patch
swift test --package-path Packages/LocalASR \
  --filter 'FileAudioChunksTests/(testEarlierPausePolicyChangesCutsWithoutLosingAudio|testNarrowContextPreservesOwnershipAndMergesTheShortFinalTail)'
```

Restore boundaries.patch with git apply -R --unidiff-zero. The original behavior must fail
the earlier-cut and exact-context assertions. The candidate must preserve
the original default, complete audio ownership and the minimum final tail.

## Meeting leading-silence offset

`meeting-offset.patch` restores the old relative-counter bug while retaining
the new regression. Apply with `git apply --unidiff-zero`, run the command in
`meeting-offset-evidence.json`, and observe the cut ending at261600 instead
of at least272000. Reverse exactly that patch afterward. The full
model-independent check passed with the correction; no live threshold changed.


## Long-file quality candidate

`file-quality.patch` adds two default-policy tests and four splice tests.
Applied to `048cefd`, six tests execute and three fail (nine assertions): the
long import still owns 30-second intervals and an unmatched time gap drops a
recognized context word. With the selected 15-second policy and gap-preserving
splice, all six pass. The complete focused suite passes 13 tests, including an
opt-in replay of all 36 development/heldout native-word exports.
`file-quality-evidence.json` records the log and replay hashes.

The two echo patches are research falsifiers, not permanent failing tests.
`preserve-echo-falsifier.patch` makes both original capture echo tests fail.
`quiet-echo-tests.patch` adds eight cases: four continuous low-threshold cases
and two current-threshold sparse controls pass; both low-threshold sparse
cases emit a microphone echo and fail. Both temporary patches were reverted.
The live capture threshold remains 0.02. Protocols and the RMS amendment were
registered before running these tests.
