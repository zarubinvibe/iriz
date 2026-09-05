// Основано на RuSwitcher (MIT, © 2025 Rashns), коммит 8c45253.
import Foundation

/// Единственная карта конверсии раскладки в процессе. Строится ТОЛЬКО из UCKeyTranslate
/// на установленных раскладках машины (системный слой, DynamicKeyMapping) и вливается сюда
/// через `configure` — статических таблиц ЙЦУКЕН в коде нет.
///
/// Почему так: «книжный» ЙЦУКЕН и реальная раскладка конкретной машины расходятся
/// (измеренный дефект: на com.apple.keylayout.Russian буква ё сидит на клавише '\',
/// а не '`', как утверждала статическая таблица). Пока существовали две карты —
/// статическая для Core/тестов и динамическая для боя, — они расходились молча, и
/// тесты на ё были зелёными, не проверяя ничего из реального поведения. Одна карта
/// на процесс делает такое расхождение структурно невозможным.
///
/// Пока `configure` не вызван (на машине нет пары en/ru), `convert` возвращает ввод
/// неизменным — честный отказ вместо конверсии по чужой раскладке.
public enum KeyMapping {
    /// EN символ → RU символ (влито из UCKeyTranslate).
    nonisolated(unsafe) public private(set) static var enToRu: [Character: Character] = [:]
    /// RU символ → EN символ (влито из UCKeyTranslate).
    nonisolated(unsafe) public private(set) static var ruToEn: [Character: Character] = [:]
    /// Кейкоды, дающие печатный символ хотя бы в одной раскладке пары
    /// (проверка «клавиша накапливается в буфер слова» на горячем пути тапа).
    nonisolated(unsafe) public private(set) static var printableKeycodes: Set<UInt16> = []

    public static var isConfigured: Bool { !enToRu.isEmpty && !ruToEn.isEmpty }

    public static func configure(enToRu: [Character: Character],
                                 ruToEn: [Character: Character],
                                 printableKeycodes: Set<UInt16>) {
        self.enToRu = enToRu
        self.ruToEn = ruToEn
        self.printableKeycodes = printableKeycodes
    }

    /// Сброс при смене раскладок в настройках (следующий configure вольёт карту заново).
    public static func reset() {
        enToRu = [:]
        ruToEn = [:]
        printableKeycodes = []
    }

    /// Конвертирует строку из одной раскладки в другую; направление — по содержимому
    /// (есть кириллица → RU→EN, иначе EN→RU). До configure — возвращает ввод как есть.
    public static func convert(_ text: String) -> String {
        guard isConfigured else { return text }
        let isLikelyRussian = text.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        let hasLatin = text.unicodeScalars.contains { ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A) }
        // Текст без латиницы и кириллицы (иврит, арабский и т.п.) не мапим вообще.
        guard isLikelyRussian || hasLatin else { return text }
        let map = isLikelyRussian ? ruToEn : enToRu
        return String(text.map { map[$0] ?? $0 })
    }
}
