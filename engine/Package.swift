// swift-tools-version:5.9
import PackageDescription

// The engine as a Swift package: the C sources compiled as they are, with
// ore.h as the module's interface. The kernels are always optimized, because a
// debug build of them is twenty times slower and the tests run real speech.
let package = Package(
    name: "ORE",
    products: [
        .library(name: "ORE", targets: ["ORE"]),
    ],
    targets: [
        .target(
            name: "ORE",
            path: ".",
            exclude: ["CMakeLists.txt", "tools", "tests", "scripts", "README.md", "NOTICE.md"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-O3"])]
        ),
    ]
)
