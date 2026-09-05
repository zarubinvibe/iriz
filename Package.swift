// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IrizApp",
    // Язык оригинала. В коде стоят русские строки, переводы лежат рядом
    // таблицами: Sources/IrizCore/Resources/<язык>.lproj/Localizable.strings.
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iriz", targets: ["iriz"]),
        .executable(name: "SettingsPreview", targets: ["SettingsPreview"]),
    ],
    dependencies: [
        // Единственная разрешённая внешняя зависимость проекта (этап 6).
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // Движок распознавания речи (Parakeet TDT v3 на CoreML/ANE), этап Э2.
        // Пин по revision — тот же, что у донора SuperDictate.
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "313feb4bd692780a9a5b5fa9048fdb119486dde8"),
    ],
    targets: [
        // Кандидат в движки, волна 2. Пакета SwiftPM у whisper.cpp НЕТ: Package.swift
        // удален из репозитория 13.03.2025 коммитом 5bb1d58c6, вместо него положен
        // build-xcframework.sh. Поэтому единственный путь - удаленный binaryTarget на
        // опубликованный ассет релиза. Диапазон версий binaryTarget не принимает:
        // обновление - ручная правка ссылки И суммы, сумма посчитана по скачанному файлу.
        // Тег v1.9.2, а НЕ последний: у v1.9.3 ассета XCFramework нет вовсе (HTTP 404).
        .binaryTarget(
            name: "WhisperFramework",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        ),
        .target(
            name: "IrizCore",
            path: "Sources/IrizCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "IrizInput",
            dependencies: ["IrizCore"],
            path: "Sources/IrizInput"
        ),
        .target(
            name: "IrizImport",
            dependencies: ["IrizCore"],
            path: "Sources/IrizImport"
        ),
        .target(
            name: "IrizDictate",
            dependencies: [
                "IrizCore",
                "IrizPrompt",
                .product(name: "FluidAudio", package: "FluidAudio"),
                "WhisperFramework",
            ],
            path: "Sources/IrizDictate"
        ),
        .target(
            name: "IrizPrompt",
            dependencies: ["IrizCore"],
            path: "Sources/IrizPrompt"
        ),
        .target(
            name: "IrizSettings",
            dependencies: ["IrizDictate", "IrizInput", "IrizCore", "IrizPrompt"],
            path: "Sources/IrizSettings",
            exclude: ["Preview"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "SettingsPreview",
            dependencies: ["IrizSettings"],
            path: "Sources/IrizSettings/Preview"
        ),
        .executableTarget(
            name: "IrizApp",
            dependencies: ["IrizCore", "IrizInput", "IrizImport", "IrizDictate", "IrizSettings"],
            path: "Sources/IrizApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "iriz",
            dependencies: [
                "IrizCore",
                // Расшифровка файла/папки (`smltlk transcribe`) зовёт тот же
                // TranscriptionWorker, что и живая диктовка. Новых внешних
                // зависимостей это не добавляет: FluidAudio уже в пакете.
                "IrizDictate",
                "IrizInput",
                "IrizPrompt",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/iriz",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "IrizCoreTests",
            dependencies: ["IrizCore", "IrizInput", "IrizImport", "IrizPrompt"],
            path: "Tests/IrizCoreTests"
        ),
        .testTarget(
            name: "IrizDictateTests",
            dependencies: ["IrizDictate"],
            path: "Tests/IrizDictateTests"
        ),
        .testTarget(
            name: "IrizSettingsTests",
            dependencies: ["IrizSettings"],
            path: "Tests/IrizSettingsTests"
        ),
        // Меню строки меню: решения (заголовок, статистика, подсказка диктовки,
        // авария, подпись для VoiceOver) - чистые свойства MenuState, и до этой
        // волны их не проверял никто, потому что тестовой цели у IrizApp
        // не было вовсе.
        .testTarget(
            name: "IrizAppTests",
            dependencies: ["IrizApp"],
            path: "Tests/IrizAppTests"
        ),
    ]
)
