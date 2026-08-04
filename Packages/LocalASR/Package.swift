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
        // Immutable commit тега 0.15.5: даже перемещённый upstream tag не
        // изменит код release-сборки.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "19600a485baa4998812e4654b70d2bab8f2c9949"
        ),
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
            dependencies: [
                "LocalASR",
                .product(name: "DictationCore", package: "DictationCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LocalASRTests",
            dependencies: ["LocalASR"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Скорер WER/CER живёт в инструменте замеров, но считать он обязан
        // честно — иначе цифры в отчётах ничего не значат.
        .testTarget(
            name: "ASRBenchTests",
            dependencies: ["asr-bench"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Сквозные тесты: контроллер диктовки, настоящая модель и настоящий
        // текстовый конвейер соединены друг с другом. Живут здесь, а не в
        // DictationCore, потому что это единственный пакет, который видит и
        // чистую логику, и загруженную модель.
        //
        // Цель отдельная, чтобы её было чем отделить: без установленной модели
        // тесты пропускаются, а `--filter DictationEndToEndTests` даёт прогнать
        // только их.
        .testTarget(
            name: "DictationEndToEndTests",
            dependencies: [
                "LocalASR",
                .product(name: "DictationCore", package: "DictationCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
