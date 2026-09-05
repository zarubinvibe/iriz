// Тесты аудио-хелперов (уровень сигнала, моно-микс) и целостности модели.
import Foundation
import IrizPrompt
import Testing

@testable import IrizDictate

// MARK: - Уровень звука

@Suite("normalizedAudioLevel")
struct AudioLevelTests {
    @Test func silenceIsZero() {
        #expect(normalizedAudioLevel(from: [Float](repeating: 0, count: 1600)) == 0)
    }

    @Test func nonFiniteSamplesAreSkipped() {
        #expect(normalizedAudioLevel(from: [.nan, .infinity, -.infinity]) == 0)
    }

    @Test func fullScaleSignalIsLoud() {
        let level = normalizedAudioLevel(from: [Float](repeating: 0.8, count: 1600))
        #expect(level > 0.9)
    }

    @Test func emptyInputIsZero() {
        #expect(normalizedAudioLevel(sumSquares: 0, sampleCount: 0) == 0)
    }
}

// MARK: - Моно-микс

@Suite("mono mix channel selection")
struct MonoMixTests {
    @Test func picksChannelsNearPeak() {
        // Пик 0.5 → порог 0.125: канал 0 (0.1) отсеян, канал 2 (0.05) тоже.
        #expect(selectedMonoMixChannelIndices(channelRMS: [0.1, 0.5, 0.05]) == [1])
    }

    @Test func keepsAllActiveChannels() {
        #expect(selectedMonoMixChannelIndices(channelRMS: [0.5, 0.4]) == [0, 1])
    }

    @Test func silentInputFallsBackToFirstChannel() {
        #expect(selectedMonoMixChannelIndices(channelRMS: [0, 0]) == [0])
        #expect(selectedMonoMixChannelIndices(channelRMS: []) == [0])
    }
}

// MARK: - Целостность модели

@Suite("ModelIntegrity")
struct ModelIntegrityTests {
    private func withTempRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smltlk-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func sha256OfKnownContent() throws {
        try withTempRoot { root in
            let file = root.appendingPathComponent("data.bin")
            try Data("hello world".utf8).write(to: file)
            // Эталон: sha256("hello world")
            #expect(try ModelIntegrity.sha256Hex(of: file, relativePath: "data.bin")
                    == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        }
    }

    @Test func verifyFilesAcceptsMatchingTree() throws {
        try withTempRoot { root in
            let dir = root.appendingPathComponent("Model.mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("model.mil")
            try Data("hello world".utf8).write(to: file)
            try ModelIntegrity.verifyFiles(
                root: root,
                expectedFiles: [ModelFileDigest(
                    relativePath: "Model.mlmodelc/model.mil",
                    sha256: "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")],
                strictDirectories: ["Model.mlmodelc"]
            )
        }
    }

    @Test func verifyFilesRejectsDigestMismatch() throws {
        try withTempRoot { root in
            let file = root.appendingPathComponent("model.mil")
            try Data("tampered".utf8).write(to: file)
            #expect(throws: ModelIntegrityError.self) {
                try ModelIntegrity.verifyFiles(
                    root: root,
                    expectedFiles: [ModelFileDigest(
                        relativePath: "model.mil",
                        sha256: "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")],
                    strictDirectories: [])
            }
        }
    }

    @Test func verifyFilesRejectsMissingFile() throws {
        try withTempRoot { root in
            #expect(throws: ModelIntegrityError.self) {
                try ModelIntegrity.verifyFiles(
                    root: root,
                    expectedFiles: [ModelFileDigest(
                        relativePath: "nope.bin",
                        sha256: "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")],
                    strictDirectories: [])
            }
        }
    }

    @Test func verifyFilesRejectsUnexpectedFileInStrictDirectory() throws {
        try withTempRoot { root in
            let dir = root.appendingPathComponent("Model.mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("stowaway.bin"))
            #expect(throws: ModelIntegrityError.self) {
                try ModelIntegrity.verifyFiles(root: root,
                                               expectedFiles: [],
                                               strictDirectories: ["Model.mlmodelc"])
            }
        }
    }
}

// MARK: - Настройки диктовки (дефолты владельца)

/// Сносит домен И его файл. Одного removePersistentDomain мало: cfprefsd дописывает
/// plist обратно уже после выхода процесса, и в ~/Library/Preferences владельца
/// остаётся мусор от каждого прогона тестов.
func removeSuiteFile(named name: String, defaults: UserDefaults) {
    defaults.removePersistentDomain(forName: name)
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist")
    try? FileManager.default.removeItem(at: url)
}

@Suite("DictationSettings defaults")
struct DictationSettingsTests {
    /// Изолированный домен настроек на время одной проверки. Домен сносится ПОСЛЕ
    /// работы, а не только до неё: иначе каждый прогон тестов оставлял бы по файлу
    /// в ~/Library/Preferences владельца (за ночь их накопилось 49).
    private func withIsolatedDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
        let name = "smltlk-dictate-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { removeSuiteFile(named: name, defaults: defaults) }
        return try body(defaults)
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func toggleIsDefaultTriggerMode() {
        withIsolatedDefaults { #expect(DictationSettings(defaults: $0).triggerMode == .toggle) }
    }

    @Test func rightCommandIsDefaultHotkey() {
        withIsolatedDefaults { d in
            let settings = DictationSettings(defaults: d)
            #expect(settings.hotkeyKeycode == 54)
            #expect(settings.hotkeyModifiers.isEmpty)
            #expect(settings.configuredHotkey.isModifier)
        }
    }

    @Test func alternateAndHistoryDefaults() {
        withIsolatedDefaults { d in
            let settings = DictationSettings(defaults: d)
            #expect(settings.enterHotkeyKeycode == 54)
            #expect(settings.enterHotkeyModifiers == .maskAlternate)
            #expect(settings.historyHotkeyKeycode == 54)
            #expect(settings.historyHotkeyModifiers == .maskShift)
            #expect(settings.alternateCompletionEnabled)
        }
    }

    @Test func promptDefaults() {
        withIsolatedDefaults { defaults in
            let settings = DictationSettings(defaults: defaults)
            #expect(!settings.promptModeEnabled)
            #expect(settings.promptRecipient == .codex)
            #expect(settings.promptHotkeyKeycode == RIGHT_COMMAND_KEYCODE)
            #expect(settings.promptHotkeyModifiers == .maskControl)
            #expect(settings.configuredPromptHotkey
                    == hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE, modifiers: .maskControl))
            #expect(settings.codexExecutablePath.isEmpty)
            #expect(!settings.promptOnboardingOffered)
        }
    }

    @Test func promptSettingsPersist() {
        withIsolatedDefaults { defaults in
            var settings = DictationSettings(defaults: defaults)
            settings.promptModeEnabled = true
            settings.promptRecipient = .generic
            settings.promptHotkeyKeycode = 96
            settings.promptHotkeyModifiers = [.maskCommand, .maskShift]
            settings.codexExecutablePath = "/tmp/codex-test"
            settings.promptOnboardingOffered = true

            settings = DictationSettings(defaults: defaults)
            #expect(settings.promptModeEnabled)
            #expect(settings.promptRecipient == .generic)
            #expect(settings.promptHotkeyKeycode == 96)
            #expect(settings.promptHotkeyModifiers == [.maskCommand, .maskShift])
            #expect(settings.codexExecutablePath == "/tmp/codex-test")
            #expect(settings.promptOnboardingOffered)
        }
    }

    @Test func invalidPromptRecipientFallsBackToCodex() {
        withIsolatedDefaults { defaults in
            defaults.set("unknown-recipient", forKey: "prompt_recipient_profile_v2")

            #expect(DictationSettings(defaults: defaults).promptRecipient == .codex)
        }
    }

    /// Неизвестный агент в хранилище не должен молча увести расшифровку к
    /// кому-то другому: откатываемся к дефолту, а не к первому попавшемуся.
    @Test func promptAgentDefaultsAndPersists() {
        withIsolatedDefaults { defaults in
            var settings = DictationSettings(defaults: defaults)
            #expect(settings.promptAgentID == PromptAgentCatalog.defaultID)
            #expect(settings.promptAgentAdapter.id == PromptAgentCatalog.codexID)
            #expect(settings.promptAgentModel.isEmpty)
            #expect(settings.promptAgentCustomArguments.isEmpty)

            settings.promptAgentID = PromptAgentCatalog.ollamaID
            settings.promptAgentModel = "qwen2.5-coder:7b"
            settings.promptAgentCustomArguments = ["--flag", "{prompt}"]
            settings.setPromptAgentPath("/tmp/ollama-test", for: PromptAgentCatalog.ollamaID)
            settings.setPromptAgentPath("/tmp/codex-test", for: PromptAgentCatalog.codexID)

            settings = DictationSettings(defaults: defaults)
            #expect(settings.promptAgentID == PromptAgentCatalog.ollamaID)
            #expect(settings.promptAgentAdapter.requiresModel)
            #expect(settings.promptAgentModel == "qwen2.5-coder:7b")
            #expect(settings.promptAgentCustomArguments == ["--flag", "{prompt}"])
            #expect(settings.promptAgentPath(for: PromptAgentCatalog.ollamaID) == "/tmp/ollama-test")
            // Путь Codex остался в донорском ключе и не смешался с новым.
            #expect(settings.promptAgentPath(for: PromptAgentCatalog.codexID) == "/tmp/codex-test")
            #expect(settings.codexExecutablePath == "/tmp/codex-test")

            defaults.set("нет-такого-агента", forKey: "prompt_agent_id_v1")
            #expect(DictationSettings(defaults: defaults).promptAgentID
                    == PromptAgentCatalog.defaultID)
        }
    }

    /// Автопоиск ищет исполняемый файл выбранного агента, а не только Codex.
    @Test func agentDetectionFindsChosenExecutableInPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smltlk-agent-detect-\(UUID().uuidString)", isDirectory: true)
        let pathDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: pathDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ollama = pathDirectory.appendingPathComponent("ollama")
        try makeExecutable(at: ollama)

        #expect(DictationSettings.detectAgentExecutable(
            adapter: PromptAgentCatalog.ollama,
            pathEnvironment: pathDirectory.path,
            homeDirectory: root
        ) == ollama)
        // Codex по тому же PATH не находится: имена разные.
        #expect(DictationSettings.detectAgentExecutable(
            adapter: PromptAgentCatalog.codex,
            pathEnvironment: pathDirectory.path,
            homeDirectory: root
        ) == nil)
        // Свой CLI автопоиска не имеет: путь задаёт владелец.
        #expect(DictationSettings.detectAgentExecutable(
            adapter: PromptAgentCatalog.custom(arguments: []),
            pathEnvironment: pathDirectory.path,
            homeDirectory: root
        ) == nil)
        #expect(DictationSettings.detectAgentExecutable(
            adapter: PromptAgentCatalog.custom(arguments: []),
            storedPath: ollama.path,
            pathEnvironment: pathDirectory.path,
            homeDirectory: root
        ) == ollama)
    }

    @Test func codexDetectionUsesStoredPathThenPATHThenKnownHomePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smltlk-codex-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stored = root.appendingPathComponent("stored-codex")
        let pathDirectory = root.appendingPathComponent("path-bin", isDirectory: true)
        let pathCodex = pathDirectory.appendingPathComponent("codex")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let homeCodex = home.appendingPathComponent(".npm-global/bin/codex")
        try makeExecutable(at: stored)
        try makeExecutable(at: pathCodex)
        try makeExecutable(at: homeCodex)

        #expect(DictationSettings.detectCodexExecutable(
            storedPath: stored.path,
            pathEnvironment: pathDirectory.path,
            homeDirectory: home
        ) == stored)
        #expect(DictationSettings.detectCodexExecutable(
            storedPath: root.appendingPathComponent("missing").path,
            pathEnvironment: pathDirectory.path,
            homeDirectory: home
        ) == pathCodex)
        #expect(DictationSettings.detectCodexExecutable(
            pathEnvironment: "",
            homeDirectory: home
        ) == homeCodex)

        withIsolatedDefaults { defaults in
            let settings = DictationSettings(defaults: defaults)
            settings.codexExecutablePath = stored.path
            #expect(settings.detectCodexExecutable() == stored)
        }
    }

    @Test func textDefaults() {
        withIsolatedDefaults { d in
            let settings = DictationSettings(defaults: d)
            #expect(settings.pasteSuffix == .appendSpace)
            #expect(settings.dictationLanguage == .auto)
            #expect(settings.removeFinalPeriod == false)
            #expect(settings.enterDelayMilliseconds == 120)
            #expect(settings.primaryCompletionBehavior == .insert)
            #expect(settings.playFeedbackSounds)
            // По умолчанию словарь замен НЕ пуст: заводской набор подсаживается
            // при первом создании настроек, иначе он остался бы мёртвым кодом.
            #expect(settings.transcriptCorrections == defaultTranscriptCorrections)
        }
    }

    @Test func enterDelayIsClamped() {
        withIsolatedDefaults { d in
            let settings = DictationSettings(defaults: d)
            settings.enterDelayMilliseconds = 9999
            #expect(settings.enterDelayMilliseconds == 500)
            settings.enterDelayMilliseconds = -5
            #expect(settings.enterDelayMilliseconds == 0)
        }
    }

    @Test func garbageHotkeyFallsBackToDefault() {
        withIsolatedDefaults { d in
            d.set("несусветное", forKey: "hotkey_keycode")
            #expect(DictationSettings(defaults: d).hotkeyKeycode == 54)
        }
    }
}

@Suite("установка модели: когда качать нельзя")
struct SpeechModelInstallTests {
    /// Отказы названы по приоритету, и приоритет не случайный: идущая
    /// установка старше всего, потому что вторая затрёт файлы первой; идущая
    /// диктовка старше «уже стоит», потому что снятый рубильник сети при
    /// работающем конвейере опаснее лишнего вопроса.
    @Test func refusalsAreOrdered() {
        #expect(speechModelInstallRefusal(installed: true, running: true, dictating: true)
                == .alreadyRunning)
        #expect(speechModelInstallRefusal(installed: true, running: false, dictating: true)
                == .dictationBusy)
        #expect(speechModelInstallRefusal(installed: true, running: false, dictating: false)
                == .alreadyInstalled)
        #expect(speechModelInstallRefusal(installed: false, running: false, dictating: false) == nil)
    }

    /// Полоса хода не откатывается назад. Сборка модели идёт без числа, и
    /// показать на ней ноль значит сказать человеку, что всё началось заново.
    @Test func progressNeverGoesBackwards() {
        #expect(speechModelInstallFraction(.downloading(0.5)) == 0.5)
        #expect(speechModelInstallFraction(.compiling) > speechModelInstallFraction(.downloading(0.9)))
        #expect(speechModelInstallFraction(.finished) == 1)
        #expect(speechModelInstallFraction(.downloading(2)) == 1)
        #expect(speechModelInstallFraction(.downloading(-1)) == 0)
    }
}
