// Принадлежность семье Олимпуса - в АКЦЕНТАХ, а не в заливке.
//
// Слова владельца про волну 3 дословно: приложение должно быть «в стиле Apple»
// и нести семейную принадлежность в акцентах. Заливка сюда не годится по двум
// причинам сразу: нативное окно macOS обязано брать фон у системы, и любая
// своя подложка в нём читается как чужая; а ночная тема семьи - это НОЧНОЕ
// НЕБО, и окно настроек звёздным небом не бывает.
//
// Поэтому из канона берутся два СМЫСЛА, а не два пикселя:
//   золото - личное и ценное владельца (его словарь, его заготовки, его
//            инструкции, его профили);
//   голубой - поток: то, что приходит извне и уходит наружу (клавиши,
//            промпт-режим, вставка, плашка записи).
//
// Числа канона (`#C9A87A`, `#B8D6EA`) - это значения для КАРТИНОК на светлом
// мраморе. На белой форме macOS они дают контраст около 1,9:1 и читаются
// грязью, а не акцентом. Поэтому светлая тема берёт тот же ТОН на рабочей
// светлоте, а тёмная - канонные значения дня и ночи, где они и работают.
// Тон один и тот же, светлота подобрана под фон: это адаптация канона, а не
// вторая палитра.
import AppKit
import IrizCore
import SwiftUI

/// Смысл акцента. Ролей ровно две - больше семья не различает.
public enum FamilyAccentRole: Sendable {
    /// Личное и ценное: словарь владельца, заготовки, его инструкции, профили.
    case personal
    /// Поток: клавиши, промпт-режим, вставка, плашка записи.
    case flow
}

/// Канонные значения семьи. Здесь они лежат ради одного: чтобы адаптация
/// светлоты была видна рядом с исходником, а не выглядела отсебятиной.
public enum FamilyPalette {
    /// День: золото Пантеона.
    public static let gold = (r: 0.788, g: 0.659, b: 0.478)      // #C9A87A
    /// День: голубой Пантеона.
    public static let sky = (r: 0.722, g: 0.839, b: 0.918)       // #B8D6EA
    /// Ночь: лунный голубой Нюкты. Тот же смысл, что у дневного голубого.
    public static let lunar = (r: 0.561, g: 0.651, b: 0.784)     // #8FA6C8
}

/// Акцент роли, живущий в обеих темах.
public func familyAccentColor(_ role: FamilyAccentRole) -> NSColor {
    NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        switch (role, dark) {
        // Тёмная тема: канонные значения работают как есть - фон тёмный,
        // и золото остаётся тёплым, ровно как требует ночной канон.
        case (.personal, true):
            return NSColor(srgbRed: FamilyPalette.gold.r, green: FamilyPalette.gold.g,
                           blue: FamilyPalette.gold.b, alpha: 1)
        case (.flow, true):
            return NSColor(srgbRed: FamilyPalette.lunar.r, green: FamilyPalette.lunar.g,
                           blue: FamilyPalette.lunar.b, alpha: 1)
        // Светлая тема: тот же тон на рабочей светлоте.
        case (.personal, false):
            return NSColor(srgbRed: 0.451, green: 0.337, blue: 0.161, alpha: 1)   // #736029
        case (.flow, false):
            return NSColor(srgbRed: 0.157, green: 0.361, blue: 0.502, alpha: 1)   // #285C80
        }
    }
}

public extension Color {
    static func familyAccent(_ role: FamilyAccentRole) -> Color {
        Color(nsColor: familyAccentColor(role))
    }
}

/// Относительная яркость по WCAG. Своя, потому что считать её надо в тесте,
/// а не на глаз: «выглядит контрастно» - не мерило доступности.
public func wcagRelativeLuminance(r: Double, g: Double, b: Double) -> Double {
    func channel(_ value: Double) -> Double {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
}

/// Коэффициент контраста двух цветов по WCAG 2.2.
public func wcagContrastRatio(_ a: (r: Double, g: Double, b: Double),
                              _ b: (r: Double, g: Double, b: Double)) -> Double {
    let la = wcagRelativeLuminance(r: a.r, g: a.g, b: a.b)
    let lb = wcagRelativeLuminance(r: b.r, g: b.g, b: b.b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// Фоны, на которых живут акценты. Числа сняты с настоящих снимков поверхностей
/// (`05_next/proof/ui-2026-09-03`), а не взяты из головы.
public enum FamilySurface {
    /// Светлая форма настроек.
    public static let light = (r: 1.0, g: 1.0, b: 1.0)
    /// Тёмная форма настроек.
    public static let dark = (r: 0.145, g: 0.145, b: 0.145)      // #252525
}

/// Значение акцента как тройка - для тестов контраста.
public func familyAccentComponents(_ role: FamilyAccentRole,
                                   dark: Bool) -> (r: Double, g: Double, b: Double) {
    switch (role, dark) {
    case (.personal, true): return FamilyPalette.gold
    case (.flow, true): return FamilyPalette.lunar
    case (.personal, false): return (0.451, 0.337, 0.161)
    case (.flow, false): return (0.157, 0.361, 0.502)
    }
}

/// Секции окна настроек: имя, символ и смысл акцента - одной таблицей.
///
/// Таблицей, а не литералами по вьюхе, ровно ради одного правила доступности:
/// **цвет никогда не единственный носитель смысла.** У каждой секции свой
/// символ SF и своё имя, и акцент только усиливает то, что уже сказано формой
/// и словом. Уникальность символов держит тест - иначе при дальтонизме две
/// секции слились бы в одну.
public enum SettingsSectionSpec: String, CaseIterable, Sendable {
    case hotkeys, promptMode, promptGuidance, appProfiles, appearance
    case layout, behavior, corrections, snippets, transfer

    public var title: String {
        switch self {
        case .hotkeys: return L("section.hotkeys", "Клавиши")
        case .promptMode: return L("section.promptMode", "Промпт-режим")
        case .promptGuidance: return L("section.promptGuidance", "Свои инструкции и примеры")
        case .appProfiles: return L("section.appProfiles", "Профиль по приложению")
        case .appearance: return L("section.appearance", "Плашка записи")
        case .layout: return L("section.layout", "Режим раскладки")
        case .behavior: return L("section.behavior", "Вставка и запуск")
        case .corrections: return L("section.corrections", "Словарь замен")
        case .snippets: return L("section.snippets", "Заготовки")
        case .transfer: return L("section.transfer", "Словарь и заготовки файлом")
        }
    }

    public var symbol: String {
        switch self {
        case .hotkeys: return "keyboard"
        case .promptMode: return "text.bubble"
        case .promptGuidance: return "lightbulb"
        case .appProfiles: return "app.badge"
        case .appearance: return "waveform"
        case .layout: return "character.cursor.ibeam"
        case .behavior: return "arrow.down.doc"
        case .corrections: return "character.book.closed"
        case .snippets: return "text.append"
        case .transfer: return "square.and.arrow.up.on.square"
        }
    }

    /// Акцент ОДИН на все секции - золото семьи.
    ///
    /// Прежде их было два: золото значило «личное владельца», голубой - «поток
    /// извне и наружу». Смысл был настоящий, но прочесть его можно было только
    /// в исходнике: в окне это выглядело как два случайных цвета вперемешку.
    /// Слова владельца 06.09.2026: «проверить значки, какие-то золотые, какие-то
    /// синие. Это странно. Они должны быть, наверное, как-то одинаковые».
    ///
    /// Различие, которое не читается без комментария в коде, различием не
    /// является - оно шум. Голубой при этом никуда не делся: он остаётся за
    /// ореолом плашки, где значит «здесь работает ИИ», и там он один в кадре.
    public var accent: FamilyAccentRole { .personal }
}
