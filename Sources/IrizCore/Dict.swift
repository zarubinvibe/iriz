// Основано на RuSwitcher (MIT, © 2025 Rashns), коммит 8c45253.
import AppKit

/// Проверка слов по системному словарю (NSSpellChecker) — локально, без зависимостей,
/// без сети и без бандла данных. ~0.1мс на проверку, 40+ языков.
public enum Dict {
    @MainActor private static let checker = NSSpellChecker.shared

    @MainActor public static func isAvailable(_ lang: String) -> Bool {
        let two = String(lang.prefix(2))
        return checker.availableLanguages.contains { String($0.prefix(2)) == two }
    }

    /// true — слово есть в словаре языка (орфография корректна).
    @MainActor public static func isValidWord(_ word: String, lang: String) -> Bool {
        // Второй слой правки #23: словарю отдаём ТОЛЬКО целиком буквенные строки.
        // NSSpellChecker токенизирует по пунктуации, а одиночную латинскую букву
        // считает словом (все 26 из 26, измерено): «объём», набранный как "j,]`v",
        // читался бы как «j»+«v» — «правильный английский», и гейт текущего языка
        // в LayoutDetector блокировал конверсию. Без этого гейта ослабленное вето
        // детектора обнажает ложные .keep на любом образе с пунктуацией.
        guard word.allSatisfy({ $0.isLetter }) else { return false }
        let range = checker.checkSpelling(of: word, startingAt: 0, language: lang,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }
}
