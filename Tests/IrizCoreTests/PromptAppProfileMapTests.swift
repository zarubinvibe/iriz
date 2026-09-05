// Решение «приложение → профиль промпта».
//
// Проверяется ЧИСТАЯ функция — та самая, которую зовёт `DictationController`.
// Ни приложения, ни окон, ни NSWorkspace здесь нет и быть не должно: весь
// смысл в том, что решение принимается по одной строке и ничего не помнит.
import Foundation
import Testing

@testable import IrizPrompt

@Suite("Профиль по приложению")
struct PromptAppProfileMapTests {
    private let xcode = PromptAppProfileEntry(bundleID: "com.apple.dt.Xcode", profile: .codex)
    private let mail = PromptAppProfileEntry(bundleID: "com.apple.mail", profile: .generic)

    /// Главное обещание таблицы: названное приложение получает свой профиль,
    /// а не общий.
    @Test func названноеПриложениеПолучаетСвойПрофиль() {
        let map = PromptAppProfileMap(defaultProfile: .generic, entries: [xcode, mail])

        #expect(map.profile(forBundleID: "com.apple.dt.Xcode") == .codex)
        #expect(map.profile(forBundleID: "com.apple.mail") == .generic)
    }

    /// Второе обещание, ради которого фича вообще безопасна: неизвестное
    /// приложение не ломает конвейер и не выбирает профиль наугад.
    @Test func неизвестноеПриложениеПадаетНаДефолт() {
        let map = PromptAppProfileMap(defaultProfile: .codex, entries: [mail])

        #expect(map.profile(forBundleID: "com.example.НикомуНеИзвестное") == .codex)
    }

    /// Пустая таблица — обычное состояние: у владельца до первой записи
    /// пусто, и вести себя это обязано ровно как до появления фичи.
    @Test func пустаяТаблицаОтдаётТолькоДефолт() {
        for profile in PromptRecipientProfile.allCases {
            let map = PromptAppProfileMap(defaultProfile: profile)
            #expect(map.entries.isEmpty)
            #expect(map.profile(forBundleID: "com.apple.dt.Xcode") == profile)
            #expect(map.profile(forBundleID: nil) == profile)
        }
    }

    /// Приложение может не назвать себя вовсе (нет фронтового процесса, нет
    /// идентификатора). Это не ошибка и не повод собрать другой промпт.
    @Test func отсутствующийИдентификаторРавенНеизвестному() {
        let map = PromptAppProfileMap(defaultProfile: .generic, entries: [xcode])

        #expect(map.profile(forBundleID: nil) == .generic)
        #expect(map.profile(forBundleID: "") == .generic)
        #expect(map.profile(forBundleID: "   ") == .generic)
    }

    /// macOS сравнивает идентификаторы без учёта регистра. Владелец, вписавший
    /// приложение из Finder, не должен гадать про заглавные буквы.
    @Test func регистрИдентификатораНеВажен() {
        let map = PromptAppProfileMap(defaultProfile: .generic, entries: [xcode])

        #expect(map.profile(forBundleID: "com.apple.dt.xcode") == .codex)
        #expect(map.profile(forBundleID: "COM.APPLE.DT.XCODE") == .codex)
    }

    /// Пробелы по краям приходят из вставки буфера обмена и из чужого файла.
    @Test func краяИдентификатораОбрезаются() {
        let map = PromptAppProfileMap(
            defaultProfile: .generic,
            entries: [PromptAppProfileEntry(bundleID: "  com.apple.dt.Xcode\n", profile: .codex)]
        )

        #expect(map.entries.first?.bundleID == "com.apple.dt.Xcode")
        #expect(map.profile(forBundleID: " com.apple.dt.Xcode ") == .codex)
    }

    /// Дубликат — не вторая строка, а перезапись первой НА МЕСТЕ: иначе список
    /// показывал бы две записи про одно приложение, а срабатывала бы одна.
    @Test func дубликатПерезаписываетПервуюЗаписьНаМесте() {
        let map = PromptAppProfileMap(
            defaultProfile: .generic,
            entries: [
                xcode,
                mail,
                PromptAppProfileEntry(bundleID: "COM.APPLE.DT.XCODE", profile: .generic),
            ]
        )

        #expect(map.entries.count == 2)
        #expect(map.entries.first?.bundleID == "COM.APPLE.DT.XCODE")
        #expect(map.entries.first?.profile == .generic)
        #expect(map.entries.last?.bundleID == "com.apple.mail")
        #expect(map.profile(forBundleID: "com.apple.dt.Xcode") == .generic)
    }

    /// Строкой с пробелом внутри идентификатор не бывает: это чужие данные или
    /// опечатка. Такие записи выбрасываются, а не превращаются в правило.
    @Test func мусорныеЗаписиВыбрасываются() {
        let map = PromptAppProfileMap(
            defaultProfile: .generic,
            entries: [
                PromptAppProfileEntry(bundleID: "", profile: .codex),
                PromptAppProfileEntry(bundleID: "   ", profile: .codex),
                PromptAppProfileEntry(bundleID: "com.apple dt.Xcode", profile: .codex),
                PromptAppProfileEntry(bundleID: "...", profile: .codex),
                PromptAppProfileEntry(bundleID: "com.apple\u{0}.Xcode", profile: .codex),
                PromptAppProfileEntry(
                    bundleID: String(repeating: "a", count: PromptAppProfileMap.maximumBundleIDBytes + 1),
                    profile: .codex
                ),
                xcode,
            ]
        )

        #expect(map.entries == [xcode])
    }

    @Test func списокНеРастётЗаПредел() {
        let entries = (0..<(PromptAppProfileMap.maximumEntries + 20)).map {
            PromptAppProfileEntry(bundleID: "com.example.app\($0)", profile: .codex)
        }
        let map = PromptAppProfileMap(defaultProfile: .generic, entries: entries)

        #expect(map.entries.count == PromptAppProfileMap.maximumEntries)
        #expect(map.profile(forBundleID: "com.example.app0") == .codex)
        #expect(map.profile(
            forBundleID: "com.example.app\(PromptAppProfileMap.maximumEntries + 5)"
        ) == .generic)
    }

    /// Смена дефолта не имеет права переписывать явный выбор владельца.
    @Test func сменаДефолтаНеТрогаетЯвныеЗаписи() {
        let codexDefault = PromptAppProfileMap(defaultProfile: .codex, entries: [mail])
        let genericDefault = PromptAppProfileMap(defaultProfile: .generic, entries: [mail])

        #expect(codexDefault.profile(forBundleID: "com.apple.mail") == .generic)
        #expect(genericDefault.profile(forBundleID: "com.apple.mail") == .generic)
        #expect(codexDefault.profile(forBundleID: "com.other.app") == .codex)
        #expect(genericDefault.profile(forBundleID: "com.other.app") == .generic)
    }

    /// Таблица едет в настройки JSON-ом: формат обязан переживать круг.
    @Test func записиПереживаютКругЧерезJSON() throws {
        let entries = [xcode, mail]
        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([PromptAppProfileEntry].self, from: data)

        #expect(decoded == entries)
    }

    @Test func негодныйИдентификаторОтклоняетсяОтдельно() {
        #expect(validatedPromptAppProfileBundleID("com.apple.dt.Xcode") == "com.apple.dt.Xcode")
        #expect(validatedPromptAppProfileBundleID(" com.apple.mail ") == "com.apple.mail")
        #expect(validatedPromptAppProfileBundleID("") == nil)
        #expect(validatedPromptAppProfileBundleID("два слова") == nil)
        #expect(validatedPromptAppProfileBundleID("---") == nil)
    }
}
