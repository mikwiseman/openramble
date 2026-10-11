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
