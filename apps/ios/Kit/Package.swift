// swift-tools-version: 6.0
import PackageDescription

// The Live Activity's attributes and the intents its buttons and the Dictate
// control run. A package, linked statically into both the app and the widget
// extension, so the module is one and the types are the same in both: the
// system then finds the same intent in the app and runs it there, and each
// target carries the intents in its own App Intents metadata, which a control
// requires.
let package = Package(
    name: "OpenRambleKit",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "OpenRambleKit", targets: ["OpenRambleKit"]),
    ],
    targets: [
        .target(name: "OpenRambleKit", swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
