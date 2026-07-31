// swift-tools-version: 6.0
import PackageDescription

// LocalASR — установка модели и локальное распознавание.
//
// Единственное место во всём проекте, где импортируется FluidAudio, — файл
// FluidAudioAdapter.swift. Всё остальное общается через ASREngineAdapting,
// объявленный в DictationCore.
let package = Package(
    name: "LocalASR",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalASR", targets: ["LocalASR"]),
        .executable(name: "asr-bench", targets: ["asr-bench"]),
    ],
    dependencies: [
        .package(path: "../DictationCore"),
        // Пин точный, не `from:` — документация FluidAudio местами расходится с API тега.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
    ],
    targets: [
        .target(
            name: "LocalASR",
            dependencies: [
                .product(name: "DictationCore", package: "DictationCore"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Инструмент фазы P0: скачать, проверить, распознать, замерить.
        .executableTarget(
            name: "asr-bench",
            dependencies: ["LocalASR"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LocalASRTests",
            dependencies: ["LocalASR"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
