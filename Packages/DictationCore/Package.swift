// swift-tools-version: 6.0
import PackageDescription

// DictationCore — чистая логика диктовки без ML-зависимостей.
//
// Направление зависимости выбрано намеренно: протокол ASREngineAdapting объявлен
// ЗДЕСЬ, а пакет LocalASR (который тянет FluidAudio) зависит от нас. Обратное
// направление затащило бы граф FluidAudio в каждый `swift test` чистой логики.
let package = Package(
    name: "DictationCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DictationCore", targets: ["DictationCore"]),
        .library(name: "DictationAudio", targets: ["DictationAudio"]),
    ],
    targets: [
        // Чистая логика: политики жестов, контроллер диктовки, текстовый конвейер,
        // хранилища, локализация. Никакого AppKit — края приложения за протоколами.
        .target(
            name: "DictationCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Захват звука: движок, ресемплер, кольцевой буфер, запись WAV.
        .target(
            name: "DictationAudio",
            dependencies: ["DictationCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DictationCoreTests",
            dependencies: ["DictationCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DictationAudioTests",
            dependencies: ["DictationAudio"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
