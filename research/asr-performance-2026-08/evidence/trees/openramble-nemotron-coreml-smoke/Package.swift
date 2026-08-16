// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NemotronCoreMLSmoke",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "$HOME/Library/Developer/Xcode/DerivedData/OpenRamble-agrxykzcjgqnlqeydbgauoyffaxv/SourcePackages/checkouts/FluidAudio")
    ],
    targets: [
        .executableTarget(
            name: "NemotronCoreMLSmoke",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
