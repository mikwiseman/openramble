// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ASRWorkerProtocol",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ASRWorkerProtocol", targets: ["ASRWorkerProtocol"]),
    ],
    targets: [
        .target(
            name: "ASRWorkerProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ASRWorkerProtocolTests",
            dependencies: ["ASRWorkerProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
