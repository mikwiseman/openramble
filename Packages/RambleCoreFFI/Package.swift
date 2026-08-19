// swift-tools-version: 6.0
import PackageDescription

// The shared Rust core, as a Swift package.
//
// Both the generated Swift and the binary it calls are produced by
// scripts/build-ffi.sh and are not checked in: they are build output, and a
// committed copy would silently disagree with the Rust it was generated from.
//
// The generated code is kept in its own package on purpose. It is machine
// written, it does not satisfy the strict-concurrency settings the app builds
// with, and isolating it means the application target's own settings stay
// untouched.
let package = Package(
    name: "RambleCoreFFI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RambleCore", targets: ["RambleCore"])
    ],
    targets: [
        .binaryTarget(name: "RambleCoreFFI", path: "RambleCoreFFI.xcframework"),
        .target(
            name: "RambleCore",
            dependencies: ["RambleCoreFFI"],
            // The core now contains the inference runtime, which is C++ built on
            // Metal. A Rust static library carries no link instructions of its
            // own, so the dependencies it inherited have to be named here or the
            // symbols simply go missing at link time.
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .testTarget(name: "RambleCoreTests", dependencies: ["RambleCore"]),
    ]
)
