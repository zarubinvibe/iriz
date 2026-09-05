// Профиль промпта по приложению-получателю.
//
// ЧТО ЧИТАЕТСЯ. Только идентификатор приложения, которое было спереди в момент
// нажатия. Ни окно, ни поле ввода, ни текст чужой программы — та же граница,
// что у списка запретов авто-конвертации (`AutoSwitchPolicy.isDeniedApp`).
//
// ЧТО НЕ ОСТАЁТСЯ. Идентификатор здесь и заканчивается: на входе строка, на
// выходе профиль. Вызывающий код обязан выбросить строку сразу и не имеет
// права положить её в файл, в счётчик или в журнал. Запись «куда владелец
// диктует» — это данные о том, с кем он работает; проект такую запись уже
// отказывался вести, и через профили она возвращаться не должна.
//
// Таблица в настройках — не наблюдение, а выбор владельца: строку заводит он
// сам, приложение её никогда не дописывает по факту диктовки.
import Foundation

public struct PromptAppProfileEntry: Codable, Equatable, Sendable {
    /// Идентификатор приложения, например `com.apple.dt.Xcode`.
    public let bundleID: String
    /// Под кого готовить промпт, когда это приложение спереди.
    public let profile: PromptRecipientProfile

    public init(bundleID: String, profile: PromptRecipientProfile) {
        self.bundleID = bundleID
        self.profile = profile
    }
}

/// Чистое решение «приложение → профиль». Состояния нет, побочных эффектов нет,
/// поэтому решение проверяется тестом целиком, без запуска приложения.
public struct PromptAppProfileMap: Equatable, Sendable {
    /// Больше сотни строк владелец в голове не удержит, а список без предела —
    /// это уже не настройка, а свалка. Предел тот же по духу, что у заготовок.
    public static let maximumEntries = 64
    /// Идентификаторы бывают длинными, но не безразмерными. Мусорную строку
    /// длиной в мегабайт в настройки пускать незачем.
    public static let maximumBundleIDBytes = 256

    /// Профиль для всех, кого нет в таблице.
    public let defaultProfile: PromptRecipientProfile
    /// Явные записи владельца. Уже нормализованы: мусор выброшен, дубликаты
    /// склеены, предел соблюдён.
    public let entries: [PromptAppProfileEntry]

    public init(defaultProfile: PromptRecipientProfile, entries: [PromptAppProfileEntry] = []) {
        self.defaultProfile = defaultProfile
        self.entries = normalizedPromptAppProfileEntries(entries)
    }

    /// Пустая таблица, неизвестное приложение и «идентификатора нет вовсе» —
    /// один и тот же исход: профиль по умолчанию. Отказ приложения назвать себя
    /// не должен превращаться ни в ошибку, ни в другой промпт.
    public func profile(forBundleID bundleID: String?) -> PromptRecipientProfile {
        guard let key = promptAppProfileLookupKey(bundleID) else { return defaultProfile }
        let match = entries.first { promptAppProfileLookupKey($0.bundleID) == key }
        return match?.profile ?? defaultProfile
    }
}

/// Обрезает края и отсекает то, что идентификатором быть не может. Пробелов
/// внутри у идентификатора не бывает, поэтому строка с пробелом — это чья-то
/// опечатка или чужие данные, а не приложение.
public func validatedPromptAppProfileBundleID(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.utf8.count <= PromptAppProfileMap.maximumBundleIDBytes,
          !trimmed.contains(where: { $0.isWhitespace }),
          !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
    return trimmed
}

/// Ключ сверки. Регистр снят намеренно: macOS сравнивает идентификаторы
/// без учёта регистра, и `com.apple.Mail` в настройках обязан ловить то же
/// приложение, что и `com.apple.mail`.
func promptAppProfileLookupKey(_ bundleID: String?) -> String? {
    guard let bundleID, let valid = validatedPromptAppProfileBundleID(bundleID) else { return nil }
    return valid.lowercased()
}

/// Негодное молча выбрасывается, дубликаты склеиваются по ключу — последняя
/// запись побеждает НА МЕСТЕ первой, чтобы порядок списка в настройках не
/// прыгал. Ровно та же дисциплина, что у словаря замен и заготовок.
public func normalizedPromptAppProfileEntries(
    _ entries: [PromptAppProfileEntry]
) -> [PromptAppProfileEntry] {
    var result: [PromptAppProfileEntry] = []
    var indexByKey: [String: Int] = [:]

    for entry in entries {
        guard let bundleID = validatedPromptAppProfileBundleID(entry.bundleID) else { continue }
        let cleaned = PromptAppProfileEntry(bundleID: bundleID, profile: entry.profile)
        let key = bundleID.lowercased()
        if let existing = indexByKey[key] {
            result[existing] = cleaned
        } else {
            guard result.count < PromptAppProfileMap.maximumEntries else { continue }
            indexByKey[key] = result.count
            result.append(cleaned)
        }
    }

    return result
}
