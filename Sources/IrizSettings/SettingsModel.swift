import Combine
import CoreGraphics
import Foundation
import IrizCore
import IrizDictate
import IrizInput
import IrizPrompt

enum HotkeyAction: String, CaseIterable, Identifiable {
    case dictation
    case dictationAndEnter
    case prompt
    case history
    case layoutConversion
    case layoutSwitch

    var id: Self { self }

    var title: String {
        switch self {
        case .dictation: L("hotkey.dictation", L("hotkey.dictation", "Диктовка"))
        case .dictationAndEnter: L("hotkey.dictationEnter", "Диктовка с переводом строки")
        case .prompt: L("hotkey.prompt", L("hotkey.prompt", "Речь → промпт"))
        case .history: L("hotkey.history", L("hotkey.history", "История"))
        case .layoutConversion: L("hotkey.layoutConversion", L("hotkey.layoutConversion", "Конвертация раскладки"))
        case .layoutSwitch: L("hotkey.layoutSwitch", L("hotkey.layoutSwitch", "Переключение раскладки"))
        }
    }
}

struct HotkeyBinding: Equatable {
    let keycode: CGKeyCode
    let modifiers: CGEventFlags

    init(choice: HotkeyChoice) {
        keycode = choice.keycode
        modifiers = choice.requiredModifiers
    }

    init(keycode: CGKeyCode, modifiers: CGEventFlags = []) {
        self.keycode = keycode
        self.modifiers = modifiers.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
    }

    var choice: HotkeyChoice {
        hotkeyChoice(forKeycode: keycode, modifiers: modifiers)
    }

    var name: String { choice.name }
}

struct LayoutHotkeyConfig: Equatable {
    let key: String
    let rightOnly: Bool
    let doubleTap: Bool
}

@MainActor
struct LayoutHotkeySettingsAccess {
    let readTrigger: () -> LayoutHotkeyConfig
    let writeTrigger: (LayoutHotkeyConfig) -> Void
    let readSwitch: () -> LayoutHotkeyConfig
    let writeSwitch: (LayoutHotkeyConfig) -> Void

    static let live = settings(SettingsManager.shared)

    static func settings(_ settings: SettingsManager) -> LayoutHotkeySettingsAccess {
        LayoutHotkeySettingsAccess(
            readTrigger: {
                LayoutHotkeyConfig(
                    key: settings.triggerKey,
                    rightOnly: settings.triggerRightOnly,
                    doubleTap: settings.triggerDoubleTap
                )
            },
            writeTrigger: { config in
                settings.triggerKey = config.key
                settings.triggerRightOnly = config.rightOnly
                settings.triggerDoubleTap = config.doubleTap
            },
            readSwitch: {
                LayoutHotkeyConfig(
                    key: settings.switchHotkey,
                    rightOnly: settings.switchRightOnly,
                    doubleTap: settings.switchDoubleTap
                )
            },
            writeSwitch: { config in
                settings.switchHotkey = config.key
                settings.switchRightOnly = config.rightOnly
                settings.switchDoubleTap = config.doubleTap
            }
        )
    }
}

enum LayoutMode: String, CaseIterable, Identifiable {
    case fixing
    case counting
    case paused

    var id: Self { self }

    var title: String {
        switch self {
        case .fixing: "Исправляет"
        case .counting: "Только считает"
        case .paused: "Пауза"
        }
    }

    var explanation: String {
        switch self {
        case .fixing: "Находит неверную раскладку и исправляет текст."
        case .counting: "Считает возможные исправления, но текст не меняет."
        case .paused: "Не следит за раскладкой и ничего не меняет."
        }
    }
}

@MainActor
struct LayoutSettingsAccess {
    let readMode: () -> LayoutMode
    let writeMode: (LayoutMode) -> Void
    let readLaunchAtLogin: () -> Bool
    let writeLaunchAtLogin: (Bool) -> Void

    static let live = LayoutSettingsAccess(
        readMode: {
            let settings = SettingsManager.shared
            if !settings.autoSwitchEnabled { return .paused }
            return settings.shadowMode ? .counting : .fixing
        },
        writeMode: { mode in
            let settings = SettingsManager.shared
            switch mode {
            case .fixing:
                settings.autoSwitchEnabled = true
                settings.shadowMode = false
                settings.autoConvert = true
            case .counting:
                settings.autoSwitchEnabled = true
                settings.shadowMode = true
                settings.autoConvert = true
            case .paused:
                settings.autoSwitchEnabled = false
                settings.shadowMode = false
                settings.autoConvert = false
            }
        },
        readLaunchAtLogin: { SettingsManager.shared.launchAtLogin },
        writeLaunchAtLogin: { SettingsManager.shared.launchAtLogin = $0 }
    )

    static func preview(defaults: UserDefaults) -> LayoutSettingsAccess {
        let modeKey = "ru.smltlk.settings.preview.layoutMode"
        let launchKey = "ru.smltlk.settings.preview.launchAtLogin"
        return LayoutSettingsAccess(
            readMode: {
                defaults.string(forKey: modeKey).flatMap(LayoutMode.init(rawValue:)) ?? .fixing
            },
            writeMode: { defaults.set($0.rawValue, forKey: modeKey) },
            readLaunchAtLogin: {
                defaults.object(forKey: launchKey) as? Bool ?? true
            },
            writeLaunchAtLogin: { defaults.set($0, forKey: launchKey) }
        )
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var hotkeys: [HotkeyAction: HotkeyBinding]
    @Published var layoutMode: LayoutMode
    @Published var enterDelayText: String
    @Published var pasteSuffix: PasteSuffix
    @Published var speechCleanupMode: SpeechCleanupMode
    @Published var launchAtLogin: Bool
    @Published var corrections: [TranscriptCorrection]
    /// Заготовки живут отдельным списком от словаря: другой редактор, другой
    /// размер записи, другая цена ошибки.
    @Published var snippets: [DictationSnippet]
    /// Свои инструкции промпт-режима. Обычная диктовка их не видит.
    /// Размер плашки записи.
    /// Через сколько дней уборка стирает надиктовку. 0 - не стирать никогда.
    @Published var retentionDays: Int
    @Published var hudSize: DictationHUDSizeChoice
    @Published var promptGuidanceInstructions: String
    /// Примеры «как сказал - какой промпт хочу».
    @Published var promptGuidanceExamples: [PromptUserExample]
    @Published var promptModeEnabled: Bool
    /// Какой распознаватель стоит. Выбор с ценой на обеих сторонах, поэтому он
    /// у владельца, а не зашит: Whisper берет английские термины внутри русской
    /// фразы, Parakeet быстрее в 11-15 раз. Разбор - `bench/BENCH-CANDIDATES-2026-09-03.md`.
    @Published var speechEngine: SpeechModelProfile
    @Published var promptRecipient: PromptRecipientSetting
    /// Явные записи «приложение → профиль». Всё, чего в списке нет, получает
    /// `promptRecipient`, поэтому отдельного «дефолтного» ряда тут не бывает.
    @Published var appProfiles: [PromptAppProfileEntry]
    @Published var promptAgentID: String
    /// Путь отдельно на каждого агента: переключение не должно подсовывать
    /// новому агенту исполняемый файл предыдущего.
    @Published var agentPaths: [String: String]
    @Published var agentModel: String
    @Published var agentCustomArguments: String
    @Published var wavePalette: DictationHUDWavePalette
    @Published var rescueWindowEnabled: Bool

    private let dictationSettings: DictationSettings
    private let layoutSettings: LayoutSettingsAccess
    private let layoutHotkeys: LayoutHotkeySettingsAccess
    private let agentDetector: (String, PromptAgentAdapter) -> URL?
    private var savedLaunchAtLogin: Bool

    convenience init(preview: Bool = false) {
        if preview {
            let defaults = UserDefaults(suiteName: "ru.smltlk.settings.preview")!
            self.init(
                dictationSettings: DictationSettings(defaults: defaults),
                layoutSettings: .preview(defaults: defaults),
                layoutHotkeys: .settings(SettingsManager(defaults: defaults))
            )
        } else {
            self.init(
                dictationSettings: .shared,
                layoutSettings: .live,
                layoutHotkeys: .live
            )
        }
    }

    /// `codexDetector` остался прежней формы ради вызывающего кода и тестов:
    /// закрытие получает путь и не знает про агента. Если его не передали,
    /// поиск идёт по адаптеру выбранного агента.
    init(
        dictationSettings: DictationSettings,
        layoutSettings: LayoutSettingsAccess,
        layoutHotkeys: LayoutHotkeySettingsAccess,
        codexDetector: ((String) -> URL?)? = nil
    ) {
        self.dictationSettings = dictationSettings
        self.layoutSettings = layoutSettings
        self.layoutHotkeys = layoutHotkeys
        agentDetector = codexDetector.map { detector in
            { path, _ in detector(path) }
        } ?? { path, adapter in
            DictationSettings.detectAgentExecutable(adapter: adapter, storedPath: path)
        }

        let launchAtLogin = layoutSettings.readLaunchAtLogin()
        savedLaunchAtLogin = launchAtLogin
        self.launchAtLogin = launchAtLogin
        layoutMode = layoutSettings.readMode()
        enterDelayText = String(dictationSettings.enterDelayMilliseconds)
        pasteSuffix = dictationSettings.pasteSuffix
        speechCleanupMode = dictationSettings.speechCleanupMode
        corrections = dictationSettings.transcriptCorrections
        snippets = dictationSettings.snippets
        retentionDays = dictationSettings.dictationRetentionDays
        hudSize = dictationSettings.dictationHUDSize
        let guidance = dictationSettings.promptUserGuidance
        promptGuidanceInstructions = guidance.instructions
        promptGuidanceExamples = guidance.examples
        promptModeEnabled = dictationSettings.promptModeEnabled
        speechEngine = dictationSettings.speechEngine
        promptRecipient = dictationSettings.promptRecipient
        appProfiles = dictationSettings.promptAppProfiles
        promptAgentID = dictationSettings.promptAgentID
        agentPaths = Dictionary(
            uniqueKeysWithValues: PromptAgentCatalog.identifiers.map {
                ($0, dictationSettings.promptAgentPath(for: $0))
            }
        )
        agentModel = dictationSettings.promptAgentModel
        agentCustomArguments = dictationSettings.promptAgentCustomArguments.joined(separator: "\n")
        wavePalette = dictationSettings.dictationHUDWavePalette
        rescueWindowEnabled = dictationSettings.rescueWindowEnabled
        hotkeys = Self.loadHotkeys(dictationSettings: dictationSettings, layoutHotkeys: layoutHotkeys)
    }

    /// Адаптер выбранного агента: свой CLI собирается из введённых аргументов.
    var agentAdapter: PromptAgentAdapter {
        PromptAgentCatalog.adapter(
            id: promptAgentID,
            customArguments: customArgumentsList
        ) ?? PromptAgentCatalog.codex
    }

    var customArgumentsList: [String] {
        agentCustomArguments
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Путь выбранного агента. Правится в настройках, пустой включает автопоиск.
    var agentPath: String {
        get { agentPaths[promptAgentID] ?? "" }
        set { agentPaths[promptAgentID] = newValue }
    }

    var detectedAgentPath: String? {
        agentDetector(agentPath, agentAdapter)?.path
    }

    /// Цена выбора рядом с выбором: строка меняется вместе с агентом.
    var agentDestinationTitle: String { agentAdapter.destination.title }

    var agentKeepsDataLocal: Bool { agentAdapter.destination.isLocal }

    var codexPath: String {
        get { agentPaths[PromptAgentCatalog.codexID] ?? "" }
        set { agentPaths[PromptAgentCatalog.codexID] = newValue }
    }

    var detectedCodexPath: String? {
        agentDetector(codexPath, PromptAgentCatalog.codex)?.path
    }

    var validationMessage: String? {
        if let unsupported = unsupportedLayoutHotkey { return unsupported }
        if let conflict = duplicateConflict { return conflict }
        if let reserved = systemReservedConflict { return reserved }

        let adapter = agentAdapter
        if promptModeEnabled, detectedAgentPath == nil {
            return agentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(adapter.displayName) не найден. Укажите путь к исполняемому файлу."
                : "\(adapter.displayName) по этому пути не запускается и автоматически не найден."
        }

        if promptModeEnabled, adapter.requiresModel,
           agentModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Укажите модель: \(adapter.displayName) без неё запускать нечего."
        }

        guard let delay = Int(enterDelayText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...500).contains(delay) else {
            return "Задержка Enter — целое число от 0 до 500."
        }

        if corrections.contains(where: {
            $0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return "В словаре обе части замены должны быть заполнены."
        }

        if snippets.contains(where: {
            $0.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return "У заготовки нужны и фраза, и текст."
        }

        if let bad = snippets.first(where: {
            let trigger = $0.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trigger.isEmpty && !trigger.contains(where: { $0.isLetter || $0.isNumber })
        }) {
            return "Фраза «\(bad.trigger)» не содержит ни буквы, ни цифры — её нечем поймать в речи."
        }
        return nil
    }

    var canSave: Bool { validationMessage == nil }

    func setHotkey(_ choice: HotkeyChoice, for action: HotkeyAction) {
        hotkeys[action] = HotkeyBinding(choice: choice)
    }

    /// Новая замена встаёт СВЕРХУ.
    ///
    /// Слова владельца 06.09.2026: «логичнее, чтобы сверху, потому что чтобы
    /// перечитать весь словарь замен, можно потратить время. А если я хочу
    /// добавить новую, мне придётся полностью всю эту портянку прокрутить
    /// донизу и только потом ставить».
    ///
    /// Порядок в словаре на подстановку не влияет: совпадение точное и по
    /// границам слова, а не «первое подошедшее». Значит верх свободен и его
    /// занимает то, ради чего список открыли.
    func addCorrection(source: String = "", replacement: String = "") {
        corrections.insert(TranscriptCorrection(source: source, replacement: replacement), at: 0)
    }

    func updateCorrection(at index: Int, source: String? = nil, replacement: String? = nil) {
        guard corrections.indices.contains(index) else { return }
        let current = corrections[index]
        corrections[index] = TranscriptCorrection(
            source: source ?? current.source,
            replacement: replacement ?? current.replacement
        )
    }

    func removeCorrection(at index: Int) {
        guard corrections.indices.contains(index) else { return }
        corrections.remove(at: index)
    }

    // MARK: - Заготовки

    /// Новая заготовка тоже встаёт сверху - по той же причине и тем же
    /// правилом, что и замена: список читают редко, дописывают часто.
    func addSnippet(trigger: String = "", body: String = "") {
        snippets.insert(DictationSnippet(trigger: trigger, body: body), at: 0)
    }

    func updateSnippet(at index: Int, trigger: String? = nil, body: String? = nil) {
        guard snippets.indices.contains(index) else { return }
        let current = snippets[index]
        snippets[index] = DictationSnippet(
            trigger: trigger ?? current.trigger,
            body: body ?? current.body
        )
    }

    func addPromptExample() {
        guard promptGuidanceExamples.count < PROMPT_GUIDANCE_EXAMPLES_MAX else { return }
        promptGuidanceExamples.append(PromptUserExample(spoken: "", wanted: ""))
    }

    func removePromptExample(at index: Int) {
        guard promptGuidanceExamples.indices.contains(index) else { return }
        promptGuidanceExamples.remove(at: index)
    }

    func updatePromptExample(at index: Int, spoken: String? = nil, wanted: String? = nil) {
        guard promptGuidanceExamples.indices.contains(index) else { return }
        let current = promptGuidanceExamples[index]
        promptGuidanceExamples[index] = PromptUserExample(
            spoken: spoken ?? current.spoken,
            wanted: wanted ?? current.wanted
        )
    }

    func removeSnippet(at index: Int) {
        guard snippets.indices.contains(index) else { return }
        snippets.remove(at: index)
    }

    // MARK: - Профиль по приложению

    /// Чем кончилась попытка добавить приложение. Кнопка обязана сказать
    /// правду: молчаливое «ничего не произошло» владелец прочитает как поломку.
    enum AppProfileAddOutcome: Equatable {
        case added
        /// Приложение уже было в списке — профиль переписан на месте, а не
        /// заведён второй строкой. Две строки про одно приложение спорили бы
        /// между собой, и владелец не видел бы, какая победила.
        case updated
        case invalidBundleID
        case listFull
    }

    @discardableResult
    func addAppProfile(bundleID: String, profile: PromptRecipientProfile) -> AppProfileAddOutcome {
        guard let cleaned = validatedPromptAppProfileBundleID(bundleID) else { return .invalidBundleID }
        let key = cleaned.lowercased()
        let entry = PromptAppProfileEntry(bundleID: cleaned, profile: profile)
        if let index = appProfiles.firstIndex(where: { $0.bundleID.lowercased() == key }) {
            appProfiles[index] = entry
            return .updated
        }
        guard appProfiles.count < PromptAppProfileMap.maximumEntries else { return .listFull }
        appProfiles.append(entry)
        return .added
    }

    func updateAppProfile(at index: Int, profile: PromptRecipientProfile) {
        guard appProfiles.indices.contains(index) else { return }
        appProfiles[index] = PromptAppProfileEntry(
            bundleID: appProfiles[index].bundleID,
            profile: profile
        )
    }

    func removeAppProfile(at index: Int) {
        guard appProfiles.indices.contains(index) else { return }
        appProfiles.remove(at: index)
    }

    // MARK: - Словарь и заготовки файлом

    /// Выгружается то, что владелец видит в редакторе прямо сейчас, а не то,
    /// что лежит на диске: иначе кнопка «Экспортировать» врала бы про только
    /// что набранную запись.
    func exportedDictionaryData() -> Data {
        DictionaryTransfer.encode(corrections: corrections, snippets: snippets)
    }

    /// Импорт правит ТОЛЬКО состояние окна. На диск он ложится общей кнопкой
    /// «Сохранить» — тем же путём, что и ручная правка, поэтому импорт можно
    /// отменить, закрыв окно, и он не переживает невалидную форму.
    func importDictionaryData(_ data: Data) throws -> String {
        let document = try DictionaryTransfer.decode(data)
        let outcome = try DictionaryTransfer.merge(document,
                                                   intoCorrections: corrections,
                                                   snippets: snippets)
        corrections = outcome.corrections
        snippets = outcome.snippets
        return outcome.summary
    }

    @discardableResult
    func save() -> Bool {
        guard validationMessage == nil,
              let delay = Int(enterDelayText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }

        saveDictationHotkey(.dictation, keycode: \DictationSettings.hotkeyKeycode,
                           modifiers: \DictationSettings.hotkeyModifiers)
        saveDictationHotkey(.dictationAndEnter, keycode: \DictationSettings.enterHotkeyKeycode,
                           modifiers: \DictationSettings.enterHotkeyModifiers)
        saveDictationHotkey(.prompt, keycode: \DictationSettings.promptHotkeyKeycode,
                           modifiers: \DictationSettings.promptHotkeyModifiers)
        saveDictationHotkey(.history, keycode: \DictationSettings.historyHotkeyKeycode,
                           modifiers: \DictationSettings.historyHotkeyModifiers)

        guard let triggerConfig = layoutConfig(for: .layoutConversion) else { return false }
        layoutHotkeys.writeTrigger(triggerConfig)
        if let switchConfig = layoutConfig(for: .layoutSwitch) {
            layoutHotkeys.writeSwitch(switchConfig)
        } else {
            layoutHotkeys.writeSwitch(LayoutHotkeyConfig(key: "", rightOnly: false, doubleTap: false))
        }

        dictationSettings.enterDelayMilliseconds = delay
        dictationSettings.pasteSuffix = pasteSuffix
        dictationSettings.speechCleanupMode = speechCleanupMode
        dictationSettings.transcriptCorrections = corrections
        dictationSettings.snippets = snippets
        dictationSettings.dictationRetentionDays = retentionDays
        dictationSettings.dictationHUDSize = hudSize
        dictationSettings.promptUserGuidance = PromptUserGuidance(
            instructions: promptGuidanceInstructions,
            examples: promptGuidanceExamples
        )
        dictationSettings.promptModeEnabled = promptModeEnabled
        dictationSettings.speechEngine = speechEngine
        dictationSettings.promptRecipient = promptRecipient
        dictationSettings.promptAppProfiles = appProfiles
        dictationSettings.dictationHUDWavePalette = wavePalette
        dictationSettings.rescueWindowEnabled = rescueWindowEnabled
        dictationSettings.promptAgentID = promptAgentID
        agentPaths = agentPaths.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for (id, path) in agentPaths {
            dictationSettings.setPromptAgentPath(path, for: id)
        }
        agentModel = agentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        dictationSettings.promptAgentModel = agentModel
        dictationSettings.promptAgentCustomArguments = customArgumentsList
        agentCustomArguments = customArgumentsList.joined(separator: "\n")
        corrections = dictationSettings.transcriptCorrections
        snippets = dictationSettings.snippets
        retentionDays = dictationSettings.dictationRetentionDays
        hudSize = dictationSettings.dictationHUDSize
        let guidance = dictationSettings.promptUserGuidance
        promptGuidanceInstructions = guidance.instructions
        promptGuidanceExamples = guidance.examples
        appProfiles = dictationSettings.promptAppProfiles
        layoutSettings.writeMode(layoutMode)
        if launchAtLogin != savedLaunchAtLogin {
            layoutSettings.writeLaunchAtLogin(launchAtLogin)
            savedLaunchAtLogin = launchAtLogin
        }
        NotificationCenter.default.post(name: DictationController.settingsDidSaveNotification,
                                        object: dictationSettings)
        return true
    }

    @discardableResult
    func resetToFactoryDefaults() -> Bool {
        hotkeys = Self.factoryHotkeys()
        layoutMode = .fixing
        enterDelayText = "120"
        pasteSuffix = .appendSpace
        speechCleanupMode = .local
        launchAtLogin = true
        corrections = []
        snippets = []
        promptModeEnabled = false
        speechEngine = .whisperTurbo
        promptRecipient = .codex
        appProfiles = []
        promptAgentID = PromptAgentCatalog.defaultID
        agentPaths = Dictionary(
            uniqueKeysWithValues: PromptAgentCatalog.identifiers.map { ($0, "") }
        )
        agentModel = ""
        agentCustomArguments = ""
        wavePalette = DICTATION_HUD_DEFAULT_WAVE_PALETTE
        rescueWindowEnabled = true
        dictationSettings.promptOnboardingOffered = false
        return save()
    }

    private var duplicateConflict: String? {
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let binding = hotkeys[action] else { continue }
            let duplicates = HotkeyAction.allCases[(index + 1)...].filter { hotkeys[$0] == binding }
            if let other = duplicates.first {
                return "Конфликт: «\(action.title)» и «\(other.title)»."
            }
        }
        return nil
    }

    private var unsupportedLayoutHotkey: String? {
        for action in [HotkeyAction.layoutConversion, .layoutSwitch] {
            guard hotkeys[action] != nil, layoutConfig(for: action) == nil else { continue }
            return "«\(action.title)»: такое сочетание раскладка не понимает."
        }
        return nil
    }

    private var systemReservedConflict: String? {
        let reserved = [
            HotkeyBinding(keycode: 49, modifiers: .maskCommand), // Spotlight
            HotkeyBinding(keycode: 48, modifiers: .maskCommand), // app switcher
        ]
        guard let action = HotkeyAction.allCases.first(where: { action in
            hotkeys[action].map(reserved.contains) == true
        }) else { return nil }
        return "«\(action.title)»: это сочетание занято macOS."
    }

    private func saveDictationHotkey(
        _ action: HotkeyAction,
        keycode: ReferenceWritableKeyPath<DictationSettings, CGKeyCode>,
        modifiers: ReferenceWritableKeyPath<DictationSettings, CGEventFlags>
    ) {
        guard let binding = hotkeys[action] else { return }
        dictationSettings[keyPath: keycode] = binding.keycode
        dictationSettings[keyPath: modifiers] = binding.modifiers
    }

    private static func loadHotkeys(
        dictationSettings: DictationSettings,
        layoutHotkeys: LayoutHotkeySettingsAccess
    ) -> [HotkeyAction: HotkeyBinding] {
        var result: [HotkeyAction: HotkeyBinding] = [
            .dictation: HotkeyBinding(choice: dictationSettings.configuredHotkey),
            .dictationAndEnter: HotkeyBinding(choice: dictationSettings.configuredEnterHotkey),
            .prompt: HotkeyBinding(choice: dictationSettings.configuredPromptHotkey),
            .history: HotkeyBinding(choice: dictationSettings.configuredHistoryHotkey),
            .layoutConversion: layoutBinding(from: layoutHotkeys.readTrigger(), switchSlot: false)
                ?? factoryHotkey(for: .layoutConversion)!,
        ]
        if let switchBinding = layoutBinding(from: layoutHotkeys.readSwitch(), switchSlot: true) {
            result[.layoutSwitch] = switchBinding
        }
        return result
    }

    private static func factoryHotkeys() -> [HotkeyAction: HotkeyBinding] {
        Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.compactMap { action in
            factoryHotkey(for: action).map { (action, $0) }
        })
    }

    private static func factoryHotkey(for action: HotkeyAction) -> HotkeyBinding? {
        switch action {
        case .dictation: HotkeyBinding(keycode: RIGHT_COMMAND_KEYCODE)
        case .dictationAndEnter: HotkeyBinding(keycode: RIGHT_COMMAND_KEYCODE, modifiers: .maskAlternate)
        case .prompt: HotkeyBinding(keycode: RIGHT_COMMAND_KEYCODE, modifiers: .maskControl)
        case .history: HotkeyBinding(keycode: RIGHT_COMMAND_KEYCODE, modifiers: .maskShift)
        case .layoutConversion: HotkeyBinding(keycode: CGKeyCode(KC.leftOption))
        case .layoutSwitch: nil
        }
    }

    private func layoutConfig(for action: HotkeyAction) -> LayoutHotkeyConfig? {
        guard let binding = hotkeys[action] else { return nil }
        let existing = action == .layoutConversion ? layoutHotkeys.readTrigger() : layoutHotkeys.readSwitch()
        return Self.layoutConfig(from: binding, existing: existing, switchSlot: action == .layoutSwitch)
    }

    private static func layoutConfig(
        from binding: HotkeyBinding,
        existing: LayoutHotkeyConfig,
        switchSlot: Bool
    ) -> LayoutHotkeyConfig? {
        if binding.keycode == CGKeyCode(KC.capsLock), binding.modifiers.isEmpty, !switchSlot {
            return LayoutHotkeyConfig(key: "capsLock", rightOnly: false, doubleTap: existing.doubleTap)
        }

        guard binding.choice.isModifier,
              let primaryFlag = binding.choice.modifierFlag,
              !primaryFlag.contains(.maskSecondaryFn),
              !binding.modifiers.contains(.maskSecondaryFn) else {
            return nil
        }

        if binding.modifiers.isEmpty,
           let key = singleModifierKey(primaryFlag) {
            return LayoutHotkeyConfig(
                key: key,
                rightOnly: isRightModifier(binding.keycode),
                doubleTap: existing.doubleTap
            )
        }

        let flags = binding.modifiers.union(primaryFlag)
        guard let key = comboKey(flags) else { return nil }
        return LayoutHotkeyConfig(key: key, rightOnly: false, doubleTap: existing.doubleTap)
    }

    private static func layoutBinding(from config: LayoutHotkeyConfig, switchSlot: Bool) -> HotkeyBinding? {
        switch config.key {
        case "":
            return nil
        case "option":
            return HotkeyBinding(keycode: CGKeyCode(config.rightOnly ? KC.rightOption : KC.leftOption))
        case "command":
            return HotkeyBinding(keycode: CGKeyCode(config.rightOnly ? KC.rightCommand : KC.leftCommand))
        case "control":
            return HotkeyBinding(keycode: CGKeyCode(config.rightOnly ? KC.rightControl : KC.leftControl))
        case "shift":
            return HotkeyBinding(keycode: CGKeyCode(config.rightOnly ? KC.rightShift : KC.leftShift))
        case "capsLock" where !switchSlot:
            return HotkeyBinding(keycode: CGKeyCode(KC.capsLock))
        case "command+shift":
            return HotkeyBinding(keycode: CGKeyCode(KC.rightCommand), modifiers: .maskShift)
        case "control+shift":
            return HotkeyBinding(keycode: CGKeyCode(KC.rightControl), modifiers: .maskShift)
        case "command+option":
            return HotkeyBinding(keycode: CGKeyCode(KC.rightCommand), modifiers: .maskAlternate)
        case "control+option":
            return HotkeyBinding(keycode: CGKeyCode(KC.rightControl), modifiers: .maskAlternate)
        default:
            return nil
        }
    }

    private static func singleModifierKey(_ flag: CGEventFlags) -> String? {
        switch flag {
        case .maskAlternate: "option"
        case .maskCommand: "command"
        case .maskControl: "control"
        case .maskShift: "shift"
        default: nil
        }
    }

    private static func comboKey(_ flags: CGEventFlags) -> String? {
        switch flags {
        case [.maskCommand, .maskShift]: "command+shift"
        case [.maskControl, .maskShift]: "control+shift"
        case [.maskCommand, .maskAlternate]: "command+option"
        case [.maskControl, .maskAlternate]: "control+option"
        default: nil
        }
    }

    private static func isRightModifier(_ keycode: CGKeyCode) -> Bool {
        [KC.rightCommand, KC.rightControl, KC.rightOption, KC.rightShift].contains(UInt16(keycode))
    }
}
