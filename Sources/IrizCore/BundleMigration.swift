import Foundation

/// Идентификатор бандла до переименования продукта.
public let LEGACY_BUNDLE_IDENTIFIER = "ru.smltlk.app"
/// Идентификатор бандла сейчас.
public let IRIZ_BUNDLE_IDENTIFIER = "ru.iriz.app"
/// Отметка о том, что настройки уже перевезены. Живёт в НОВОМ домене.
public let IRIZ_DEFAULTS_MIGRATION_KEY = "ru.iriz.defaultsMigratedFromLegacyBundle"

/// Перевезти настройки из домена прежнего бандла.
///
/// `UserDefaults.standard` у неизолированного приложения адресуется
/// идентификатором бандла: сменили идентификатор - получили пустой домен. Без
/// переезда владелец открыл бы настройки и увидел заводские значения вместо
/// своих сочетаний клавиш, словаря замен и списка приложений.
///
/// Переносится ВСЁ, что лежит в старом домене под нашими префиксами, и только
/// то, чего ещё нет в новом: повторный запуск прежней сборки рядом не должен
/// затирать свежие правки старыми.
///
/// Прецедент в проекте уже был - ключи переезжали с `com.ruswitcher.*` на
/// `ru.smltlk.*`, когда донором был RuSwitcher. Механика та же, меняется домен.
@discardableResult
public func migrateDefaultsFromLegacyBundle(
    legacy: UserDefaults?,
    into destination: UserDefaults,
    prefixes: [String] = ["ru.smltlk.", "ru.iriz."]
) -> Int {
    guard !destination.bool(forKey: IRIZ_DEFAULTS_MIGRATION_KEY) else { return 0 }
    defer { destination.set(true, forKey: IRIZ_DEFAULTS_MIGRATION_KEY) }
    guard let legacy else { return 0 }

    var moved = 0
    for (key, value) in legacy.dictionaryRepresentation() {
        guard prefixes.contains(where: { key.hasPrefix($0) }) else { continue }
        guard key != IRIZ_DEFAULTS_MIGRATION_KEY else { continue }
        guard destination.object(forKey: key) == nil else { continue }
        destination.set(value, forKey: key)
        moved += 1
    }
    return moved
}
