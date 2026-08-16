// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenRambleShortShapeHarness",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../FluidAudio")
    ],
    targets: [
        .executableTarget(
            name: "short-shape-bench",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        )
    ]
)
