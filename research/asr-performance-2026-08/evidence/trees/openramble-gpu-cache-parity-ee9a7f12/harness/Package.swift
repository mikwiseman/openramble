// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenRamblePhaseBench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../FluidAudio")],
    targets: [
        .executableTarget(
            name: "phase-bench",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
