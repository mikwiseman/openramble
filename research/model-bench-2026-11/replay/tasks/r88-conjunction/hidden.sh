set -e
swift test --package-path Packages/DictationCore --filter CleanVerbatimTests
# The Swift pipeline must write the reference's recording for the reference's
# corpus, and the Rust core must reproduce that recording.
swift build --package-path core/conformance/generator
core/conformance/generator/.build/debug/GenerateFixtures core/conformance/corpus-text.json core/conformance/fixtures/text/pipeline.json
cmp core/conformance/fixtures/text/pipeline.json "$REF/core/conformance/fixtures/text/pipeline.json"
cargo test -p ramble-text --test conformance
