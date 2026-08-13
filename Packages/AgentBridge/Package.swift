// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentBridge", targets: ["AgentBridge"]),
    ],
    targets: [
        .target(
            name: "AgentBridge",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "AgentBridgeTests",
            dependencies: ["AgentBridge"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
