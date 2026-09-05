// Основано на SuperDictate (MIT, © 2026 Richard Courtman), коммит 83dd7e4.
// Настройки диктовки над UserDefaults — ужатый срез донорского Settings:
// только ключи, которые реально использует владелец. Дефолты инлайн в
// геттерах (register() нет), имена ключей и дефолты совпадают с донором.
import CoreGraphics
import Foundation
import IrizPrompt

/// Кому предназначен готовый промпт. Это не выбор генератора: генератор
/// выбирается отдельно (`promptAgentID`), профиль лишь готовит текст под
/// исполнителя.
///
/// Имя оставлено ради вызывающего кода настроек, но тип теперь ОДИН и тот же,
/// что уходит в генератор. Раньше рядом жили два перечисления с одинаковыми
/// вариантами и одинаковыми rawValue, и каждое место стыка приходилось
/// переводить руками — с таблицей «приложение → профиль» такой перевод стал бы
/// третьим по счёту и первым же местом, где они разъедутся.
public typealias PromptRecipientSetting = PromptRecipientProfile

public final class DictationSettings: @unchecked Sendable {
    private static let keyHotkeyKeycode = "hotkey_keycode"
    private static let keyHotkeyModifiers = "hotkey_modifiers"
    private static let keyEnterHotkeyKeycode = "enter_hotkey_keycode"
    private static let keyEnterHotkeyModifiers = "enter_hotkey_modifiers"
    private static let keyHistoryHotkeyKeycode = "history_hotkey_keycode"
    private static let keyHistoryHotkeyModifiers = "history_hotkey_modifiers"
    private static let keyPromptHotkeyKeycode = "prompt_hotkey_keycode"
    private static let keyTranslationHotkeyKeycode = "translation_hotkey_keycode"
    private static let keyTranslationHotkeyModifiers = "translation_hotkey_modifiers"
    private static let keyTranslationEnabled = "translation_mode_enabled"
    private static let keyTranslationTargetLanguage = "translation_target_language"
    private static let keyPromptHotkeyModifiers = "prompt_hotkey_modifiers"
    private static let keyPromptModeEnabled = "prompt_mode_enabled_v1"
    private static let keyPromptRecipient = "prompt_recipient_profile_v2"
    private static let keyPromptAppProfiles = "prompt_app_profiles_v1"
    private static let keyCodexExecutablePath = "codex_executable_path_v1"
    private static let keyPromptAgentID = "prompt_agent_id_v1"
    private static let keyPromptAgentPaths = "prompt_agent_paths_v1"
    private static let keySpeechEngine = "speech_engine_v1"
    private static let keyPromptAgentModel = "prompt_agent_model_v1"
    private static let keyPromptAgentCustomArguments = "prompt_agent_custom_arguments_v1"
    private static let keyPromptOnboardingOffered = "prompt_onboarding_offered_v1"
    private static let keyPrimaryCompletionBehavior = "primary_completion_behavior_v1"
    private static let keyAlternateCompletionEnabled = "alternate_completion_enabled_v1"
    private static let keyTriggerMode = "trigger_mode"
    private static let keyPasteSuffix = "paste_suffix"
    private static let keyPlayFeedbackSounds = "play_feedback_sounds"
    private static let keyInputDevice = "input_device"
    private static let keyTranscriptCorrections = "transcript_corrections"
    private static let keyDictationSnippets = "dictation_snippets_v1"
    private static let keyPromptUserGuidance = "prompt_user_guidance_v1"
    private static let keySpeechCleanupMode = "speech_cleanup_mode_v1"
    private static let keyDictationHUDSize = "dictation_hud_size_v1"
    private static let keyDictationLanguage = "dictation_language"
    private static let keyRemoveFinalPeriod = "remove_final_period_v1"
    private static let keyEnterDelayMilliseconds = "enter_delay_milliseconds_v1"
    private static let keyDictationHUDPositionFractionX = "dictation_hud_position_fraction_x"
    private static let keyDictationHUDPositionFractionY = "dictation_hud_position_fraction_y"
    private static let keyDictationHUDPositionDisplayID = "dictation_hud_position_display_id"
    private static let keyDictationHUDHintShownCount = "dictation_hud_hint_shown_count"
    private static let keyDictationHUDWavePalette = "dictation_hud_wave_palette_v1"
    private static let keyRescueWindowEnabled = "rescue_window_enabled_v1"

    private let defaults: UserDefaults

    public static let shared = DictationSettings()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seedDefaultTranscriptCorrectionsOnce()
    }

    private static let keyCorrectionsSeeded = "ru.smltlk.transcriptCorrectionsSeeded"

    /// Заводской словарь замен без этого вызова остался бы мёртвым кодом: геттер
    /// `transcriptCorrections` при отсутствии ключа возвращает пустой список, и в
    /// продукте словарь был бы пуст, как бы хорошо он ни был собран.
    ///
    /// Сеем РАЗ и помечаем флагом, а не подставляем набор в геттер: иначе удалённая
    /// владельцем запись воскресала бы при каждом запуске. Удаление — его право.
    private func seedDefaultTranscriptCorrectionsOnce() {
        guard !defaults.bool(forKey: Self.keyCorrectionsSeeded) else { return }
        defaults.set(true, forKey: Self.keyCorrectionsSeeded)
        // Уже есть свои записи — не трогаем: значит владелец успел завести словарь
        // до появления заводского набора, и его правки важнее наших.
        guard transcriptCorrections.isEmpty else { return }
        transcriptCorrections = defaultTranscriptCorrections
    }

    @discardableResult
    func refreshFromDisk() -> Bool {
        defaults.synchronize()
    }

    // MARK: - Горячие клавиши (по умолчанию: голый правый Cmd, toggle)

    public var hotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyHotkeyKeycode))
                ?? DEFAULT_HOTKEY_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? DEFAULT_HOTKEY_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyHotkeyKeycode)
        }
    }

    public var hotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyHotkeyModifiers) as? NSNumber
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyHotkeyModifiers)
        }
    }

    public var configuredHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: hotkeyKeycode, modifiers: hotkeyModifiers)
    }

    public var enterHotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyEnterHotkeyKeycode))
                ?? RIGHT_COMMAND_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? RIGHT_COMMAND_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyEnterHotkeyKeycode)
        }
    }

    public var enterHotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyEnterHotkeyModifiers) as? NSNumber
            if raw == nil { return .maskAlternate }
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyEnterHotkeyModifiers)
        }
    }

    public var configuredEnterHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: enterHotkeyKeycode, modifiers: enterHotkeyModifiers)
    }

    public var historyHotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyHistoryHotkeyKeycode))
                ?? RIGHT_COMMAND_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? RIGHT_COMMAND_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyHistoryHotkeyKeycode)
        }
    }

    public var historyHotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyHistoryHotkeyModifiers) as? NSNumber
            if raw == nil { return .maskShift }
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyHistoryHotkeyModifiers)
        }
    }

    public var configuredHistoryHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: historyHotkeyKeycode, modifiers: historyHotkeyModifiers)
    }

    public var promptHotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyPromptHotkeyKeycode))
                ?? RIGHT_COMMAND_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? RIGHT_COMMAND_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyPromptHotkeyKeycode)
        }
    }

    public var promptHotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyPromptHotkeyModifiers) as? NSNumber
            if raw == nil { return .maskControl }
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyPromptHotkeyModifiers)
        }
    }

    public var configuredPromptHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: promptHotkeyKeycode, modifiers: promptHotkeyModifiers)
    }

    // MARK: - Перевод голосом

    /// Режим перевода выключен заводски, как и промпт-режим: он уводит речь
    /// наружу к агенту, и включать такое молча нельзя.
    public var translationModeEnabled: Bool {
        get { defaults.bool(forKey: Self.keyTranslationEnabled) }
        set { defaults.set(newValue, forKey: Self.keyTranslationEnabled) }
    }

    /// Куда переводим. По умолчанию английский: владелец назвал именно этот
    /// случай - «я говорю по-русски, а вставляется английский текст».
    public var translationTargetLanguage: String {
        get {
            let stored = defaults.string(forKey: Self.keyTranslationTargetLanguage) ?? ""
            return stored.isEmpty ? "английский" : stored
        }
        set { defaults.set(newValue, forKey: Self.keyTranslationTargetLanguage) }
    }

    public var translationHotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyTranslationHotkeyKeycode))
                ?? RIGHT_COMMAND_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? RIGHT_COMMAND_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyTranslationHotkeyKeycode)
        }
    }

    public var translationHotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyTranslationHotkeyModifiers) as? NSNumber
            // Заводское сочетание отличается от промпт-режима: там Control,
            // здесь Shift. Совпадение молча отобрало бы у одного режима клавишу.
            if raw == nil { return .maskShift }
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyTranslationHotkeyModifiers)
        }
    }

    public var configuredTranslationHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: translationHotkeyKeycode, modifiers: translationHotkeyModifiers)
    }

    // MARK: - Очистка речи

    /// Где чистится речь. Умолчание - на этой машине: очистка полезна, а
    /// отправка текста наружу требует отдельного решения владельца.
    ///
    /// Неизвестное сохранённое значение не поднимается до внешнего режима
    /// молча. Битая запись в настройках не имеет права выпустить текст с
    /// машины - падаем в самый закрытый режим, а не в самый полезный.
    public var speechCleanupMode: SpeechCleanupMode {
        get {
            guard let raw = defaults.string(forKey: Self.keySpeechCleanupMode),
                  let mode = SpeechCleanupMode(rawValue: raw) else {
                return .local
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keySpeechCleanupMode) }
    }

    // MARK: - Промпт-режим

    public var promptModeEnabled: Bool {
        get { defaults.bool(forKey: Self.keyPromptModeEnabled) }
        set { defaults.set(newValue, forKey: Self.keyPromptModeEnabled) }
    }

    /// Codex — владельческий дефолт. Неизвестное сохранённое значение
    /// не должно молча менять поведение на более общее.
    /// Какой распознаватель стоит. По умолчанию - Whisper turbo с подсказкой
    /// декодеру: замер 03.09.2026 (`bench/BENCH-CANDIDATES-2026-09-03.md`) показал,
    /// что он чинит главный дефект прежнего движка и при этом достаточно быстр.
    ///
    /// Чем оплачено. Parakeet транслитерировал английские термины внутри русской
    /// фразы: `git rebase` в «гид репейс», `MCP` в «Мсипи», - на смешанной речи
    /// 44,05 процента ошибок против 19,05 у turbo. На честной шкале (без записей,
    /// где числа выписаны словами, - там прежний движок совпадал с эталоном по
    /// соглашению записи, а не по слуху) turbo лучше и на всем русском: 21,24
    /// против 31,42. Английский 13,28 против 18,75.
    ///
    /// Плата - скорость: около 2,7 раза быстрее записи на коротких русских
    /// репликах против 21-29 у Parakeet, то есть примерно 1,5 секунды ожидания
    /// на четырехсекундную надиктовку вместо 0,2. Прежний движок остается в том
    /// же бинарнике и выбирается здесь же.
    public var speechEngine: SpeechModelProfile {
        get {
            defaults.string(forKey: Self.keySpeechEngine)
                .flatMap(SpeechModelProfile.init(rawValue:)) ?? SpeechModelProfile.installedDefault()
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keySpeechEngine) }
    }

    public var promptRecipient: PromptRecipientSetting {
        get {
            defaults.string(forKey: Self.keyPromptRecipient)
                .flatMap(PromptRecipientSetting.init(rawValue:)) ?? .codex
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyPromptRecipient) }
    }

    /// Таблица «приложение → профиль»: JSON-массив `[PromptAppProfileEntry]`.
    ///
    /// Здесь лежит ВЫБОР ВЛАДЕЛЬЦА, а не наблюдение. Строку заводит он сам в
    /// настройках; приложение никогда не дописывает её по факту диктовки и не
    /// сохраняет идентификатор того, что было спереди. У владельца пусто, пока
    /// он не добавил первое приложение руками.
    public var promptAppProfiles: [PromptAppProfileEntry] {
        get {
            guard let data = defaults.data(forKey: Self.keyPromptAppProfiles),
                  let decoded = try? JSONDecoder().decode([PromptAppProfileEntry].self, from: data) else {
                return []
            }
            return normalizedPromptAppProfileEntries(decoded)
        }
        set {
            let normalized = normalizedPromptAppProfileEntries(newValue)
            if let data = try? JSONEncoder().encode(normalized) {
                defaults.set(data, forKey: Self.keyPromptAppProfiles)
            }
        }
    }

    /// Готовое решение целиком: явные записи владельца плюс профиль для всех
    /// остальных. Дефолт — та же настройка «Исполнитель промпта», отдельного
    /// ключа для него нет: два места для одного смысла разъезжаются.
    public var promptAppProfileMap: PromptAppProfileMap {
        PromptAppProfileMap(defaultProfile: promptRecipient, entries: promptAppProfiles)
    }

    /// Пустая строка включает автопоиск Codex. Ключ остался донорским: это
    /// путь именно к Codex, а не к «текущему агенту», иначе сохранённый
    /// владельцем путь сменил бы смысл после обновления.
    public var codexExecutablePath: String {
        get { defaults.string(forKey: Self.keyCodexExecutablePath) ?? "" }
        set { defaults.set(newValue, forKey: Self.keyCodexExecutablePath) }
    }

    /// Кто собирает промпт. Неизвестное сохранённое значение не должно молча
    /// уводить расшифровку к другому получателю — откатываемся к дефолту.
    public var promptAgentID: String {
        get {
            let stored = defaults.string(forKey: Self.keyPromptAgentID) ?? ""
            return PromptAgentCatalog.identifiers.contains(stored)
                ? stored
                : PromptAgentCatalog.defaultID
        }
        set { defaults.set(newValue, forKey: Self.keyPromptAgentID) }
    }

    /// Модель для агентов, которым она нужна (`ollama run <модель>`).
    public var promptAgentModel: String {
        get { defaults.string(forKey: Self.keyPromptAgentModel) ?? "" }
        set { defaults.set(newValue, forKey: Self.keyPromptAgentModel) }
    }

    /// Аргументы своего CLI — по одному в строке. Никакого разбора кавычек:
    /// строка есть аргумент, поэтому shell-склейки не возникает в принципе.
    public var promptAgentCustomArguments: [String] {
        get {
            (defaults.string(forKey: Self.keyPromptAgentCustomArguments) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            defaults.set(newValue.joined(separator: "\n"), forKey: Self.keyPromptAgentCustomArguments)
        }
    }

    /// Путь хранится отдельно для каждого агента: переключение не должно
    /// подсовывать новому агенту чужой исполняемый файл.
    public func promptAgentPath(for id: String) -> String {
        guard id != PromptAgentCatalog.codexID else { return codexExecutablePath }
        let stored = defaults.object(forKey: Self.keyPromptAgentPaths) as? [String: String]
        return stored?[id] ?? ""
    }

    public func setPromptAgentPath(_ path: String, for id: String) {
        guard id != PromptAgentCatalog.codexID else {
            codexExecutablePath = path
            return
        }
        var stored = (defaults.object(forKey: Self.keyPromptAgentPaths) as? [String: String]) ?? [:]
        stored[id] = path
        defaults.set(stored, forKey: Self.keyPromptAgentPaths)
    }

    public var promptOnboardingOffered: Bool {
        get { defaults.bool(forKey: Self.keyPromptOnboardingOffered) }
        set { defaults.set(newValue, forKey: Self.keyPromptOnboardingOffered) }
    }

    /// Адаптер выбранного агента. Свой CLI собирается из сохранённых аргументов.
    public var promptAgentAdapter: PromptAgentAdapter {
        PromptAgentCatalog.adapter(
            id: promptAgentID,
            customArguments: promptAgentCustomArguments
        ) ?? PromptAgentCatalog.codex
    }

    /// Ищет только исполняемый файл. Shell не запускается, сети нет — один
    /// `access(X_OK)` по путям.
    public static func detectAgentExecutable(
        adapter: PromptAgentAdapter,
        storedPath: String = "",
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates: [String] = []
        if let stored = executableCandidate(storedPath, homeDirectory: homeDirectory) {
            candidates.append(stored)
        }
        if !adapter.executableName.isEmpty {
            if let pathEnvironment {
                candidates += pathEnvironment.split(separator: ":", omittingEmptySubsequences: true)
                    .compactMap { executableCandidate(String($0), homeDirectory: homeDirectory) }
                    .map {
                        URL(fileURLWithPath: $0)
                            .appendingPathComponent(adapter.executableName)
                            .standardizedFileURL.path
                    }
            }
            candidates += adapter.knownPaths.compactMap {
                executableCandidate($0, homeDirectory: homeDirectory)
            }
        }

        for path in candidates {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: path) else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static func detectCodexExecutable(
        storedPath: String = "",
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        detectAgentExecutable(
            adapter: PromptAgentCatalog.codex,
            storedPath: storedPath,
            pathEnvironment: pathEnvironment,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }

    public func detectCodexExecutable() -> URL? {
        Self.detectCodexExecutable(storedPath: codexExecutablePath)
    }

    /// Исполняемый файл выбранного агента.
    public func detectPromptAgentExecutable() -> URL? {
        let adapter = promptAgentAdapter
        return Self.detectAgentExecutable(
            adapter: adapter,
            storedPath: promptAgentPath(for: adapter.id)
        )
    }

    private static func executableCandidate(_ rawPath: String, homeDirectory: URL) -> String? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path == "~" { return homeDirectory.standardizedFileURL.path }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL.path
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Позиция плашки

    /// Доля видимой области до центра плашки. Если одного из двух ключей нет
    /// или в defaults лежит мусор, сохранённой позиции нет целиком.
    var dictationHUDPositionFraction: CGPoint? {
        get {
            guard let x = defaults.object(forKey: Self.keyDictationHUDPositionFractionX) as? NSNumber,
                  let y = defaults.object(forKey: Self.keyDictationHUDPositionFractionY) as? NSNumber,
                  x.doubleValue.isFinite,
                  y.doubleValue.isFinite else { return nil }
            return CGPoint(x: min(1, max(0, x.doubleValue)),
                           y: min(1, max(0, y.doubleValue)))
        }
        set {
            guard let newValue, newValue.x.isFinite, newValue.y.isFinite else {
                defaults.removeObject(forKey: Self.keyDictationHUDPositionFractionX)
                defaults.removeObject(forKey: Self.keyDictationHUDPositionFractionY)
                return
            }
            defaults.set(min(1, max(0, Double(newValue.x))),
                         forKey: Self.keyDictationHUDPositionFractionX)
            defaults.set(min(1, max(0, Double(newValue.y))),
                         forKey: Self.keyDictationHUDPositionFractionY)
        }
    }

    var dictationHUDPositionDisplayID: UInt32? {
        get {
            guard let value = defaults.object(forKey: Self.keyDictationHUDPositionDisplayID)
                    as? NSNumber else { return nil }
            let raw = value.int64Value
            guard raw >= 0, raw <= Int64(UInt32.max) else { return nil }
            return UInt32(raw)
        }
        set {
            if let newValue {
                defaults.set(Int64(newValue), forKey: Self.keyDictationHUDPositionDisplayID)
            } else {
                defaults.removeObject(forKey: Self.keyDictationHUDPositionDisplayID)
            }
        }
    }

    var dictationHUDHintShownCount: Int {
        get { max(0, defaults.integer(forKey: Self.keyDictationHUDHintShownCount)) }
        set { defaults.set(max(0, newValue), forKey: Self.keyDictationHUDHintShownCount) }
    }

    /// Палитра ленты. Неизвестное сохранённое значение не должно молча менять
    /// вид плашки — падаем на заводскую, как и с исполнителем промпта.
    public var dictationHUDWavePalette: DictationHUDWavePalette {
        get {
            defaults.string(forKey: Self.keyDictationHUDWavePalette)
                .flatMap(DictationHUDWavePalette.init(rawValue:))
                ?? DICTATION_HUD_DEFAULT_WAVE_PALETTE
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyDictationHUDWavePalette) }
    }

    /// Поднимать ли окно с текстом, который не доехал до поля. По умолчанию да:
    /// провал доставки редок, а молчаливый провал стоит владельцу целой
    /// надиктовки. Выключатель есть — насильно показывать окно тому, кому оно
    /// мешает, приложение права не имеет.
    public var rescueWindowEnabled: Bool {
        get {
            if defaults.object(forKey: Self.keyRescueWindowEnabled) == nil { return true }
            return defaults.bool(forKey: Self.keyRescueWindowEnabled)
        }
        set { defaults.set(newValue, forKey: Self.keyRescueWindowEnabled) }
    }

    func incrementDictationHUDHintShownCount() {
        guard dictationHUDHintShownCount < Int.max else { return }
        dictationHUDHintShownCount += 1
    }

    /// Drag сохраняет единый якорь только на mouseUp. Вызывающий код не может
    /// забыть displayID или оставить половину старой позиции.
    func saveDictationHUDPosition(fraction: CGPoint, displayID: UInt32) {
        guard fraction.x.isFinite, fraction.y.isFinite else {
            clearDictationHUDPosition()
            return
        }
        dictationHUDPositionFraction = fraction
        dictationHUDPositionDisplayID = displayID
    }

    func clearDictationHUDPosition() {
        dictationHUDPositionFraction = nil
        dictationHUDPositionDisplayID = nil
    }

    // MARK: - Поведение завершения

    var primaryCompletionBehavior: DictationCompletionBehavior {
        get {
            guard let raw = defaults.string(forKey: Self.keyPrimaryCompletionBehavior),
                  let behavior = DictationCompletionBehavior(rawValue: raw) else {
                return .insert
            }
            return behavior
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyPrimaryCompletionBehavior) }
    }

    var alternateCompletionEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.keyAlternateCompletionEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Self.keyAlternateCompletionEnabled)
        }
        set { defaults.set(newValue, forKey: Self.keyAlternateCompletionEnabled) }
    }

    /// Delay between pasting the transcribed text and posting the
    /// Return key when the completion behavior includes "+ Enter".
    public var enterDelayMilliseconds: Int {
        get {
            guard defaults.object(forKey: Self.keyEnterDelayMilliseconds) != nil else {
                return 120
            }
            return max(0, min(500, defaults.integer(forKey: Self.keyEnterDelayMilliseconds)))
        }
        set { defaults.set(max(0, min(500, newValue)), forKey: Self.keyEnterDelayMilliseconds) }
    }

    /// Режим триггера — toggle (нажал → пишет, нажал → стоп). Так работает
    /// у владельца сейчас, переучивать нельзя.
    var triggerMode: TriggerMode {
        get {
            if let v = defaults.string(forKey: Self.keyTriggerMode), let m = TriggerMode(rawValue: v) {
                return m
            }
            return .toggle
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyTriggerMode) }
    }

    public var pasteSuffix: PasteSuffix {
        get {
            if let v = defaults.string(forKey: Self.keyPasteSuffix), let s = PasteSuffix(rawValue: v) {
                return s
            }
            return .appendSpace
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyPasteSuffix) }
    }

    // MARK: - Звук, устройство, язык

    var playFeedbackSounds: Bool {
        get {
            if defaults.object(forKey: Self.keyPlayFeedbackSounds) == nil { return true }
            return defaults.bool(forKey: Self.keyPlayFeedbackSounds)
        }
        set { defaults.set(newValue, forKey: Self.keyPlayFeedbackSounds) }
    }

    var inputDevice: String {
        get {
            guard let raw = defaults.string(forKey: Self.keyInputDevice),
                  let normalized = normalizedInputDevicePreference(raw) else {
                return ""
            }
            return normalized
        }
        set {
            if let normalized = normalizedInputDevicePreference(newValue) {
                defaults.set(normalized, forKey: Self.keyInputDevice)
            } else {
                defaults.removeObject(forKey: Self.keyInputDevice)
            }
        }
    }

    var dictationLanguage: DictationLanguage {
        get {
            if let v = defaults.string(forKey: Self.keyDictationLanguage),
               let lang = DictationLanguage(rawValue: v) {
                return lang
            }
            return .auto
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyDictationLanguage) }
    }

    var removeFinalPeriod: Bool {
        get { defaults.bool(forKey: Self.keyRemoveFinalPeriod) }
        set { defaults.set(newValue, forKey: Self.keyRemoveFinalPeriod) }
    }

    /// Словарь пользовательских замен: Data с JSON-массивом
    /// [TranscriptCorrection]. У владельца пуст.
    public var transcriptCorrections: [TranscriptCorrection] {
        get {
            guard let data = defaults.data(forKey: Self.keyTranscriptCorrections),
                  let decoded = try? JSONDecoder().decode([TranscriptCorrection].self, from: data) else {
                return []
            }
            return normalizedTranscriptCorrections(decoded)
        }
        set {
            let normalized = normalizedTranscriptCorrections(newValue)
            if let data = try? JSONEncoder().encode(normalized) {
                defaults.set(data, forKey: Self.keyTranscriptCorrections)
            }
        }
    }

    /// Размер плашки записи. Прежнее 124,2 x 36,8 pt было наследством донора,
    /// а не решением: теперь это выбор владельца из трёх.
    public var dictationHUDSize: DictationHUDSizeChoice {
        get {
            guard let raw = defaults.string(forKey: Self.keyDictationHUDSize),
                  let value = DictationHUDSizeChoice(rawValue: raw) else {
                return DICTATION_HUD_DEFAULT_SIZE
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyDictationHUDSize) }
    }

    /// Свои инструкции и примеры промпт-режима. Хранятся ОДНИМ ключом: их
    /// правят вместе и вместе же выключают, а разложенные по трём ключам они
    /// расходились бы при импорте.
    ///
    /// Обычная диктовка это поле не читает НИКОГДА - она обязана оставаться
    /// дословной. Читает только сборка промпта.
    public var promptUserGuidance: PromptUserGuidance {
        get {
            guard let data = defaults.data(forKey: Self.keyPromptUserGuidance),
                  let decoded = try? JSONDecoder().decode(PromptUserGuidance.self, from: data) else {
                return .none
            }
            return normalizedPromptUserGuidance(decoded)
        }
        set {
            let normalized = normalizedPromptUserGuidance(newValue)
            if let data = try? JSONEncoder().encode(normalized) {
                defaults.set(data, forKey: Self.keyPromptUserGuidance)
            }
        }
    }

    /// Заготовки: Data с JSON-массивом [DictationSnippet]. Отдельный ключ,
    /// отдельный список — заводского набора нет, у всех пусто до первой
    /// собственноручной записи.
    public var snippets: [DictationSnippet] {
        get {
            guard let data = defaults.data(forKey: Self.keyDictationSnippets),
                  let decoded = try? JSONDecoder().decode([DictationSnippet].self, from: data) else {
                return []
            }
            return normalizedDictationSnippets(decoded)
        }
        set {
            let normalized = normalizedDictationSnippets(newValue)
            if let data = try? JSONEncoder().encode(normalized) {
                defaults.set(data, forKey: Self.keyDictationSnippets)
            }
        }
    }
}
