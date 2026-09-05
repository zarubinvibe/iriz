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
