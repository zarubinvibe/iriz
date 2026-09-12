import Foundation
import IrizCore
import Testing

@testable import IrizDictate

@Suite("Подготовка и восстановление модели без сети")
struct SpeechModelRecoveryTests {
    @Test("сетевые ошибки установки объясняют причину и действие без технического кода")
    func installErrorsExplainRecovery() {
        let cases: [(URLError.Code, String, String)] = [
            (.notConnectedToInternet, "speechModel.error.offline", "Нет подключения к интернету. Подключись к сети и повтори скачивание."),
            (.networkConnectionLost, "speechModel.error.connectionLost", "Соединение прервалось. Проверь интернет и повтори скачивание."),
            (.timedOut, "speechModel.error.timeout", "Сервер не ответил вовремя. Повтори скачивание чуть позже."),
            (.cancelled, "speechModel.error.cancelled", "Скачивание отменено. Его можно запустить снова.")
        ]
        for (code, key, fallback) in cases {
            let message = speechModelInstallFailureMessage(for: URLError(code))
            #expect(message == L(key, fallback))
            #expect(!message.contains("NSURLErrorDomain"))
        }
        #expect(speechModelInstallFailureMessage(for: CancellationError())
                == speechModelInstallFailureMessage(for: URLError(.cancelled)))
        let unknown = NSError(domain: "fixture", code: 42,
                              userInfo: [NSLocalizedDescriptionKey: "Подробности отказа"])
        #expect(speechModelInstallFailureMessage(for: unknown) == "Подробности отказа")
    }

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iriz-model-recovery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("пустая или неполная папка не означает установленную модель")
    func cacheRequiresEveryModelFile() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!speechModelCacheIsComplete(for: .multilingualV3, at: root))
        for file in ModelIntegrity.parakeetV3DownloadFiles {
            let target = root.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: target)
        }
        // Быстрый UI-probe проверяет состав. SHA-256 проверяется отдельно.
        #expect(speechModelCacheIsComplete(for: .multilingualV3, at: root))
        let vocabulary = root.appendingPathComponent("parakeet_vocab.json")
        try Data().write(to: vocabulary)
        #expect(!speechModelCacheIsComplete(for: .multilingualV3, at: root))
        try FileManager.default.removeItem(at: vocabulary)
        #expect(!speechModelCacheIsComplete(for: .multilingualV3, at: root))
    }

    @Test("Whisper требует непустой файл, каталог с именем модели не подходит")
    func whisperRequiresNonemptyFile() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("ggml-large-v3-turbo.bin")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: false)
        #expect(!speechModelCacheIsComplete(for: .whisperTurbo, at: root))
        try FileManager.default.removeItem(at: model)
        try Data().write(to: model)
        #expect(!speechModelCacheIsComplete(for: .whisperTurbo, at: root))
        try Data("fixture".utf8).write(to: model)
        #expect(speechModelCacheIsComplete(for: .whisperTurbo, at: root))
    }

    @Test("адреса скачивания ограничены файлами закреплённого манифеста")
    func downloadsUsePinnedAllowlist() throws {
        for file in ModelIntegrity.parakeetV3DownloadFiles {
            let url = try speechModelDownloadURL(for: file)
            #expect(url.scheme == "https")
            #expect(url.host == "huggingface.co")
            #expect(url.path.contains("/resolve/" + ModelIntegrity.parakeetV3RepositoryCommit + "/"))
            #expect(!url.path.contains("/resolve/main/"))
        }
        #expect(throws: URLError.self) {
            try speechModelDownloadURL(for: ModelFileDigest(relativePath: "../outside.bin",
                                                            sha256: String(repeating: "0", count: 64)))
        }
    }

    @Test("публикация новой модели сохраняет предыдущую копию")
    func publicationKeepsPreviousCache() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        for url in [cache, staging] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data("previous".utf8).write(to: cache.appendingPathComponent("model"))
        try Data("new".utf8).write(to: staging.appendingPathComponent("model"))
        try publishSpeechModelCache(from: staging, to: cache)
        #expect(try String(contentsOf: cache.appendingPathComponent("model"), encoding: .utf8) == "new")
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".iriz-model-backup-") }
        let backup = try #require(backups.first)
        #expect(backups.count == 1)
        #expect(try String(contentsOf: backup.appendingPathComponent("model"), encoding: .utf8) == "previous")
    }

    @Test("отказ публикации возвращает предыдущую модель на прежнее место")
    func failedPublicationRestoresCache() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("previous".utf8).write(to: cache.appendingPathComponent("model"))
        #expect(throws: (any Error).self) {
            try publishSpeechModelCache(from: root.appendingPathComponent("missing"), to: cache)
        }
        #expect(try String(contentsOf: cache.appendingPathComponent("model"), encoding: .utf8) == "previous")
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries == ["cache"])
    }

    @MainActor
    @Test("после установки можно повторить неудачный прогрев без записи и изменения настроек")
    func failedPreparationCanRetry() async {
        let name = "iriz-model-preparation-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { removeSuiteFile(named: name, defaults: defaults) }
        let settings = DictationSettings(defaults: defaults)
        settings.speechEngine = .multilingualV3
        let probe = ModelPreparationProbe()
        let controller = DictationController(settings: settings,
                                            insertionStats: InsertionStats(defaults: defaults),
                                            modelLoader: { try await probe.load($0) })
        #expect(controller.prepareAfterModelInstallation())
        #expect(controller.state == .warmingUp)
        #expect(!controller.prepareAfterModelInstallation())
        await controller.pendingWarmUp?.value
        guard case .unavailable = controller.state else {
            Issue.record("Первый отказ загрузчика должен оставаться видимым")
            return
        }
        #expect(controller.prepareAfterModelInstallation())
        #expect(controller.state == .warmingUp)
        await controller.pendingWarmUp?.value
        #expect(controller.state == .ready)
        #expect(!controller.isRecordingActive)
        #expect(settings.speechEngine == .multilingualV3)
        #expect(await probe.profiles == [.multilingualV3, .multilingualV3])
    }

    @MainActor
    @Test("сохранённый выбор установленного движка восстанавливает unavailable без перезапуска")
    func changingEngineRetriesPreparation() async {
        let name = "iriz-model-selection-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { removeSuiteFile(named: name, defaults: defaults) }
        let settings = DictationSettings(defaults: defaults)
        settings.speechEngine = .whisperTurbo
        let probe = ModelPreparationProbe()
        let controller = DictationController(settings: settings,
                                            insertionStats: InsertionStats(defaults: defaults),
                                            modelLoader: { try await probe.load($0) })
        #expect(controller.prepareAfterModelInstallation())
        await controller.pendingWarmUp?.value
        guard case .unavailable = controller.state else {
            Issue.record("Первый отказ должен быть видимым")
            return
        }
        settings.speechEngine = .multilingualV3
        controller.applySettings()
        #expect(controller.state == .warmingUp)
        await controller.pendingWarmUp?.value
        #expect(controller.state == .ready)
        #expect(await probe.profiles == [.whisperTurbo, .multilingualV3])
        #expect(!controller.isRecordingActive)
        controller.applySettings()
        #expect(controller.pendingWarmUp == nil)
    }
}

private actor ModelPreparationProbe {
    private(set) var profiles: [SpeechModelProfile] = []

    func load(_ profile: SpeechModelProfile) throws {
        profiles.append(profile)
        if profiles.count == 1 { throw URLError(.cannotOpenFile) }
    }
}
