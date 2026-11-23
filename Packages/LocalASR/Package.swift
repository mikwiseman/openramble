// swift-tools-version: 6.0
import PackageDescription

// LocalASR — installing the model and recognizing speech with it.
//
// Two files in the entire project touch a recognition engine:
// TranscribeCppAdapter.swift, which runs Apple silicon Macs on Metal, and
// OreAdapter.swift, which runs Intel Macs and the iPhone on our own engine.
// The Metal runtime is a Mac-only binary, so on iOS the package builds without
// it and that adapter compiles to nothing. Everything else
// talks to ASREngineAdapting, declared in DictationCore — which is what made
// replacing the previous engine a contained change instead of a rewrite.
let package = Package(
    name: "LocalASR",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LocalASR", targets: ["LocalASR"]),
        .executable(name: "asr-bench", targets: ["asr-bench"]),
    ],
    dependencies: [
        .package(path: "../DictationCore"),
        // Our own recognition engine: plain C with no dependencies, compiled
        // from the repository's `engine/` folder. Intel Macs recognize with
        // it, and so does the iPhone; Windows, Linux and the server compile the
        // same files.
        .package(name: "ORE", path: "../../engine"),
    ],
    targets: [
        // The transcribe.cpp inference runtime from our fork: release 0.4.1 plus
        // the Parakeet long-form fix (upstream issue #235), the decoder's
        // per-step products on Accelerate, and phrase boosting for the words a
        // person taught (upstream pull request #221), built from commit
        // dacdba09 by scripts/build-transcribe-xcframework.sh and published
        // with the fork's release. Pinned by exact URL and checksum for the
        // same reason every other dependency here is: a build must not be able
        // to change what it links without the change being visible in a diff.
        //
        // The binary was audited before adoption. Its only Objective-C class
        // references are Metal types plus NSLock, NSNumber, NSString, NSURL and
        // the mutable collections, its only NSURL selector is
        // `fileURLWithPath:`, and it links Metal, MetalKit, Accelerate,
        // Foundation and libc++ — no CFNetwork, no sockets, no TLS.
        // `scripts/check-network-surface.sh` re-runs that audit on every check.
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/mikwiseman/transcribe.cpp/releases/download/v0.4.1-dacdba09/TranscribeCpp.xcframework.zip",
            checksum: "f181b34da5aa9896bced3d9d0da4ad3a2b7d3b8028f0174abeb9c74449bf7d3d"
        ),
        .target(
            name: "LocalASR",
            dependencies: [
                .product(name: "DictationCore", package: "DictationCore"),
                .target(name: "CTranscribe", condition: .when(platforms: [.macOS])),
                .product(name: "ORE", package: "ORE"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        //P0 phase tool: download, check, recognize, measure.
        .executableTarget(
            name: "asr-bench",
            dependencies: [
                "LocalASR",
                .product(name: "DictationCore", package: "DictationCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LocalASRTests",
            dependencies: ["LocalASR"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // End-to-end tests: dictation controller, real model and real
        // text pipelines are connected to each other. They live here, not in
        // DictationCore because it's the only package that sees and
        // pure logic and loaded model.
        //
        // The goal is separate, so that there is something to separate it: without an installed model
        // tests are skipped, and `--filter DictationEndToEndTests` makes it run
        // only them.
        .testTarget(
            name: "DictationEndToEndTests",
            dependencies: [
                "LocalASR",
                .product(name: "DictationCore", package: "DictationCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
