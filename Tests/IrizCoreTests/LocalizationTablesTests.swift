// Проба живых таблиц перевода.
//
// Ворота `scripts/translation_gate.sh` судят ФАЙЛЫ: все ключи на месте, ничего
// не осталось по-русски. Здесь судится другое - что приложение эти файлы
// действительно находит и читает. Полная таблица, которую никто не открыл,
// выглядит на экране ровно как отсутствующая.
import Foundation
import Testing

@testable import IrizCore

@Suite("Таблицы перевода")
struct LocalizationTablesTests {
    @Test("перенесённое приложение читает английский и китайский из Contents/Resources")
    func packagedAppReadsItsOwnLocalizationBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iriz-localization-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("relocated/iriz.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleIdentifier": "test.iriz.localized",
                                      "CFBundlePackageType": "APPL",
                                      "CFBundleExecutable": "iriz"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let original = try #require(irizResourceBundle())
        let copied = resources.appendingPathComponent("IrizApp_IrizCore.bundle", isDirectory: true)
        try FileManager.default.copyItem(at: original.bundleURL, to: copied)
        let host = try #require(Bundle(url: app))
        let relocated = try #require(irizResourceBundle(in: host))
        #expect(relocated.bundleURL.standardizedFileURL.path == copied.standardizedFileURL.path)
        let key = "firstrun.welcome.title"
        for language in [IrizLanguage.en, .zh] {
            let expected = try #require(irizLocalizationBundle(for: language))
                .localizedString(forKey: key, value: nil, table: nil)
            #expect(expected != key)
            let table = try #require(irizLocalizationBundle(for: language, resources: relocated))
            #expect(table.localizedString(forKey: key, value: nil, table: nil) == expected)
        }
    }

    @Test("отсутствующий ресурсный bundle возвращает nil без абсолютного build fallback")
    func absentPackagedResourcesDoNotCrash() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iriz-no-localization-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("iriz.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.iriz.missing", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let host = try #require(Bundle(url: contents.deletingLastPathComponent()))
        #expect(irizResourceBundle(in: host) == nil)
    }

    private func table(_ language: IrizLanguage) -> Bundle? {
        irizLocalizationBundle(for: language)
    }

    @Test("английская таблица лежит в бандле и читается")
    func английскаяТаблицаЧитается() throws {
        let bundle = try #require(table(.en))
        let value = bundle.localizedString(forKey: "firstrun.welcome.title", value: "", table: nil)
        #expect(!value.isEmpty)
        #expect(value.range(of: "[а-яА-Я]", options: .regularExpression) == nil)
    }

    @Test("китайская таблица лежит в бандле и читается")
    func китайскаяТаблицаЧитается() throws {
        let bundle = try #require(table(.zh))
        let value = bundle.localizedString(forKey: "firstrun.welcome.title", value: "", table: nil)
        #expect(!value.isEmpty)
        #expect(value.range(of: "[а-яА-Я]", options: .regularExpression) == nil)
    }

    @Test("китайское знакомство просит говорить по-русски для перевода в английский")
    func китайскийПереводНазываетОбаЯзыка() throws {
        let bundle = try #require(table(.zh))
        #expect(bundle.localizedString(forKey: "firstrun.translate.title", value: "", table: nil)
                == "说俄语，出英文")
        #expect(bundle.localizedString(forKey: "firstrun.translatePressKey", value: "", table: nil)
                == "按一下这个键，用俄语说句话")
    }

    @Test("имя продукта не переводится ни в одной таблице")
    func имяПродуктаНеПереводится() throws {
        // «iriz» строчными и без склонения - решение владельца. Переводчик,
        // не знающий этого, однажды напишет «Ириз» или «Iriz».
        for language in [IrizLanguage.en, .zh] {
            let bundle = try #require(table(language))
            let value = bundle.localizedString(forKey: "firstrun.accessibility.note",
                                               value: "", table: nil)
            #expect(!value.contains("Iriz"))
            #expect(!value.contains("IRIZ"))
        }
    }

    @Test("русский остаётся оригиналом, а не переводом")
    func русскийОстаётсяОригиналом() {
        // Продукт написан по-русски, и в коде стоит русская строка. Таблицы
        // для русского нет намеренно: перевод оригинала на язык оригинала
        // разъедется с кодом на первой же правке.
        #expect(irizResolvedLanguage(choice: .ru, systemPreferred: ["en"]) == .ru)
    }
}
