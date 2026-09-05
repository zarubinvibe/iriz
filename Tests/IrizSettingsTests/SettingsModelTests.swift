import CoreGraphics
import Foundation
import IrizCore
import IrizInput
import IrizPrompt
import Testing
@testable import IrizSettings
@testable import IrizDictate

@MainActor
@Suite("Settings model")
struct SettingsModelTests {
    /// Наследник теста про `MenuHotkeyLabels`: тот проверял шесть строк справки,
    /// которую меню больше не печатает. Проверяемое обещание то же — клавиши
    /// в меню взяты из настроек, а промпт-режим не показывается, пока выключен.
    @Test func menuKeyHintsUseConfiguredKeysAndPromptMode() {
        let fixture = Fixture()
        fixture.dictationSettings.hotkeyKeycode = 96
        fixture.dictationSettings.hotkeyModifiers = .maskCommand
        fixture.dictationSettings.promptHotkeyKeycode = 79
        fixture.dictationSettings.promptHotkeyModifiers = .maskControl
        fixture.layoutHotkeySettings.triggerKey = "control"
        fixture.layoutHotkeySettings.triggerRightOnly = true
        fixture.layoutHotkeySettings.triggerDoubleTap = true

        var hints = MenuKeys.hints(dictation: fixture.dictationSettings,
                                   layout: fixture.layoutHotkeySettings)
        #expect(hints.dictation == "⌘F5")
        #expect(hints.conversion == "правый ⌃ дважды")
        #expect(hints.prompt == nil)

        fixture.dictationSettings.promptModeEnabled = true
        hints = MenuKeys.hints(dictation: fixture.dictationSettings,
                               layout: fixture.layoutHotkeySettings)
        #expect(hints.prompt == "⌃F18")
    }

    /// Клавиша в меню обязана быть той, что сработает. В «Паузе» ручной триггер
    /// раскладки выходит по `guard autoSwitchEnabled` — подпись обещала бы впустую.
    @Test func menuHidesLayoutKeyWhenPaused() {
        let fixture = Fixture()
        fixture.layoutHotkeySettings.autoSwitchEnabled = true
        #expect(MenuKeys.hints(dictation: fixture.dictationSettings,
                               layout: fixture.layoutHotkeySettings).conversion == "⌥")

        fixture.layoutHotkeySettings.autoSwitchEnabled = false
        #expect(MenuKeys.hints(dictation: fixture.dictationSettings,
                               layout: fixture.layoutHotkeySettings).conversion == nil)
    }

    /// Одна нотация на всё меню: глифы, как их печатает macOS, и по-русски.
    /// До этого в шести строках было три нотации и английские слова.
    @Test func menuKeyNamesUseRussianGlyphs() {
        #expect(MenuKeys.russianKeyName(
            hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)) == "правый ⌘")
        #expect(MenuKeys.russianKeyName(
            hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE, modifiers: .maskControl))
            == "⌃ правый ⌘")
        #expect(MenuKeys.russianKeyName(
            hotkeyChoice(forKeycode: 49, modifiers: [.maskCommand, .maskShift])) == "⇧⌘␣")
        #expect(!MenuKeys.russianKeyName(
            hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE, modifiers: .maskAlternate))
            .contains("Command"))
    }

    @Test func recordedHotkeyPersists() {
        let fixture = Fixture()
        let model = fixture.makeModel()
        let recorded = recordableHotkeyChoice(forKeycode: 0, modifiers: [.maskCommand, .maskShift])!
        let prompt = recordableHotkeyChoice(forKeycode: 97, modifiers: .maskCommand)!
        let layout = recordableHotkeyChoice(forKeycode: CGKeyCode(KC.rightControl))!
        let switchHotkey = recordableHotkeyChoice(forKeycode: CGKeyCode(KC.rightControl),
                                                  modifiers: .maskShift)!

        model.setHotkey(recorded, for: .dictation)
        model.setHotkey(prompt, for: .prompt)
        model.setHotkey(layout, for: .layoutConversion)
        model.setHotkey(switchHotkey, for: .layoutSwitch)

        #expect(model.save())
        let reloaded = fixture.makeModel()
        #expect(reloaded.hotkeys[.dictation] == HotkeyBinding(choice: recorded))
        #expect(fixture.dictationSettings.configuredHotkey == recorded)
        #expect(reloaded.hotkeys[.prompt] == HotkeyBinding(choice: prompt))
        #expect(fixture.dictationSettings.configuredPromptHotkey == prompt)
        #expect(reloaded.hotkeys[.layoutConversion] == HotkeyBinding(choice: layout))
        #expect(fixture.layoutHotkeySettings.triggerKey == "control")
        #expect(fixture.layoutHotkeySettings.triggerRightOnly)
        #expect(reloaded.hotkeys[.layoutSwitch] == HotkeyBinding(choice: switchHotkey))
        #expect(fixture.layoutHotkeySettings.switchHotkey == "control+shift")
        #expect(!fixture.layoutHotkeySettings.switchRightOnly)
    }

    @Test func duplicateHotkeysBlockSave() {
        let fixture = Fixture()
        let model = fixture.makeModel()
        let duplicate = recordableHotkeyChoice(forKeycode: 96, modifiers: .maskControl)!
        model.setHotkey(duplicate, for: .dictation)
        model.setHotkey(duplicate, for: .history)

        #expect(model.validationMessage?.contains("Конфликт") == true)
        #expect(!model.save())
        #expect(fixture.dictationSettings.hotkeyKeycode == RIGHT_COMMAND_KEYCODE)
    }

    @Test func unsupportedLayoutHotkeyBlocksSave() {
        let fixture = Fixture()
        let model = fixture.makeModel()
        let unsupported = recordableHotkeyChoice(forKeycode: 96, modifiers: .maskControl)!

        model.setHotkey(unsupported, for: .layoutConversion)

        #expect(model.validationMessage?.contains("раскладка не понимает") == true)
        #expect(!model.save())
        #expect(fixture.layoutHotkeySettings.triggerKey == "option")
    }

    @Test func dictationAndLayoutHotkeyConflictBlocksSave() {
        let fixture = Fixture()
        let model = fixture.makeModel()
        let duplicate = recordableHotkeyChoice(forKeycode: CGKeyCode(KC.rightCommand))!

        model.setHotkey(duplicate, for: .dictation)
        model.setHotkey(duplicate, for: .layoutConversion)

        #expect(model.validationMessage?.contains("Конфликт") == true)
        #expect(!model.save())
        #expect(fixture.dictationSettings.hotkeyKeycode == RIGHT_COMMAND_KEYCODE)
        #expect(fixture.layoutHotkeySettings.triggerKey == "option")
    }

    @Test func promptHotkeyConflictBlocksSave() {
        let fixture = Fixture()
        let model = fixture.makeModel()
        let duplicate = recordableHotkeyChoice(forKeycode: 96, modifiers: .maskControl)!

        model.setHotkey(duplicate, for: .dictation)
        model.setHotkey(duplicate, for: .prompt)

        #expect(model.validationMessage?.contains("Конфликт") == true)
        #expect(model.validationMessage?.contains("Речь → промпт") == true)
        #expect(!model.save())
        #expect(fixture.dictationSettings.promptHotkeyKeycode == RIGHT_COMMAND_KEYCODE)
    }

    @Test func reservedPromptHotkeyBlocksSave() {
        let fixture = Fixture()
        let model = fixture.makeModel()
        let reserved = recordableHotkeyChoice(forKeycode: 49, modifiers: .maskCommand)!

        model.setHotkey(reserved, for: .prompt)

        #expect(model.validationMessage?.contains("занято macOS") == true)
        #expect(model.validationMessage?.contains("Речь → промпт") == true)
        #expect(!model.save())
    }

    @Test func promptModeRecipientAndCodexPathPersist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smltlk-settings-codex-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let fixture = Fixture()
        let model = fixture.makeModel()
        model.promptModeEnabled = true
        model.promptRecipient = .generic
        model.codexPath = "  \(executable.path)  "

        #expect(model.save())
        let reloaded = fixture.makeModel()
        #expect(reloaded.promptModeEnabled)
        #expect(reloaded.promptRecipient == .generic)
        #expect(reloaded.codexPath == executable.path)
        #expect(reloaded.detectedCodexPath == executable.path)
    }

    @Test func saveAppliesPromptSettingsToLiveController() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smltlk-live-prompt-settings-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let fixture = Fixture()
        let controller = DictationController(settings: fixture.dictationSettings)
        let model = fixture.makeModel()
        let promptHotkey = recordableHotkeyChoice(forKeycode: 97, modifiers: .maskCommand)!

        model.promptModeEnabled = true
        model.codexPath = executable.path
        model.setHotkey(promptHotkey, for: .prompt)
        #expect(model.save())

        #expect(controller.promptSettingsForTesting.enabled)
        #expect(controller.promptSettingsForTesting.hotkey == promptHotkey)
        #expect(controller.promptSettingsForTesting.codexPath == executable.path)

        model.promptModeEnabled = false
        #expect(model.save())
        #expect(!controller.promptSettingsForTesting.enabled)
    }

    @Test func promptModeWithNonExecutableCodexBlocksSave() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("smltlk-non-executable-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not executable".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        let fixture = Fixture()
        let model = fixture.makeModel(codexDetector: { path in
            FileManager.default.isExecutableFile(atPath: path)
                ? URL(fileURLWithPath: path)
                : nil
        })
        model.promptModeEnabled = true
        model.codexPath = file.path

        #expect(model.validationMessage?.contains("не запускается") == true)
        #expect(!model.save())
        #expect(!fixture.dictationSettings.promptModeEnabled)
        #expect(fixture.dictationSettings.codexExecutablePath.isEmpty)
    }

    @Test func correctionsSurviveAddEditAndDelete() {
        let fixture = Fixture()
        var model = fixture.makeModel()
        // Хранилище НЕ пусто: заводской словарь подсаживается при первом создании
        // настроек (DictationSettings.seedDefaultTranscriptCorrectionsOnce), иначе
        // владельцу пришлось бы набирать 27 записей руками. Поэтому проверяем
        // относительные изменения, а не абсолютную пустоту.
        let seeded = model.corrections.count
        #expect(seeded > 0, "заводской словарь не подсел — проверь посев в DictationSettings")

        model.addCorrection(source: "паракит", replacement: "Parakeet")
        #expect(model.save())

        model = fixture.makeModel()
        #expect(model.corrections.count == seeded + 1)
        let added = try! #require(model.corrections.firstIndex(
            of: TranscriptCorrection(source: "паракит", replacement: "Parakeet")))
        model.updateCorrection(at: added, replacement: "Parakeet TDT")
        #expect(model.save())

        model = fixture.makeModel()
        #expect(model.corrections[added].replacement == "Parakeet TDT")
        model.removeCorrection(at: added)
        #expect(model.save())

        let afterDelete = fixture.makeModel().corrections
        #expect(afterDelete.count == seeded)
        #expect(!afterDelete.contains { $0.source == "паракит" })
    }

    /// Выбранная палитра обязана дойти до плашки, а не остаться в окне
    /// настроек: настройка, которую никто не читает, ХУЖЕ отсутствующей —
    /// она обещает и не делает.
    @Test func палитраВолныСохраняетсяИВозвращаетсяКЗаводскойПриСбросе() {
        let fixture = Fixture()
        let model = fixture.makeModel()
        #expect(model.wavePalette == DICTATION_HUD_DEFAULT_WAVE_PALETTE)

        model.wavePalette = .mono
        #expect(model.save())
        #expect(fixture.dictationSettings.dictationHUDWavePalette == .mono)
        #expect(fixture.makeModel().wavePalette == .mono)

        #expect(model.resetToFactoryDefaults())
        #expect(model.wavePalette == DICTATION_HUD_DEFAULT_WAVE_PALETTE)
        #expect(fixture.dictationSettings.dictationHUDWavePalette
                == DICTATION_HUD_DEFAULT_WAVE_PALETTE)
    }

    /// Выключатель окна спасения обязан доходить до рантайма диктовки: галка,
    /// которую никто не читает, обещает и не делает. Заводское состояние —
    /// включено, потому что молчаливый провал доставки стоит владельцу целой
    /// надиктовки.
    @Test func окноСпасенияСохраняетсяИВозвращаетсяКЗаводскомуПриСбросе() {
        let fixture = Fixture()
        let model = fixture.makeModel()
        #expect(model.rescueWindowEnabled)

        model.rescueWindowEnabled = false
        #expect(model.save())
        #expect(!fixture.dictationSettings.rescueWindowEnabled)
        #expect(!fixture.makeModel().rescueWindowEnabled)

        #expect(model.resetToFactoryDefaults())
        #expect(model.rescueWindowEnabled)
        #expect(fixture.dictationSettings.rescueWindowEnabled)
    }

    @Test func resetRestoresFactoryDefaults() {
        let fixture = Fixture(mode: .paused, launchAtLogin: false)
        let model = fixture.makeModel()
        model.setHotkey(recordableHotkeyChoice(forKeycode: 1, modifiers: .maskCommand)!, for: .dictation)
        model.enterDelayText = "499"
        model.pasteSuffix = .appendNewline
        model.addCorrection(source: "a", replacement: "b")
        model.promptModeEnabled = true
        model.promptRecipient = .generic
        model.codexPath = "/custom/codex"
        model.setHotkey(recordableHotkeyChoice(forKeycode: 97, modifiers: .maskCommand)!, for: .prompt)
        fixture.dictationSettings.promptOnboardingOffered = true

        #expect(model.resetToFactoryDefaults())
        #expect(model.hotkeys[.dictation] == HotkeyBinding(keycode: RIGHT_COMMAND_KEYCODE))
        #expect(model.enterDelayText == "120")
        #expect(model.pasteSuffix == .appendSpace)
        #expect(model.layoutMode == .fixing)
        #expect(model.launchAtLogin)
        #expect(model.corrections.isEmpty)
        #expect(!model.promptModeEnabled)
        #expect(model.promptRecipient == .codex)
        #expect(model.codexPath.isEmpty)
        #expect(model.hotkeys[.prompt]
                == HotkeyBinding(keycode: RIGHT_COMMAND_KEYCODE, modifiers: .maskControl))
        #expect(!fixture.dictationSettings.promptModeEnabled)
        #expect(fixture.dictationSettings.promptRecipient == .codex)
        #expect(fixture.dictationSettings.codexExecutablePath.isEmpty)
        #expect(!fixture.dictationSettings.promptOnboardingOffered)
        #expect(fixture.mode == .fixing)
        #expect(fixture.launchAtLogin)
    }

    /// Выбор агента переживает перезапуск, а путь хранится отдельно на каждого:
    /// переключение не должно подсунуть новому агенту чужой исполняемый файл.
    @Test func promptAgentChoiceAndPerAgentPathsPersist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smltlk-agent-paths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex")
        let ollama = root.appendingPathComponent("ollama")
        for executable in [codex, ollama] {
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }

        let fixture = Fixture()
        let model = fixture.makeModel()
        model.promptModeEnabled = true
        model.codexPath = codex.path
        model.promptAgentID = PromptAgentCatalog.ollamaID
        model.agentPath = "  \(ollama.path)  "
        model.agentModel = " qwen2.5-coder:7b "
        #expect(model.save())

        let reloaded = fixture.makeModel()
        #expect(reloaded.promptAgentID == PromptAgentCatalog.ollamaID)
        #expect(reloaded.agentPath == ollama.path)
        #expect(reloaded.agentModel == "qwen2.5-coder:7b")
        #expect(reloaded.codexPath == codex.path)

        // Возврат к Codex возвращает путь Codex, а не путь Ollama.
        reloaded.promptAgentID = PromptAgentCatalog.codexID
        #expect(reloaded.agentPath == codex.path)
    }

    /// Цена выбора стоит рядом с выбором и меняется вместе с ним.
    @Test func destinationLineFollowsAgentChoice() {
        let model = Fixture().makeModel()

        model.promptAgentID = PromptAgentCatalog.ollamaID
        #expect(model.agentKeepsDataLocal)
        #expect(model.agentDestinationTitle.contains("на этом Маке"))

        model.promptAgentID = PromptAgentCatalog.codexID
        #expect(!model.agentKeepsDataLocal)
        #expect(model.agentDestinationTitle.contains("OpenAI"))

        model.promptAgentID = PromptAgentCatalog.claudeID
        #expect(model.agentDestinationTitle.contains("Anthropic"))

        model.promptAgentID = PromptAgentCatalog.kimiID
        #expect(model.agentDestinationTitle.contains("Moonshot"))
    }

    /// `ollama run` без модели запускать нечего: сохранение должно объяснить это,
    /// а не молча записать заведомо нерабочую настройку.
    @Test func localAgentWithoutModelBlocksSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smltlk-agent-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ollama")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let fixture = Fixture()
        let model = fixture.makeModel()
        model.promptModeEnabled = true
        model.promptAgentID = PromptAgentCatalog.ollamaID
        model.agentPath = executable.path

        #expect(model.validationMessage?.contains("модель") == true)
        #expect(!model.save())

        model.agentModel = "qwen2.5-coder:7b"
        #expect(model.validationMessage == nil)
        #expect(model.save())
    }

    /// Аргументы своего CLI хранятся построчно: командная строка не собирается
    /// из строки, поэтому кавычек и shell-я в этой настройке нет.
    @Test func customAgentArgumentsSurviveSaveLineByLine() {
        let fixture = Fixture()
        let model = fixture.makeModel()
        model.promptAgentID = PromptAgentCatalog.customID
        model.agentCustomArguments = "--flag\n  \n{prompt}\n"

        #expect(model.save())
        #expect(model.customArgumentsList == ["--flag", "{prompt}"])
        #expect(fixture.dictationSettings.promptAgentCustomArguments == ["--flag", "{prompt}"])
        #expect(model.agentAdapter.promptDelivery == .argument)
    }

    @Test func repeatedSaveUsesLastPersistedLoginSetting() {
        let fixture = Fixture(launchAtLogin: true)
        let model = fixture.makeModel()

        model.launchAtLogin = false
        #expect(model.save())
        #expect(!fixture.launchAtLogin)

        model.launchAtLogin = true
        #expect(model.save())
        #expect(fixture.launchAtLogin)
    }
}

@MainActor
private final class Fixture {
    let defaults: UserDefaults
    let dictationSettings: DictationSettings
    let layoutHotkeySettings: SettingsManager
    var mode: LayoutMode
    var launchAtLogin: Bool

    init(mode: LayoutMode = .fixing, launchAtLogin: Bool = true) {
        let suiteName = "ru.smltlk.settings.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        dictationSettings = DictationSettings(defaults: defaults)
        layoutHotkeySettings = SettingsManager(defaults: defaults)
        self.mode = mode
        self.launchAtLogin = launchAtLogin
    }

    func makeModel(
        codexDetector: @escaping (String) -> URL? = {
            DictationSettings.detectCodexExecutable(storedPath: $0)
        }
    ) -> SettingsModel {
        SettingsModel(
            dictationSettings: dictationSettings,
            layoutSettings: LayoutSettingsAccess(
                readMode: { self.mode },
                writeMode: { self.mode = $0 },
                readLaunchAtLogin: { self.launchAtLogin },
                writeLaunchAtLogin: { self.launchAtLogin = $0 }
            ),
            layoutHotkeys: .settings(layoutHotkeySettings),
            codexDetector: codexDetector
        )
    }
}
