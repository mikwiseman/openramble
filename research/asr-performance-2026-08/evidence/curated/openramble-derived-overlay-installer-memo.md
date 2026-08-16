# TEMP-only derived short-shape overlay installer

Date: 2026-08-14 (Europe/Moscow)

## Verdict

The local installer mechanism is feasible. A CPU-only Swift prototype now proves signed/hash-pinned intake, exact source dependency checks, adjacent staging, hardlink-first materialization, APFS clone and ordinary-copy fallbacks, per-file SHA/device/inode inventory, atomic promotion, process-crash reconciliation, feature rollback, and derived-before-source pruning.

It is **not ready to integrate**. The remaining hard blocker is offline overlay generation: the old 7.5 s hybrid packer uses positional `zip(shipping.operations, short.operations)` and copies whole operations. That is forbidden for 10/12.5 s, where shipping has 3,398 operations and the new static graphs have 3,396. The signed schema now requires semantic tensor/blob attestation and rejects `indexZip`, but no trusted generator has yet produced the complete 614-reference attestation. The runtime installer never rewrites a Core ML graph.

No Core ML model was loaded, compiled, exported, or predicted in this subtask. No shared repository tracked file was changed.

## Exact prototype

- Detached worktree: `$TMP/openramble-derived-overlay-installer-f2b6e8cc`
- Base HEAD: `f2b6e8cc66d20f7a07094f79af0faf3ba861af64`
- Source: `Packages/LocalASR/Sources/LocalASR/DerivedModelOverlayInstaller.swift`
  - 1,364 lines
  - SHA-256 `79529ec13c44ee9ab3de08cb3b22bb269dc7afe02b0e418f2645802ded463f7f`
- Tests: `Packages/LocalASR/Tests/LocalASRTests/DerivedModelOverlayInstallerTests.swift`
  - 869 lines
  - SHA-256 `7ff2b9b02a0f5afe69399a032b69fc22c8615a653aac1a34cd24df0f655134c2`
- Both files are untracked and exist only in the temp worktree.

## Exact pins and artifact identity

- Shipping model revision: `aed02740059203c4a87495924f685de3722ae9ce`
- Shipping manifest bytes SHA-256: `05046d2b0b12fcfcf82625256bbf606eed198a064a73f979b5b2b3a617f0f78b`
- FluidAudio runtime revision: `ee9a7f12d91710da53de6d75f8b7160e09eccee4`
- Shipping encoder weight:
  - 445,187,200 bytes
  - SHA-256 `e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421`
- Existing temp hardlink proof:
  - source and derived `shipping.bin`: device `16777230`, inode `3414179`, link count `2`
- Shipping compiled-tree canonical manifest SHA-256: `8c64ab8f13f62a7ecbd068c21e7dd53c1453b52ebed0b8631a0a7a8e47eef481`
- Hybrid compiled-tree canonical manifest SHA-256: `8796692e468ac4e1cc1e873e96dd2a4000615178c1b55043af7a3da36d2b4179`
- Canonical tree hash input is sorted lines of `file_sha256 byte_count ./relative/path`, including every regular file.

The ten downloaded/unique files are exactly:

| Relative path | Bytes | SHA-256 |
|---|---:|---|
| `Encoder.mlmodelc/analytics/coremldata.bin` | 243 | `6e35b42a4540f13797b0aef7afccb7a508b3a7378544bfe6745402f29b1ee76d` |
| `Encoder.mlmodelc/coremldata.bin` | 534 | `900958fe087945a2b24ae74e1941ccba66a91b274ace8f6a6025ae33f056c7fe` |
| `Encoder.mlmodelc/metadata.json` | 2,963 | `b46167e0566da335ca17d24c661bf055235abe9088d865adc71b09ff7d3c73d6` |
| `Encoder.mlmodelc/model.mil` | 800,252 | `1fa9f9b028c88210c1e06964ef953564615aa0078f882873139f22bc6e006e56` |
| `Encoder.mlmodelc/weights/short-shape.bin` | 3,452,992 | `1ee90b3f3c2273d4b0de6fb61c73553c83daca6b4f2ee9651ae512e328dbc7e8` |
| `Preprocessor.mlmodelc/analytics/coremldata.bin` | 243 | `bd95004ddecd7631c6d3a70ca7ef43b0808e43aa10e727443ec4cd674ce1397c` |
| `Preprocessor.mlmodelc/coremldata.bin` | 541 | `678400fdcb6069164f35a1de38917dd273ca0e1c050a12e7ec8b90173c54b0f4` |
| `Preprocessor.mlmodelc/metadata.json` | 2,885 | `63156ac4097aade8d2141f5146dacd593c3a17574c3352f94cd63b41fbb7a7b2` |
| `Preprocessor.mlmodelc/model.mil` | 23,903 | `6795fc780671ad6ecb88a8c670ce97ba3465489e5a9a7823fc1de45b01ebd316` |
| `Preprocessor.mlmodelc/weights/weight.bin` | 395,072 | `eb2412006697c8d82acf748f428dfdab37bdbe91141417a7fd6e6d6262194094` |

Their sorted canonical manifest SHA-256 is `fdad450b642cc17661842b570143af444936f7f3d2f191aeb52b5f7264da410f`.

## Signed manifest and graph contract

`DerivedModelOverlayEnvelope.verify` requires both:

1. the exact envelope byte SHA-256 pinned by an app-signed catalog; and
2. a valid Ed25519 signature from a compiled trusted-key ring.

The canonical signed bytes are the manifest encoded as sorted-key JSON. The manifest pins:

- overlay ID and 64-hex content/build revision;
- exact FluidAudio commit;
- exact source model ID, 40-hex revision, engine folder, and source manifest SHA-256;
- every downloaded file path, byte count, and SHA-256;
- every shared source path, derived destination path, byte count, and SHA-256;
- one or more graph attestations.

Each graph attestation records:

- mapping mode, where only `semanticNameAndBlobReferenceV1` is accepted and `indexZip` is fail-closed;
- exact shipping, independently exported static, and final packed graph path/bytes/SHA;
- operation count and blob-reference count for all three graphs;
- for every tensor: exporter/state-dict semantic name, role (`sharedFromSource` or `overlayPayload`), dtype, shape, decoded byte count, and canonical decoded-content SHA-256;
- standalone, packed, and (for shared tensors) shipping blob references: function, specialization block, operation type, generated operation name, output name, attribute name, blob file, and offset.

Validation requires one-to-one semantic names and blob references, exact coverage of every standalone and packed blob reference, a shipping reference for every shared tensor, no shipping reference for overlay-only tensors, a packed graph pinned by payload files, and blob filenames connected to the exact `sharedFiles`/`payloadFiles` entries. The installer also confirms the shipping graph path/bytes/SHA against the exact source manifest and bytes on disk.

Operation counts may differ; count equality is not a mapping rule. This lets the schema represent shipping 3,398 vs static/packed 3,396 safely, provided all blob references map semantically.

Important boundary: the runtime installer structurally validates the signed attestation and exact final/source file hashes; it does not contain `coremltools` and cannot independently reparse and recompute 614 tensor mappings. The offline packer and CI verifier remain a required trust boundary. The scale smoke below used a synthetic one-blob attestation only to exercise installer mechanics; it is not evidence that the old hybrid graph was semantically packed.

## Proposed product API

Current temp prototype API:

```swift
let verified = try DerivedModelOverlayEnvelope.verify(
    envelopeData,
    expectedEnvelopeSHA256: catalog.overlayEnvelopeSHA256,
    trustedKeys: overlaySigningKeys
)

let installer = DerivedModelOverlayInstaller(
    manifest: verified,
    root: modelsRoot
)

try installer.reconcile(sourceManifestData: shippingManifestData)
let report = try installer.install(
    payloadDirectory: verifiedDownloadDirectory,
    sourceManifestData: shippingManifestData,
    featureEnabled: featureFlags.shortShapeOverlay,
    replaceExisting: false
)
try installer.validateInstalled(sourceManifestData: shippingManifestData)
try installer.rollbackForDisabledFeature(sourceManifestData: shippingManifestData)

let pruner = DerivedModelDependencyPruner(root: modelsRoot)
try pruner.pruneSource(
    modelID: sourceID,
    revision: sourceRevision,
    mode: .refuseWhenDerivedExists // or .cascadeDerivedFirst
)
```

Product integration should expose one actor-owned artifact store rather than two independently callable stores:

```swift
actor ModelArtifactStore {
    func installOverlay(_ signedEnvelope: Data, payload: AsyncSequence<ByteBuffer>) async throws
    func reconcile() async throws
    func setOverlayEnabled(_ enabled: Bool) async throws
    func repairSource(...) async throws // invalidates/prunes dependents first
    func pruneSource(..., policy: SourcePrunePolicy) async throws
}
```

The actor must hold a source-install lease across source SHA verification, linking, final verification, and promotion. `ModelStore.repair/delete` must call the dependency planner first. Otherwise a concurrent source replacement can leave a still-readable hardlink to the old inode; the prototype detects the inode mismatch later, but serialization should prevent it.

Payload downloads should stream directly into the adjacent staging tree. The temp prototype accepts a predownloaded payload directory to keep network behavior out of scope.

## Materialization and promotion

For every shared regular file:

1. verify source size/SHA and source ready marker/revision;
2. compare source and staging-parent device IDs;
3. on the same volume call POSIX `link`;
4. if linking fails call APFS `clonefile`;
5. if cloning fails make an ordinary copy;
6. verify destination size/SHA and record device, inode, link count, strategy, and source identity.

Payload files are copied into adjacent staging and verified before and after copy. Symlinks, special files, path traversal, unexpected root entries, unexpected regular files, same-byte inode substitution, and missing files are rejected.

The ready marker is written and the complete staging tree revalidated before visibility. Promotion is same-parent rename:

1. existing destination to `.overlay-backup-<revision>`;
2. complete staging to final revision path;
3. revalidate final tree;
4. remove backup as housekeeping.

## Crash/fault matrix

| Injected point/fault | On-disk state at interruption | Fresh-process reconciliation |
|---|---|---|
| after staging create | old destination + empty staging | keep valid old destination; sweep staging |
| after payload copy | old destination + partial staging | keep old; sweep staging |
| after shared materialization | old destination + unmarked complete bytes | keep old; sweep staging |
| after ready marker/write+verify | old destination + valid staging | keep old; staging is never silently promoted |
| after destination→backup | backup + valid staging, no destination | restore valid backup; sweep staging |
| after staging→destination | valid new destination + backup | keep new; remove backup |
| after final verification | valid new destination + backup | keep new; remove backup |
| before backup removal | valid new destination + backup | keep new; remove backup |
| bad envelope hash/signature | no staging | fail before disk mutation |
| source manifest/revision/weight/graph mismatch | no staging | fail closed |
| corrupt payload | staging may exist | ordinary error cleanup removes staging; no published tree |
| hardlink unavailable/cross-volume | no semantic change | try clone, then copy |
| clone unavailable | no semantic change | ordinary copy |
| crash during prune after rename | hidden `.overlay-pruning-*` tombstone | `reconcileTombstones` finishes deletion |
| source prune with dependents, refuse policy | no mutation | return exact dependent overlay IDs |
| source prune with cascade policy | derived revisions renamed/removed first | source revision removed only after all dependents |
| feature flag disabled before install | no mutation | `.featureDisabled` |
| feature flag rolled back after install | derived revision removed | source inode/content remains |

All eight promotion checkpoints were injected in tests. Every relaunch ended with a fully verified old or new tree and no backup/staging residue.

Process-crash permutations are covered. Power-loss durability is not yet complete: the prototype closes files and uses atomic writes/renames but does not explicitly `fsync`/`F_FULLFSYNC` every file and parent directory. Product implementation must add those barriers and a power-cut/filesystem fault harness before claiming durable recovery.

## Disk and download accounting

| Item | Logical bytes | Allocated/physical evidence |
|---|---:|---:|
| Shipping compiled tree | 483,105,645 | 483,151,872 allocated |
| Existing hybrid compiled tree entry | 486,299,032 | 486,350,848 entry-allocated |
| Existing hybrid incremental unique (only encoder weight hardlinked) | 41,111,832 | 41,160,704 allocated |
| Proposed fully linked shared set, 12 files | 481,619,404 | zero duplicated file data with hardlinks; directory metadata remains |
| Proposed downloaded/unique payload, 10 files | 4,679,628 | 4,706,304 allocated in current artifact |
| Shipping + fully linked overlay unique total | 487,785,273 | 487,858,176 before marker/directory metadata |
| Full-copy fallback for new derived tree | 486,299,032 | approximately full tree plus marker |

The ten-file payload is 0.9623% of the derived tree. A gzip-9 tar stream measured 1,162,114 bytes (24.83% of raw, 75.17% smaller); this is an estimate, not a promised CDN/archive size. The final signed 614-tensor attestation will add bytes and has not been generated yet.

With direct-to-staging download, hardlink-first installation needs about 4.68 MB new file data plus metadata. Replacing an existing overlay temporarily retains the old overlay's unique payload until backup cleanup. The current prototype's predownloaded payload API temporarily holds two payload copies, 9,359,256 raw bytes, plus any old overlay. To guarantee copy fallback, preflight must reserve the full new logical tree plus safety headroom; APFS clone allocation must never be promised as zero because CoW blocks may become private.

Hardlinks cannot be encoded reliably in a downloaded archive; they must be created locally. They persist across app updates and directory renames on the same volume because Application Support is outside the app bundle. Removing the source path first would not free the inode while the derived link exists, but would violate the dependency and identity contract. Therefore source repair/prune/delete must remove or rebuild derived overlays first.

## Tests and evidence

- Focused installer suite: 15 cases, 1 opt-in real-artifact case skipped, 0 failures.
- Related installer/manifest/layout/verifier/source suites: 74 total cases, 1 opt-in skip, 0 failures, 13.676 s.
- Actual APFS `clonefile` fallback: 1/1, distinct inode, exact bytes.
- Actual hardlink path: same device/inode and link count increment/decrement verified.
- Real frozen compiled-tree CPU smoke, with explicit environment paths: 1/1 in 1.579 s.
  - source manifest exact SHA above;
  - 4,679,628 downloaded bytes;
  - 481,619,404 shared logical bytes;
  - 486,299,032 installed logical bytes;
  - all 12 shared files materialized as hardlinks;
  - final exact inventory/hash/inode validation passed.
- The real smoke created a temp source/layout using hardlinks and removed it in teardown. It did not mutate source bytes and did not load Core ML.

## Offline packer acceptance gate

The product packer must be a separate pinned tool and must:

1. parse exact shipping, standalone-static, and packed MIL protobufs without model execution;
2. consume stable exporter/state-dict semantic tensor IDs; generated names are evidence, not primary identity;
3. never zip operations by index and never `CopyFrom` a whole shipping operation into a shifted graph;
4. prove one-to-one standalone→packed mapping for all blob references (currently 614), with no duplicate or uncovered refs;
5. read every tensor via its blob reference and compare dtype, exact shape, decoded byte count, and canonical decoded SHA;
6. reuse shipping bytes only for exact tensor matches; write shape-dependent tensors into the overlay blob;
7. reparse output and prove every shipping reference belongs to an attested shared tensor and every overlay reference belongs to an attested payload tensor;
8. pin every input/output graph and final compiled file by bytes/SHA, then sign the envelope;
9. fail closed on missing semantic names, ambiguous mappings, unknown dtypes, count/coverage mismatch, or hash mismatch.

The 10/12.5 finding (3,398 vs 3,396 operations, while the blob-op sequence remains 614 and 24 tensors are shape-dependent) suggests semantic reuse may still be possible. It is not proof. Until this packer/attestation gate exists and passes, the safe output remains the standalone as-produced model, not an overlay.
