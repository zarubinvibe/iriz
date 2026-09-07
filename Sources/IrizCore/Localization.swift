// Язык интерфейса: системный или выбранный руками.
//
// Почему таблица, а не строки в коде. Строка, написанная прямо во вьюхе,
// переводится только переписыванием вьюхи, и три языка означали бы три копии
// одного экрана. Таблица переводится заменой файла, а экран остается один.
//
// Почему свой поиск, а не голый NSLocalizedString. Системный ищет только в
// языке ОС, а владелец просил ВЫБОР: человек может держать macOS на английском
// и хотеть русский интерфейс, и наоборот. Поэтому язык решается тут: сначала
// выбор человека, потом системный, потом русский как язык оригинала.
import Foundation

/// Ключ выбора языка. В том же домене, что и остальные настройки.
public let IRIZ_LANGUAGE_KEY = "ru.smltlk.interfaceLanguage"

public enum IrizLanguage: String, CaseIterable, Sendable {
    /// Взять язык системы. Заводское значение.
    case auto
    case ru
    case en
    case zh

    /// Как называется папка перевода. Китайский у Apple зовется zh-Hans:
    /// упрощенное письмо, а не «китайский вообще».
    var folder: String {
        switch self {
        case .auto: return "ru"
        case .ru: return "ru"
        case .en: return "en"
        case .zh: return "zh-Hans"
        }
    }

    /// Локаль для дат и чисел. Отдельно от папки перевода: папка отвечает за
    /// таблицу строк, локаль - за то, как названы месяцы и разделены разряды.
    public var localeIdentifier: String {
        switch self {
        case .auto, .ru: return "ru_RU"
        case .en: return "en_US"
        case .zh: return "zh_Hans_CN"
        }
    }

    /// Имя языка НА НЕМ САМОМ. Человек, открывший список на незнакомом языке,
    /// должен узнать свой: «English» ищут глазами, а не переводом.
    public var ownName: String {
        switch self {
        case .auto: return "Авто"
        case .ru: return "Русский"
        case .en: return "English"
        case .zh: return "简体中文"
        }
    }
}

/// Какой язык показывать при этом выборе и этом языке системы.
///
/// Чистая функция: решение проверяется тестом без Bundle и без UserDefaults.
public func irizResolvedLanguage(choice: IrizLanguage,
                                 systemPreferred: [String]) -> IrizLanguage {
    guard choice == .auto else { return choice }
    for code in systemPreferred {
        let low = code.lowercased()
        if low.hasPrefix("ru") { return .ru }
        if low.hasPrefix("zh") { return .zh }
        if low.hasPrefix("en") { return .en }
    }
    // Язык оригинала. Продукт написан по-русски, и падать некуда, кроме него.
    return .ru
}

/// Выбор человека, прочитанный из настроек.
public func irizLanguageChoice(defaults: UserDefaults = .standard) -> IrizLanguage {
    guard let raw = defaults.string(forKey: IRIZ_LANGUAGE_KEY),
          let choice = IrizLanguage(rawValue: raw) else { return .auto }
    return choice
}

public func setIrizLanguageChoice(_ choice: IrizLanguage, defaults: UserDefaults = .standard) {
    defaults.set(choice.rawValue, forKey: IRIZ_LANGUAGE_KEY)
}

/// Действующий язык интерфейса прямо сейчас.
public func irizCurrentLanguage(defaults: UserDefaults = .standard) -> IrizLanguage {
    irizResolvedLanguage(choice: irizLanguageChoice(defaults: defaults),
                         systemPreferred: Locale.preferredLanguages)
}

/// Перевод по ключу.
///
/// `ru` - не «запасной вариант», а ОРИГИНАЛ: продукт написан по-русски, и в
/// коде стоит русская строка. Если перевода нет, человек видит оригинал, а не
/// голый ключ вида `settings.plate.size`.
/// Перевод по ключу с подстановкой.
///
/// Нужен затем, что `L()` берёт готовую строку, а треть текста продукта строится
/// из частей: «Клавиша диктовки: ⌘», «Пример 2», «Ошибка настроек: …». Такие
/// строки нельзя перевести целиком - в таблице должен лежать ОБРАЗЕЦ с местами
/// подстановки, иначе перевод либо ломает порядок частей, либо не делается
/// вовсе. К 07.09.2026 непереведёнными по этой причине оставались 37 строк,
/// почти все - подписи для голосового доступа.
///
/// Места подстановки в образце: `%@` для строки, `%d` для числа. Порядок частей
/// у языка свой, поэтому в переводе разрешён явный номер довода: `%1$@`.
public func Lf(_ key: String, _ original: String, _ arguments: CVarArg...) -> String {
    String(format: L(key, original), arguments: arguments)
}

/// Бандл таблицы перевода, найденный БЕЗ УЧЁТА РЕГИСТРА.
///
/// Прямой поиск по имени папки ломается о SwiftPM: он кладёт `zh-Hans.lproj`
/// из исходников как `zh-hans.lproj` в собранный бандл, и запрос по канонному
/// имени возвращает пусто. Китайский интерфейс при этом молча показывался
/// по-русски - дефект, который не роняет сборку, не пишет в лог и виден только
/// человеку, не знающему русского.
///
/// Поэтому имя папки сверяется в нижнем регистре, а не берётся как есть.
public func irizLocalizationBundle(for language: IrizLanguage) -> Bundle? {
    if let path = Bundle.module.path(forResource: language.folder, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle
    }
    guard let root = Bundle.module.resourceURL,
          let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return nil }
    let wanted = (language.folder + ".lproj").lowercased()
    guard let match = entries.first(where: { $0.lastPathComponent.lowercased() == wanted }) else {
        return nil
    }
    return Bundle(url: match)
}

public func L(_ key: String, _ original: String) -> String {
    let language = irizCurrentLanguage()
    if language == .ru { return original }
    guard let bundle = irizLocalizationBundle(for: language) else { return original }
    let translated = bundle.localizedString(forKey: key, value: original, table: nil)
    return translated.isEmpty ? original : translated
}
