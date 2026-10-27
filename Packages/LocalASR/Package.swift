// swift-tools-version: 6.0
import PackageDescription

// LocalASR — installing the model and recognizing speech with it.
//
// The only place in the entire project that touches the inference runtime is
// TranscribeCppAdapter.swift. Everything else talks to ASREngineAdapting,
// declared in DictationCore — which is what made replacing the previous engine
// a contained change instead of a rewrite.
let package = Package(
    name: "LocalASR",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalASR", targets: ["LocalASR"]),
        .executable(name: "asr-bench", targets: ["asr-bench"]),
    ],
    dependencies: [
        .package(path: "../DictationCore"),
    ],
    targets: [
        // The transcribe.cpp inference runtime, as the prebuilt XCFramework
        // published with its release. Pinned by exact URL and checksum for the
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
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.4.1/TranscribeCpp.xcframework.zip",
            checksum: "fb5646e564036a6c49659e3efcf72eb567af20da31b8569045c9a08181d35126"
        ),
        .target(
            name: "LocalASR",
            dependencies: [
                .product(name: "DictationCore", package: "DictationCore"),
                "CTranscribe",
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
