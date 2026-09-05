// Окно настроек: список «приложение → профиль промпта».
//
// Ключевая проверка та же, что у заготовок: настройка не осталась обещанием —
// строка, заведённая в окне, доходит до `DictationSettings` и оттуда до
// решения, которым конвейер выбирает профиль.
import CoreGraphics
import Foundation
import IrizCore
import IrizInput
import IrizPrompt
import Testing
@testable import IrizSettings
@testable import IrizDictate

@MainActor
@Suite("Настройки: профиль по приложению")
struct SettingsAppProfilesTests {
    @Test func строкаИзОкнаДоходитДоРешенияКонвейера() {
        let fixture = AppProfilesFixture()
        let model = fixture.makeModel()

        #expect(model.appProfiles.isEmpty)
        #expect(model.addAppProfile(bundleID: "com.apple.dt.Xcode", profile: .codex) == .added)
        model.promptRecipient = .generic
        #expect(model.save())

        let map = fixture.dictationSettings.promptAppProfileMap
        #expect(map.profile(forBundleID: "com.apple.dt.Xcode") == .codex)
        #expect(map.profile(forBundleID: "com.apple.mail") == .generic)
        #expect(map.profile(forBundleID: nil) == .generic)
    }

    /// Второй раз то же приложение — не вторая строка, а правка первой.
    /// Иначе в списке спорили бы две записи про одну программу.
    @Test func повторноеДобавлениеПравитСтрокуНаМесте() {
        let model = AppProfilesFixture().makeModel()

        #expect(model.addAppProfile(bundleID: "com.apple.dt.Xcode", profile: .generic) == .added)
        #expect(model.addAppProfile(bundleID: "COM.APPLE.DT.XCODE", profile: .codex) == .updated)

        #expect(model.appProfiles.count == 1)
        #expect(model.appProfiles.first?.profile == .codex)
    }

    @Test func негодныйИдентификаторСтрокуНеЗаводит() {
        let model = AppProfilesFixture().makeModel()

        #expect(model.addAppProfile(bundleID: "  ", profile: .codex) == .invalidBundleID)
        #expect(model.addAppProfile(bundleID: "два слова", profile: .codex) == .invalidBundleID)
        #expect(model.appProfiles.isEmpty)
    }

    @Test func списокНеПереполняется() {
        let model = AppProfilesFixture().makeModel()

        for index in 0..<PromptAppProfileMap.maximumEntries {
            #expect(model.addAppProfile(bundleID: "com.example.app\(index)", profile: .codex) == .added)
        }
        #expect(model.addAppProfile(bundleID: "com.example.extra", profile: .codex) == .listFull)
        #expect(model.appProfiles.count == PromptAppProfileMap.maximumEntries)
    }

    @Test func сменаПрофиляИУдалениеДоходятДоНастроек() {
        let fixture = AppProfilesFixture()
        let model = fixture.makeModel()

        model.addAppProfile(bundleID: "com.apple.mail", profile: .codex)
        model.updateAppProfile(at: 0, profile: .generic)
        #expect(model.save())
        #expect(fixture.dictationSettings.promptAppProfiles
            == [PromptAppProfileEntry(bundleID: "com.apple.mail", profile: .generic)])

        model.removeAppProfile(at: 0)
        #expect(model.save())
        #expect(fixture.dictationSettings.promptAppProfiles.isEmpty)
    }

    /// Сброс к заводским обязан убирать список: там имена программ владельца,
    /// и «сбросил, а они остались» — это не сброс.
    @Test func сбросУбираетСписок() {
        let fixture = AppProfilesFixture()
        let model = fixture.makeModel()

        model.addAppProfile(bundleID: "com.apple.dt.Xcode", profile: .codex)
        #expect(model.save())

        #expect(model.resetToFactoryDefaults())
        #expect(model.appProfiles.isEmpty)
        #expect(fixture.dictationSettings.promptAppProfiles.isEmpty)
        #expect(fixture.dictationSettings.promptAppProfileMap
            .profile(forBundleID: "com.apple.dt.Xcode") == .codex)
    }
}

@MainActor
private final class AppProfilesFixture {
    let defaults: UserDefaults
    let dictationSettings: DictationSettings
    let layoutHotkeySettings: SettingsManager
    var mode: LayoutMode = .fixing
    var launchAtLogin = true
    private let suiteName: String

    init() {
        suiteName = "ru.smltlk.settings.appprofiles.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        dictationSettings = DictationSettings(defaults: defaults)
        layoutHotkeySettings = SettingsManager(defaults: defaults)
    }

    /// Домен сносится ПОСЛЕ работы: иначе каждый прогон оставлял бы по plist
    /// в ~/Library/Preferences владельца.
    deinit {
        let manager = FileManager()
        let url = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? manager.removeItem(at: url)
    }

    func makeModel() -> SettingsModel {
        SettingsModel(
            dictationSettings: dictationSettings,
            layoutSettings: LayoutSettingsAccess(
                readMode: { self.mode },
                writeMode: { self.mode = $0 },
                readLaunchAtLogin: { self.launchAtLogin },
                writeLaunchAtLogin: { self.launchAtLogin = $0 }
            ),
            layoutHotkeys: .settings(layoutHotkeySettings),
            codexDetector: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
    }
}
