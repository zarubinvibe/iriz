// Основано на RuSwitcher (MIT, © 2025 Rashns), коммит 8c45253.
import Foundation
import ServiceManagement

/// Централизованное хранение настроек через UserDefaults
/// Настройки приложения. Свойства thread-safe через UserDefaults.
public final class SettingsManager: @unchecked Sendable {
    public static let shared = SettingsManager(defaults: .standard)

    private let defaults: UserDefaults

    private enum Keys {
        static let autoSwitch = "ru.smltlk.autoSwitch"
        static let layout1ID = "ru.smltlk.layout1ID"
        static let layout2ID = "ru.smltlk.layout2ID"
        static let launchAtLogin = "ru.smltlk.launchAtLogin"
        static let permissionsWereGranted = "ru.smltlk.permissionsWereGranted"
        static let triggerKey = "ru.smltlk.triggerKey"
        static let triggerRightOnly = "ru.smltlk.triggerRightOnly"
        static let triggerDoubleTap = "ru.smltlk.triggerDoubleTap"
        static let switchHotkey = "ru.smltlk.switchHotkey"
        static let switchDoubleTap = "ru.smltlk.switchDoubleTap"
        static let switchRightOnly = "ru.smltlk.switchRightOnly"
        static let autoConvert = "ru.smltlk.autoConvert"
        static let shadowMode = "ru.smltlk.shadowMode"
        static let deniedAppsAdded = "ru.smltlk.deniedAppsAdded"
        static let deniedAppsRemoved = "ru.smltlk.deniedAppsRemoved"
        static let deniedWords = "ru.smltlk.deniedWords"
        static let alwaysConvertWords = "ru.smltlk.alwaysConvertWords"
    }

    /// Хранилище передаётся ЯВНО, без значения по умолчанию: иначе
    /// `SettingsManager()` создаёт второй экземпляр поверх живых настроек
    /// владельца, и это выглядит как безобидная опечатка вместо `shared`.
    /// Тест обязан назвать своё `UserDefaults(suiteName:)` вслух.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        migrateLegacyKeys()
    }

    /// Разовая миграция ключей донора com.ruswitcher.* -> ru.smltlk.*.
    /// Если нового ключа нет, а старый есть — переносим значение; старый ключ удаляем
    /// в любом случае, чтобы два приложения не делили один набор ключей (этап 7:
    /// RuSwitcher может быть поставлен рядом как эталон).
    private func migrateLegacyKeys() {
        let names = [
            "autoSwitch", "layout1ID", "layout2ID", "launchAtLogin", "permissionsWereGranted",
            "triggerKey", "triggerRightOnly", "triggerDoubleTap", "switchHotkey",
            "switchDoubleTap", "switchRightOnly", "autoConvert", "shadowMode",
            "deniedAppsAdded", "deniedAppsRemoved", "deniedWords", "alwaysConvertWords",
            "debugLog",
        ]
        for name in names {
            let oldKey = "com.ruswitcher.\(name)"
            let newKey = "ru.smltlk.\(name)"
            if defaults.object(forKey: newKey) == nil, let value = defaults.object(forKey: oldKey) {
                defaults.set(value, forKey: newKey)
            }
            defaults.removeObject(forKey: oldKey)
        }
    }

    // MARK: - Properties

    public var autoSwitchEnabled: Bool {
        get { defaults.object(forKey: Keys.autoSwitch) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.autoSwitch) }
    }

    /// ID первой раскладки (пустая строка = авто-определение)
    var layout1ID: String {
        get { defaults.string(forKey: Keys.layout1ID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.layout1ID) }
    }

    /// ID второй раскладки (пустая строка = авто-определение)
    var layout2ID: String {
        get { defaults.string(forKey: Keys.layout2ID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.layout2ID) }
    }

    public var launchAtLogin: Bool {
        // Дефолт — ВКЛ (этап 5): автозапуск через SMAppService из коробки.
        get { defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            let enabled = newValue
            DispatchQueue.main.async {
                self.doUpdateLoginItem(enabled: enabled)
            }
        }
    }

    /// Флаг: разрешения были ранее выданы (для определения сброса после обновления)
    public var permissionsWereGranted: Bool {
        get { defaults.bool(forKey: Keys.permissionsWereGranted) }
        set { defaults.set(newValue, forKey: Keys.permissionsWereGranted) }
    }

    // MARK: - Триггер конвертации

    /// Клавиша-триггер: "option" | "command" | "control" | "shift" | "capsLock".
    /// Дефолт — option (как было до 2.3, поведение не меняется).
    public var triggerKey: String {
        get { defaults.string(forKey: Keys.triggerKey) ?? "option" }
        set { defaults.set(newValue, forKey: Keys.triggerKey) }
    }

    /// Реагировать только на правую клавишу модификатора (для option/command/control/shift).
    public var triggerRightOnly: Bool {
        get { defaults.bool(forKey: Keys.triggerRightOnly) }
        set { defaults.set(newValue, forKey: Keys.triggerRightOnly) }
    }

    /// Двойной тап вместо одиночного.
    public var triggerDoubleTap: Bool {
        get { defaults.bool(forKey: Keys.triggerDoubleTap) }
        set { defaults.set(newValue, forKey: Keys.triggerDoubleTap) }
    }

    /// issue #14: отдельный хоткей «просто переключить раскладку» (без конверсии) —
    /// в т.ч. модификаторные комбо (Ctrl+Shift), которые системно назначить нельзя.
    /// Кодировка как у triggerKey; пустая строка — выключен (дефолт).
    public var switchHotkey: String {
        get { defaults.string(forKey: Keys.switchHotkey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.switchHotkey) }
    }

    /// issue #14: смена раскладки по ДВОЙНОМУ тапу хоткея (зеркало triggerDoubleTap).
    public var switchDoubleTap: Bool {
        get { defaults.bool(forKey: Keys.switchDoubleTap) }
        set { defaults.set(newValue, forKey: Keys.switchDoubleTap) }
    }

    /// issue #14: реагировать только на ПРАВУЮ клавишу хоткея (зеркало triggerRightOnly).
    /// Действует лишь для одиночных модификаторов; для комбо сторона не различается.
    public var switchRightOnly: Bool {
        get { defaults.bool(forKey: Keys.switchRightOnly) }
        set { defaults.set(newValue, forKey: Keys.switchRightOnly) }
    }

    /// Caps Lock как триггер требует consume-tap (чтобы подавить переключение регистра).
    var triggerIsCapsLock: Bool { triggerKey == "capsLock" }

    /// Автоматическая конвертация «на лету» (детект неправильной раскладки на границе
    /// слова). Отдельный флаг от autoSwitchEnabled (тот гейтит РУЧНОЙ триггер).
    /// Дефолт — ВКЛ (этап 5): автопереключение — основная функция приложения,
    /// назначена из коробки, как и хоткеи.
    public var autoConvert: Bool {
        get { defaults.object(forKey: Keys.autoConvert) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.autoConvert) }
    }

    /// Теневой режим (этап 7, первый день обкатки): кандидаты на автопереключение
    /// считаются в counters.json, но текст НЕ меняется. Дефолт — выкл.
    public var shadowMode: Bool {
        get { defaults.bool(forKey: Keys.shadowMode) }
        set { defaults.set(newValue, forKey: Keys.shadowMode) }
    }

    /// Приложения, где авто-конверсия выключена. Эффективный список = дефолты минус
    /// явно удалённые пользователем плюс явно добавленные. Так новые дефолты из будущих
    /// версий подхватываются автоматически, а правки пользователя сохраняются.
    var deniedApps: [String] {
        get {
            let removed = Set(defaults.stringArray(forKey: Keys.deniedAppsRemoved) ?? [])
            let added = defaults.stringArray(forKey: Keys.deniedAppsAdded) ?? []
            var result = AutoSwitchPolicy.defaultDeniedApps.filter { !removed.contains($0) }
            for a in added where !result.contains(a) { result.append(a) }
            return result
        }
        set {
            let defaultsSet = Set(AutoSwitchPolicy.defaultDeniedApps)
            let newSet = Set(newValue)
            let removed = AutoSwitchPolicy.defaultDeniedApps.filter { !newSet.contains($0) }
            let added = newValue.filter { !defaultsSet.contains($0) }
            defaults.set(removed, forKey: Keys.deniedAppsRemoved)
            defaults.set(added, forKey: Keys.deniedAppsAdded)
        }
    }

    /// Слова, которые авто-конверсия никогда не трогает.
    public var deniedWords: [String] {
        get { defaults.stringArray(forKey: Keys.deniedWords) ?? [] }
        set { defaults.set(newValue, forKey: Keys.deniedWords) }
    }
    public var deniedWordsSet: Set<String> { Set(deniedWords.map { $0.lowercased() }) }

    /// Слова, которые авто-конверсия переключает всегда (даже если их нет в словаре).
    var alwaysConvertWords: [String] {
        get { defaults.stringArray(forKey: Keys.alwaysConvertWords) ?? [] }
        set { defaults.set(newValue, forKey: Keys.alwaysConvertWords) }
    }
    var alwaysConvertWordsSet: Set<String> { Set(alwaysConvertWords.map { $0.lowercased() }) }

    // MARK: - Login Item

    private func doUpdateLoginItem(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                rslog("Login item registered")
            } else {
                try service.unregister()
                rslog("Login item unregistered")
            }
        } catch {
            rslog("Login item error: \(error)")
        }
    }

    /// Текущий статус автозапуска (может отличаться от настройки)
    public var loginItemStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }
}
