import Foundation
import Testing

@testable import IrizCore

@Suite("настройки переезжают из домена прежнего бандла")
struct BundleMigrationTests {
    private func suite(_ name: String) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Владелец согласился выдать разрешения заново, но терять сочетания клавиш,
    /// словарь замен и список приложений он не соглашался.
    @Test func ownersSettingsSurviveTheBundleRename() throws {
        let id = UUID().uuidString
        let legacyName = "ru.iriz.tests.legacy.\(id)"
        let currentName = "ru.iriz.tests.current.\(id)"
        let legacy = try suite(legacyName)
        let current = try suite(currentName)
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            current.removePersistentDomain(forName: currentName)
        }

        legacy.set(55, forKey: "ru.smltlk.dictationHotkeyKeyCode")
        legacy.set(["чёрный": "черный"], forKey: "ru.smltlk.transcriptCorrections")
        legacy.set("не наше", forKey: "com.apple.something")

        let moved = migrateDefaultsFromLegacyBundle(legacy: legacy, into: current)

        #expect(moved == 2)
        #expect(current.integer(forKey: "ru.smltlk.dictationHotkeyKeyCode") == 55)
        #expect(current.dictionary(forKey: "ru.smltlk.transcriptCorrections") as? [String: String]
                == ["чёрный": "черный"])
        #expect(current.object(forKey: "com.apple.something") == nil, "чужие ключи не наше дело")
        #expect(current.bool(forKey: IRIZ_DEFAULTS_MIGRATION_KEY))
    }

    /// Второй запуск ничего не трогает: иначе прежняя сборка рядом однажды
    /// затрёт свежие правки старыми значениями.
    @Test func migrationRunsOnlyOnce() throws {
        let id = UUID().uuidString
        let legacyName = "ru.iriz.tests.legacy.\(id)"
        let currentName = "ru.iriz.tests.current.\(id)"
        let legacy = try suite(legacyName)
        let current = try suite(currentName)
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            current.removePersistentDomain(forName: currentName)
        }

        legacy.set(55, forKey: "ru.smltlk.dictationHotkeyKeyCode")
        migrateDefaultsFromLegacyBundle(legacy: legacy, into: current)
        current.set(99, forKey: "ru.smltlk.dictationHotkeyKeyCode")

        let again = migrateDefaultsFromLegacyBundle(legacy: legacy, into: current)

        #expect(again == 0)
        #expect(current.integer(forKey: "ru.smltlk.dictationHotkeyKeyCode") == 99,
                "свежее значение затёрто старым")
    }

    /// Уже заданное в новом домене старым не перебивается даже в первый раз.
    @Test func existingValuesWin() throws {
        let id = UUID().uuidString
        let legacyName = "ru.iriz.tests.legacy.\(id)"
        let currentName = "ru.iriz.tests.current.\(id)"
        let legacy = try suite(legacyName)
        let current = try suite(currentName)
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            current.removePersistentDomain(forName: currentName)
        }

        legacy.set(55, forKey: "ru.smltlk.dictationHotkeyKeyCode")
        current.set(99, forKey: "ru.smltlk.dictationHotkeyKeyCode")

        migrateDefaultsFromLegacyBundle(legacy: legacy, into: current)

        #expect(current.integer(forKey: "ru.smltlk.dictationHotkeyKeyCode") == 99)
    }

    /// Чистая установка: старого домена нет вовсе, и это не ошибка.
    @Test func missingLegacyDomainIsNotAnError() throws {
        let id = UUID().uuidString
        let currentName = "ru.iriz.tests.current.\(id)"
        let current = try suite(currentName)
        defer { current.removePersistentDomain(forName: currentName) }
        let moved = migrateDefaultsFromLegacyBundle(legacy: nil, into: current)
        #expect(moved == 0)
        #expect(current.bool(forKey: IRIZ_DEFAULTS_MIGRATION_KEY), "отметка обязана встать и без донора")
    }
}
