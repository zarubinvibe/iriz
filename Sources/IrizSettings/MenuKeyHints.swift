import IrizCore
import CoreGraphics
import Foundation
import IrizDictate
import IrizInput

/// Клавиши, которые показывает меню строки меню.
///
/// ПОЧЕМУ ТИП, А НЕ СПИСОК СТРОК. Предыдущий `MenuHotkeyLabels.labels()` отдавал
/// шесть готовых строк, и меню вываливало их подряд серой справкой — самый
/// большой блок в меню, который `VISUAL_SPEC §6.2` прямо запретил. Клавиша
/// должна стоять рядом со своим действием, поэтому меню получает адресуемые
/// поля, а не список.
///
/// ПОЧЕМУ nil, А НЕ ПУСТАЯ СТРОКА. `nil` здесь значит «клавиша сейчас ничего не
/// сделает» — и меню обязано её не показывать. Меню, обещающее несуществующее, —
/// дефект, на котором проект горел четырежды.
public struct MenuKeyHints: Equatable, Sendable {
    /// Диктовка. Глобальный тап, работает независимо от режима раскладки.
    public let dictation: String
    /// Ручное исправление слова. `nil` в «Паузе»: `onAltTap` выходит по
    /// `guard autoSwitchEnabled`, значит клавиша там мертва.
    public let conversion: String?
    /// Промпт-режим. `nil`, когда он выключен, — а выключен он по умолчанию.
    public let prompt: String?
    /// Окно истории надиктовок. Всегда есть: хоткей работает независимо от
    /// режима раскладки и от промпт-режима.
    public let history: String

    public init(dictation: String, conversion: String?, prompt: String?, history: String) {
        self.dictation = dictation
        self.conversion = conversion
        self.prompt = prompt
        self.history = history
    }
}

@MainActor
public enum MenuKeys {
    public static func current() -> MenuKeyHints {
        hints(dictation: .shared, layout: .shared)
    }

    static func hints(dictation: DictationSettings, layout: SettingsManager) -> MenuKeyHints {
        MenuKeyHints(
            dictation: russianKeyName(dictation.configuredHotkey),
            conversion: layout.autoSwitchEnabled
                ? layoutKeyName(key: layout.triggerKey,
                                rightOnly: layout.triggerRightOnly,
                                doubleTap: layout.triggerDoubleTap)
                : nil,
            prompt: dictation.promptModeEnabled
                ? russianKeyName(dictation.configuredPromptHotkey)
                : nil,
            history: russianKeyName(dictation.configuredHistoryHotkey)
        )
    }

    // MARK: - Одна нотация: глифы, как их печатает сама macOS

    /// `HotkeyChoice.name` собран для окна настроек и говорит по-английски
    /// («Right Command», «Control + Right Command»). В меню это давало три
    /// нотации в шести строках — читателю приходилось каждый раз переводить.
    /// Здесь одна: модификаторы глифами, сторона клавиши — словом.
    public static func russianKeyName(_ choice: HotkeyChoice) -> String {
        let modifiers = modifierGlyphs(choice.requiredModifiers)
        if choice.isModifier {
            let base = sidedModifierNames[choice.keycode] ?? choice.name
            return modifiers.isEmpty ? base : "\(modifiers) \(base)"
        }
        return modifiers + plainKeyName(choice)
    }

    /// Сторона клавиши по коду: глифа «правый ⌘» в системе нет, а разница
    /// существенная — на левом Command хоткей не сработает.
    /// Слова «левый» и «правый» переводятся, глифы - нет: ⌘ и ⌥ одинаковы во
    /// всех языках, а сторона на левом Command решает, сработает хоткей или нет.
    private static var sidedModifierNames: [CGKeyCode: String] {
        let left = L("key.left", "левый")
        let right = L("key.right", "правый")
        return [
            59: "\(left) ⌃", 62: "\(right) ⌃",
            58: "\(left) ⌥", 61: "\(right) ⌥",
            56: "\(left) ⇧", 60: "\(right) ⇧",
            55: "\(left) ⌘", 54: "\(right) ⌘",
            63: "fn",
        ]
    }

    /// Клавиши без буквы — глифами macOS, иначе в русском меню всплывёт «Space».
    private static let namedKeyGlyphs: [String: String] = [
        "Space": "␣",
        "Return": "⏎",
        "Enter": "⌤",
        "Tab": "⇥",
        "Delete": "⌫",
        "Forward Delete": "⌦",
        "Left Arrow": "←",
        "Right Arrow": "→",
        "Up Arrow": "↑",
        "Down Arrow": "↓",
        "Page Up": "⇞",
        "Page Down": "⇟",
        "Home": "↖",
        "End": "↘",
    ]

    /// У не-модификатора `name` уже собран как «глифы + имя клавиши»,
    /// поэтому берём хвост после модификаторов и переводим только его.
    private static func plainKeyName(_ choice: HotkeyChoice) -> String {
        let bare = String(choice.name.drop(while: { !$0.isLetter && !$0.isNumber && !$0.isPunctuation }))
        let key = bare.isEmpty ? choice.name : bare
        return namedKeyGlyphs[key] ?? key
    }

    private static func modifierGlyphs(_ flags: CGEventFlags) -> String {
        var result = ""
        if flags.contains(.maskControl) { result += "⌃" }
        if flags.contains(.maskAlternate) { result += "⌥" }
        if flags.contains(.maskShift) { result += "⇧" }
        if flags.contains(.maskCommand) { result += "⌘" }
        if flags.contains(.maskSecondaryFn) { result += "fn" }
        return result
    }

    /// Раскладочный триггер хранится не кодом клавиши, а словом («option»),
    /// и различает не сторону, а «только правая» — отсюда отдельная таблица.
    static func layoutKeyName(key: String, rightOnly: Bool, doubleTap: Bool) -> String? {
        let base: String?
        switch key {
        case "option": base = rightOnly ? "правый ⌥" : "⌥"
        case "command": base = rightOnly ? "правый ⌘" : "⌘"
        case "control": base = rightOnly ? "правый ⌃" : "⌃"
        case "shift": base = rightOnly ? "правый ⇧" : "⇧"
        case "capsLock": base = "Caps Lock"
        case "command+shift": base = "⌘⇧"
        case "control+shift": base = "⌃⇧"
        case "command+option": base = "⌘⌥"
        case "control+option": base = "⌃⌥"
        default: base = nil
        }
        return base.map { doubleTap ? "\($0) дважды" : $0 }
    }
}
