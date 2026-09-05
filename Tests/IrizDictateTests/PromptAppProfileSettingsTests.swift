// Хранение таблицы «приложение → профиль» и её склейка с дефолтом.
//
// Тут проверяется стык: настройки владельца превращаются в то самое чистое
// решение, которое зовёт конвейер промпта.
import Foundation
import IrizPrompt
import Testing

@testable import IrizDictate

@Suite("Профиль по приложению: настройки")
struct PromptAppProfileSettingsTests {
    /// Заводского набора нет: раздавать всем список чужих программ — то же
    /// самое, что раздавать чужие шапки документов.
    @Test func поУмолчаниюСписокПуст() {
        withIsolatedDefaults { defaults in
            let settings = DictationSettings(defaults: defaults)
            #expect(settings.promptAppProfiles.isEmpty)
            #expect(settings.promptAppProfileMap.entries.isEmpty)
        }
    }

    @Test func записиПереживаютПерезапуск() {
        withIsolatedDefaults { defaults in
            var settings = DictationSettings(defaults: defaults)
            settings.promptAppProfiles = [
                PromptAppProfileEntry(bundleID: "com.apple.dt.Xcode", profile: .codex),
                PromptAppProfileEntry(bundleID: "com.apple.mail", profile: .generic),
            ]

            settings = DictationSettings(defaults: defaults)
            #expect(settings.promptAppProfiles.count == 2)
            #expect(settings.promptAppProfiles.first?.bundleID == "com.apple.dt.Xcode")
            #expect(settings.promptAppProfiles.first?.profile == .codex)
        }
    }

    /// Мусор до диска не доезжает: чистится и на записи, и на чтении, поэтому
    /// испорченный вручную plist не превращается в правило.
    @Test func мусорНеСохраняетсяИНеЧитается() {
        withIsolatedDefaults { defaults in
            let settings = DictationSettings(defaults: defaults)
            settings.promptAppProfiles = [
                PromptAppProfileEntry(bundleID: "  ", profile: .codex),
                PromptAppProfileEntry(bundleID: "два слова", profile: .codex),
                PromptAppProfileEntry(bundleID: " com.apple.mail ", profile: .generic),
            ]

            #expect(settings.promptAppProfiles
                == [PromptAppProfileEntry(bundleID: "com.apple.mail", profile: .generic)])
        }
    }

    @Test func испорченноеЗначениеВНастройкахДаётПустойСписок() {
        withIsolatedDefaults { defaults in
            defaults.set(Data("не json".utf8), forKey: "prompt_app_profiles_v1")

            #expect(DictationSettings(defaults: defaults).promptAppProfiles.isEmpty)
        }
    }

    /// Дефолт у таблицы один и тот же, что у настройки «Исполнитель промпта»:
    /// второго места для того же смысла нет.
    @Test func дефолтБерётсяИзНастройкиИсполнителя() {
        withIsolatedDefaults { defaults in
            let settings = DictationSettings(defaults: defaults)
            settings.promptAppProfiles = [
                PromptAppProfileEntry(bundleID: "com.apple.mail", profile: .generic),
            ]

            settings.promptRecipient = .codex
            #expect(settings.promptAppProfileMap.profile(forBundleID: "com.apple.mail") == .generic)
            #expect(settings.promptAppProfileMap.profile(forBundleID: "com.other.app") == .codex)

            settings.promptRecipient = .generic
            #expect(settings.promptAppProfileMap.profile(forBundleID: "com.other.app") == .generic)
            #expect(settings.promptAppProfileMap.profile(forBundleID: nil) == .generic)
        }
    }

    private func withIsolatedDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
        let name = "smltlk-app-profiles-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { removeSuiteFile(named: name, defaults: defaults) }
        return try body(defaults)
    }
}
