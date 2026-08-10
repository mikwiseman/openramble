// swift-tools-version: 6.0
import PackageDescription

// DictationCore - pure dictation logic without ML dependencies.
//
// The direction of the dependency is intentional: the ASREngineAdapting protocol is declared
// HERE, and the LocalASR package (which pulls FluidAudio) depends on us. Reverse
// the direction would drag the FluidAudio graph into each `swift test` of pure logic.
let package = Package(
    name: "DictationCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DictationCore", targets: ["DictationCore"]),
        .library(name: "DictationAudio", targets: ["DictationAudio"]),
    ],
    targets: [
        // Pure logic: gesture policies, dictation controller, text pipeline,
        // storage, localization. No AppKit - the edges of the application are behind the protocols.
        .target(
            name: "DictationCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Audio capture: engine, resampler, ring buffer, WAV recording.
        .target(
            name: "DictationAudio",
            dependencies: ["DictationCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DictationCoreTests",
            dependencies: ["DictationCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DictationAudioTests",
            dependencies: ["DictationAudio"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
