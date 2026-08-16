// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenRambleFusedTdtSmoke",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../FluidAudio")
    ],
    targets: [
        .executableTarget(
            name: "fused-tdt-smoke",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        )
    ]
)
