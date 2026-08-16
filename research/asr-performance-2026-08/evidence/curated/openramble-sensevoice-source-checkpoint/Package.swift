// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenRambleSenseVoiceProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "FluidAudio")
    ],
    targets: [
        .executableTarget(
            name: "sensevoice-probe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/SenseVoiceProbe"
        )
    ]
)
