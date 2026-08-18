// swift-tools-version: 6.0
import PackageDescription

// Runs the shipping macOS text pipeline over a corpus and writes what it
// produced. Those recordings are the fixtures the Rust port must reproduce
// exactly — the only honest check that the two implementations agree.
//
// Deliberately its own package rather than a target in DictationCore: nothing
// that ships should depend on a fixture generator.
let package = Package(
    name: "GenerateFixtures",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../Packages/DictationCore")],
    targets: [
        .executableTarget(
            name: "GenerateFixtures",
            dependencies: [.product(name: "DictationCore", package: "DictationCore")]
        )
    ]
)
