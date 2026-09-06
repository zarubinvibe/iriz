// Окно настроек: редактор заготовок и кнопки «Экспортировать» / «Импортировать».
//
// Ключевая проверка — что настройка не осталась обещанием: заготовка, заведённая
// в окне, доходит до `DictationSettings` и оттуда до конвейера диктовки.
import CoreGraphics
import Foundation
import IrizCore
import IrizInput
import Testing
@testable import IrizSettings
@testable import IrizDictate

@MainActor
@Suite("Настройки: заготовки")
struct SettingsSnippetsTests {
    @Test func заготовкаИзОкнаДоходитДоНастроекИКонвейера() {
        let fixture = TransferFixture()
        let model = fixture.makeModel()

        #expect(model.snippets.isEmpty)
        model.addSnippet(trigger: "шапка иска", body: "В Верховный суд\nот ИП Иванова")
        #expect(model.save())

        let stored = fixture.dictationSettings.snippets
        #expect(stored == [DictationSnippet(trigger: "шапка иска",
                                            body: "В Верховный суд\nот ИП Иванова")])

        let processed = processedDictationText(rawTranscript: "шапка иска дальше",
                                               corrections: fixture.dictationSettings.transcriptCorrections,
                                               snippets: stored)
        #expect(processed.text.hasPrefix("В Верховный суд"))
        #expect(processed.appliedSnippetCount == 1)
    }

    @Test func полупустаяЗаготовкаНеДаётСохранить() {
        let model = TransferFixture().makeModel()

        model.addSnippet(trigger: "шапка", body: "")
        #expect(model.validationMessage == "У заготовки нужны и фраза, и текст.")
        #expect(!model.canSave)
        #expect(!model.save())

        model.updateSnippet(at: 0, body: "текст")
        #expect(model.validationMessage == nil)
        #expect(model.save())
    }

    @Test func фразаБезБуквыИЦифрыНеДаётСохранить() {
        let model = TransferFixture().makeModel()
        model.addSnippet(trigger: "...", body: "текст")
        #expect(model.validationMessage?.contains("ни буквы, ни цифры") == true)
        #expect(!model.canSave)
    }

    @Test func удалениеЗаготовкиДоходитДоДиска() {
        let fixture = TransferFixture()
        let model = fixture.makeModel()

        // Новая заготовка встаёт СВЕРХУ (решение владельца 06.09.2026), поэтому
        // после двух добавлений первой в списке лежит «вторая фраза».
        model.addSnippet(trigger: "первая фраза", body: "тело")
        model.addSnippet(trigger: "вторая фраза", body: "тело")
        #expect(model.save())
        #expect(fixture.dictationSettings.snippets.map(\.trigger)
                == ["вторая фраза", "первая фраза"])

        model.removeSnippet(at: 0)
        #expect(model.save())
        #expect(fixture.dictationSettings.snippets
                == [DictationSnippet(trigger: "первая фраза", body: "тело")])
    }

    @Test func сбросКЗаводскимОчищаетЗаготовки() {
        let fixture = TransferFixture()
        let model = fixture.makeModel()

        model.addSnippet(trigger: "шапка иска", body: "тело")
        #expect(model.save())

        #expect(model.resetToFactoryDefaults())
        #expect(model.snippets.isEmpty)
        #expect(fixture.dictationSettings.snippets.isEmpty)
    }
}

@MainActor
@Suite("Настройки: словарь файлом")
struct SettingsDictionaryTransferTests {
    /// Круг целиком через окно: выгрузили, снесли настройки, загрузили в чистое
    /// окно — словарь и заготовки на месте.
    @Test func кругЧерезФайлВосстанавливаетСловарьИЗаготовки() throws {
        let source = TransferFixture()
        let sourceModel = source.makeModel()
        sourceModel.corrections = [TranscriptCorrection(source: "смолток", replacement: "smltlk")]
        sourceModel.addSnippet(trigger: "шапка иска", body: "В Верховный суд")
        #expect(sourceModel.save())

        let data = sourceModel.exportedDictionaryData()

        let empty = TransferFixture()
        let emptyModel = empty.makeModel()
        emptyModel.corrections = []
        #expect(emptyModel.save())

        let summary = try emptyModel.importDictionaryData(data)
        #expect(summary.contains("добавлено"))
        #expect(emptyModel.save())

        #expect(empty.dictationSettings.transcriptCorrections
                == [TranscriptCorrection(source: "смолток", replacement: "smltlk")])
        #expect(empty.dictationSettings.snippets
                == [DictationSnippet(trigger: "шапка иска", body: "В Верховный суд")])
    }

    /// Выгружается то, что в окне сейчас, а не то, что на диске: иначе кнопка
    /// врала бы про только что набранную запись.
    @Test func экспортБерётНесохранённоеСостояниеОкна() throws {
        let model = TransferFixture().makeModel()
        model.corrections = [TranscriptCorrection(source: "новое", replacement: "НОВОЕ")]

        let document = try DictionaryTransfer.decode(model.exportedDictionaryData())
        #expect(document.corrections == [TranscriptCorrection(source: "новое", replacement: "НОВОЕ")])
    }

    /// Негодный файл не трогает окно вообще: ни половины, ни очистки.
    @Test func негодныйФайлНеМеняетОкноИНазываетПричину() {
        let model = TransferFixture().makeModel()
        model.corrections = [TranscriptCorrection(source: "местное", replacement: "МЕСТНОЕ")]
        model.addSnippet(trigger: "местная фраза", body: "тело")

        #expect(throws: DictionaryTransferError.notJSON) {
            try model.importDictionaryData(Data("совсем не json".utf8))
        }
        #expect(model.corrections == [TranscriptCorrection(source: "местное", replacement: "МЕСТНОЕ")])
        #expect(model.snippets == [DictationSnippet(trigger: "местная фраза", body: "тело")])
    }

    /// Импорт правит только окно. На диск он попадает общей кнопкой
    /// «Сохранить» — значит, ошибочный импорт закрывается без последствий.
    @Test func импортБезСохраненияДоДискаНеДоходит() throws {
        let fixture = TransferFixture()
        let model = fixture.makeModel()
        model.corrections = []
        #expect(model.save())

        let data = DictionaryTransfer.encode(
            corrections: [TranscriptCorrection(source: "смолток", replacement: "smltlk")],
            snippets: []
        )
        _ = try model.importDictionaryData(data)

        #expect(model.corrections.count == 1)
        #expect(fixture.dictationSettings.transcriptCorrections.isEmpty)
    }

    @Test func столкновениеИмёнРешаетсяВПользуФайлаИНазываетсяЧислом() throws {
        let model = TransferFixture().makeModel()
        model.corrections = [TranscriptCorrection(source: "эцп", replacement: "местная")]

        let data = DictionaryTransfer.encode(
            corrections: [TranscriptCorrection(source: "ЭЦП", replacement: "ИЗ ФАЙЛА")],
            snippets: []
        )
        let summary = try model.importDictionaryData(data)

        #expect(model.corrections == [TranscriptCorrection(source: "ЭЦП", replacement: "ИЗ ФАЙЛА")])
        #expect(summary == "Импорт: замен перезаписано 1.")
    }
}

@MainActor
private final class TransferFixture {
    let defaults: UserDefaults
    let dictationSettings: DictationSettings
    let layoutHotkeySettings: SettingsManager
    var mode: LayoutMode = .fixing
    var launchAtLogin = true
    private let suiteName: String

    init() {
        suiteName = "ru.smltlk.settings.transfer.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        dictationSettings = DictationSettings(defaults: defaults)
        layoutHotkeySettings = SettingsManager(defaults: defaults)
    }

    /// Домен настроек сносится ПОСЛЕ работы, а не только до неё: иначе каждый
    /// прогон оставлял бы по plist в ~/Library/Preferences владельца.
    /// Свой FileManager и только строка имени — в nonisolated deinit больше
    /// ничего трогать нельзя.
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
