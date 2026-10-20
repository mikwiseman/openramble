// swift-tools-version: 6.0
import PackageDescription

// Research harness, not shipping code. It drives the shipping
// `MicrophoneCapture` exactly as a key-down does and measures whether the
// start of speech lands inside the take.
let package = Package(
    name: "OnsetHarness",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../../Packages/DictationCore"),
    ],
    targets: [
        .executableTarget(
            name: "first-word-onset",
            dependencies: [
                .product(name: "DictationCore", package: "DictationCore"),
                .product(name: "DictationAudio", package: "DictationCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
