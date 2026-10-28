// swift-tools-version: 6.1
import PackageDescription

// Runner for the runtime spike: FluidAudio (Core ML) Parakeet TDT v3 or Ultra.
//
// FluidAudio is used from a local checkout of tag v0.17.7 (commit 503b4bd1),
// made with
//   git clone --depth 1 --branch v0.17.7 https://github.com/FluidInference/FluidAudio.git \
//     ~/Library/Caches/OpenRambleSpike/fluidaudio/src
// so SwiftPM does not mirror the whole 300 MB repository into its shared cache.
// FLUIDAUDIO_SRC overrides the location. `traits: []` leaves out FluidAudio's
// NeMo text-normalization binary, which ASR does not need.
let fluidAudio =
    Context.environment["FLUIDAUDIO_SRC"]
    ?? (Context.environment["HOME"] ?? "") + "/Library/Caches/OpenRambleSpike/fluidaudio/src"

let package = Package(
    name: "fluidaudio-runner",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: fluidAudio, traits: [])
    ],
    targets: [
        .executableTarget(
            name: "fluidaudio-runner",
            dependencies: [.product(name: "FluidAudio", package: "src")]
        )
    ]
)
