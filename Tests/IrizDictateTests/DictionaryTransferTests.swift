// Экспорт и импорт словаря замен и заготовок.
//
// Три обещания под проверкой: круг «выгрузил → загрузил» возвращает то же
// самое; негодный файл отклоняется ВСЛУХ и целиком; столкновение имён решается
// в пользу файла, а записей не удаляет.
import Foundation
import Testing

@testable import IrizDictate

private let образецЗамен = [
    TranscriptCorrection(source: "смолток", replacement: "smltlk"),
    TranscriptCorrection(source: "эцп", replacement: "ЭЦП"),
]

private let образецЗаготовок = [
    DictationSnippet(trigger: "шапка иска",
                     body: "В Верховный суд\nот ИП Иванова И. И."),
]

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

// MARK: - Круг

@Suite("Словарь файлом: круг")
struct DictionaryTransferRoundTripTests {
    @Test func выгрузилЗагрузилПолучилТоЖе() throws {
        let data = DictionaryTransfer.encode(corrections: образецЗамен, snippets: образецЗаготовок)
        let document = try DictionaryTransfer.decode(data)

        #expect(document.corrections == образецЗамен)
        #expect(document.snippets == образецЗаготовок)
    }

    /// Байты повторяемы: два экспорта одного и того же набора совпадают.
    /// Иначе бэкап нельзя ни сравнить, ни положить под контроль версий.
    @Test func повторныйЭкспортДаётТеЖеБайты() {
        let first = DictionaryTransfer.encode(corrections: образецЗамен, snippets: образецЗаготовок)
        let second = DictionaryTransfer.encode(corrections: образецЗамен, snippets: образецЗаготовок)
        #expect(first == second)
    }

    /// Файл читаемый: кириллица буквами, а не \uXXXX, и переносы строк внутри
    /// тела заготовки экранируются, а не рвут JSON.
    @Test func файлЧитаетсяГлазами() throws {
        let text = try #require(
            String(data: DictionaryTransfer.encode(corrections: образецЗамен,
                                                   snippets: образецЗаготовок),
                   encoding: .utf8)
        )
        #expect(text.contains("\"ЭЦП\""))
        #expect(text.contains("smltlk-dictionary"))
        #expect(text.contains("\"trigger\""))
        #expect(!text.contains("\\u04"))
        #expect(text.contains("\n  \"corrections\""))
    }

    /// Экспорт отдаёт то, что реально работает: мусор из редактора в бэкап
    /// не попадает.
    @Test func экспортОтдаётНормализованное() throws {
        let data = DictionaryTransfer.encode(
            corrections: [TranscriptCorrection(source: "  ", replacement: "пусто"),
                          TranscriptCorrection(source: " эцп ", replacement: " ЭЦП ")],
            snippets: [DictationSnippet(trigger: "фраза", body: " ")]
        )
        let document = try DictionaryTransfer.decode(data)
        #expect(document.corrections == [TranscriptCorrection(source: "эцп", replacement: "ЭЦП")])
        #expect(document.snippets.isEmpty)
    }

    /// Только заготовки без словаря — законный файл.
    @Test func файлТолькоСЗаготовкамиГодится() throws {
        let data = DictionaryTransfer.encode(corrections: [], snippets: образецЗаготовок)
        #expect(try DictionaryTransfer.decode(data).snippets == образецЗаготовок)
    }
}

// MARK: - Отказы

@Suite("Словарь файлом: отказы")
struct DictionaryTransferRefusalTests {
    private func отказ(_ data: Data) -> DictionaryTransferError? {
        do {
            _ = try DictionaryTransfer.decode(data)
            return nil
        } catch let error as DictionaryTransferError {
            return error
        } catch {
            return nil
        }
    }

    @Test func неJSONОтклоняется() {
        #expect(отказ(Data("не json вовсе".utf8)) == .notJSON)
        #expect(отказ(Data()) == .notJSON)
    }

    @Test func чужойФайлОтклоняется() {
        #expect(отказ(json(["version": 1, "corrections": []])) == .foreignFile)
        #expect(отказ(json(["smltlk": "что-то другое", "version": 1])) == .foreignFile)
        #expect(отказ(Data("[]".utf8)) == .foreignFile)
    }

    @Test func файлИзБудущегоОтклоняется() {
        #expect(отказ(json(["smltlk": "smltlk-dictionary", "version": 99])) == .futureFormat(99))
        #expect(отказ(json(["smltlk": "smltlk-dictionary", "version": "один"]))
                == .wrongShape(field: "version"))
    }

    @Test func полеНеТогоТипаОтклоняется() {
        #expect(отказ(json(["smltlk": "smltlk-dictionary",
                            "version": 1,
                            "corrections": "строка"])) == .wrongShape(field: "corrections"))
        #expect(отказ(json(["smltlk": "smltlk-dictionary",
                            "version": 1,
                            "snippets": 17])) == .wrongShape(field: "snippets"))
    }

    /// Главный отказ этапа: одна негодная строка валит ВЕСЬ файл и называет
    /// номер. Частичный импорт бэкапа хуже отказа — владелец уйдёт уверенным,
    /// что словарь восстановлен, а на месте будет половина.
    @Test func негоднаяЗаписьВалитВесьФайлИНазываетНомер() {
        let файл = json([
            "smltlk": "smltlk-dictionary",
            "version": 1,
            "corrections": [
                ["source": "эцп", "replacement": "ЭЦП"],
                ["source": "пусто", "replacement": "   "],
            ],
        ])
        let error = отказ(файл)
        #expect(error == .badCorrection(index: 1, reason: "правая часть замены пуста"))
        #expect(error?.message.contains("№2") == true)
        #expect(error?.message.contains("Ничего не импортировано") == true)
    }

    @Test func записьБезПолейОтклоняется() {
        #expect(отказ(json(["smltlk": "smltlk-dictionary",
                            "version": 1,
                            "corrections": [["source": "эцп"]]])
                ) == .badCorrection(index: 0,
                                    reason: "нет пары «source» и «replacement» из двух строк"))
        #expect(отказ(json(["smltlk": "smltlk-dictionary",
                            "version": 1,
                            "snippets": [["trigger": "фраза", "body": 5]]])
                ) == .badSnippet(index: 0,
                                 reason: "нет пары «trigger» и «body» из двух строк"))
    }

    @Test func негоднаяЗаготовкаНазываетПричину() {
        #expect(отказ(json(["smltlk": "smltlk-dictionary",
                            "version": 1,
                            "snippets": [["trigger": "...", "body": "текст"]]])
                ) == .badSnippet(index: 0,
                                 reason: "во фразе нет ни буквы, ни цифры — такую заготовку нечем поймать в речи"))
    }

    /// Пустой документ — тоже отказ. Именно так выглядит «импортировал и
    /// молча ничего не произошло», ради чего этот гейт и написан.
    @Test func пустойДокументОтклоняется() {
        #expect(отказ(json(["smltlk": "smltlk-dictionary", "version": 1])) == .emptyDocument)
        #expect(отказ(json(["smltlk": "smltlk-dictionary",
                            "version": 1,
                            "corrections": [],
                            "snippets": []])) == .emptyDocument)
    }

    @Test func переборПоЧислуЗаписейОтклоняется() {
        let rows = (0..<(MAX_TRANSCRIPT_CORRECTIONS + 1)).map {
            ["source": "слово\($0)", "replacement": "З"]
        }
        #expect(отказ(json(["smltlk": "smltlk-dictionary", "version": 1, "corrections": rows])
                ) == .tooManyCorrections(MAX_TRANSCRIPT_CORRECTIONS + 1))

        let snippetRows = (0..<(MAX_DICTATION_SNIPPETS + 1)).map {
            ["trigger": "фраза\($0)", "body": "т"]
        }
        #expect(отказ(json(["smltlk": "smltlk-dictionary", "version": 1, "snippets": snippetRows])
                ) == .tooManySnippets(MAX_DICTATION_SNIPPETS + 1))
    }

    @Test func укаждогоОтказаЕстьВнятныйТекст() {
        let errors: [DictionaryTransferError] = [
            .notJSON, .foreignFile, .futureFormat(9), .wrongShape(field: "corrections"),
            .badCorrection(index: 0, reason: "почему"), .badSnippet(index: 0, reason: "почему"),
            .emptyDocument, .tooManyCorrections(1), .tooManySnippets(1),
            .correctionLimitExceeded(total: 1), .snippetLimitExceeded(total: 1),
        ]
        for error in errors {
            #expect(error.message.count > 20, "отказ без внятного текста: \(error)")
        }
    }
}

// MARK: - Слияние и столкновение имён

@Suite("Словарь файлом: слияние")
struct DictionaryTransferMergeTests {
    /// Столкновение имён: побеждает файл. Иначе восстановление бэкапа не
    /// восстанавливает ничего и молчит об этом.
    @Test func приСовпаденииФразыПобеждаетФайл() throws {
        let document = DictionaryTransferDocument(
            corrections: [TranscriptCorrection(source: "эцп", replacement: "ИЗ ФАЙЛА")],
            snippets: [DictationSnippet(trigger: "шапка иска", body: "ИЗ ФАЙЛА")]
        )
        let outcome = try DictionaryTransfer.merge(
            document,
            intoCorrections: [TranscriptCorrection(source: "ЭЦП", replacement: "местная")],
            snippets: [DictationSnippet(trigger: "Шапка  Иска", body: "местная")]
        )

        #expect(outcome.corrections == [TranscriptCorrection(source: "эцп", replacement: "ИЗ ФАЙЛА")])
        #expect(outcome.snippets == [DictationSnippet(trigger: "шапка иска", body: "ИЗ ФАЙЛА")])
        #expect(outcome.updatedCorrections == 1)
        #expect(outcome.addedCorrections == 0)
        #expect(outcome.updatedSnippets == 1)
        #expect(outcome.summary.contains("перезаписано"))
    }

    /// Слияние ничего не удаляет: местная запись, которой нет в файле,
    /// остаётся. Полная замена достижима руками — очистить список и
    /// импортировать, — и это осознанное разрушительное действие.
    @Test func слияниеНичегоНеУдаляет() throws {
        let outcome = try DictionaryTransfer.merge(
            DictionaryTransferDocument(
                corrections: [TranscriptCorrection(source: "новое", replacement: "НОВОЕ")],
                snippets: []
            ),
            intoCorrections: [TranscriptCorrection(source: "местное", replacement: "МЕСТНОЕ")],
            snippets: [DictationSnippet(trigger: "местная фраза", body: "тело")]
        )

        #expect(outcome.corrections == [
            TranscriptCorrection(source: "местное", replacement: "МЕСТНОЕ"),
            TranscriptCorrection(source: "новое", replacement: "НОВОЕ"),
        ])
        #expect(outcome.snippets == [DictationSnippet(trigger: "местная фраза", body: "тело")])
        #expect(outcome.addedCorrections == 1)
        #expect(outcome.updatedCorrections == 0)
        #expect(outcome.summary == "Импорт: замен добавлено 1.")
    }

    @Test func повторныйИмпортТогоЖеФайлаНичегоНеМеняет() throws {
        let document = DictionaryTransferDocument(corrections: образецЗамен,
                                                  snippets: образецЗаготовок)
        let first = try DictionaryTransfer.merge(document, intoCorrections: [], snippets: [])
        let second = try DictionaryTransfer.merge(document,
                                                  intoCorrections: first.corrections,
                                                  snippets: first.snippets)

        #expect(second.corrections == first.corrections)
        #expect(second.snippets == first.snippets)
        #expect(second.addedCorrections == 0)
        #expect(second.updatedCorrections == образецЗамен.count)
    }

    /// Предел проверяется ДО слияния: иначе нормализация обрезала бы хвост
    /// молча, а отчёт «добавлено N» соврал бы.
    @Test func переборПослеСлиянияОтклоняетсяСЧислом() {
        let existing = (0..<MAX_TRANSCRIPT_CORRECTIONS).map {
            TranscriptCorrection(source: "местное\($0)", replacement: "М")
        }
        let document = DictionaryTransferDocument(
            corrections: [TranscriptCorrection(source: "лишнее", replacement: "Л")],
            snippets: []
        )

        #expect(throws: DictionaryTransferError.correctionLimitExceeded(
            total: MAX_TRANSCRIPT_CORRECTIONS + 1
        )) {
            try DictionaryTransfer.merge(document, intoCorrections: existing, snippets: [])
        }
    }

    /// Круг целиком, как им пользуются: выгрузил, снёс настройки, загрузил —
    /// и те же замены снова срабатывают на том же тексте.
    @Test func полныйКругЧерезФайлВосстанавливаетПоведение() throws {
        let было = processedDictationText(rawTranscript: "смолток и шапка иска",
                                          corrections: образецЗамен,
                                          snippets: образецЗаготовок)

        let data = DictionaryTransfer.encode(corrections: образецЗамен, snippets: образецЗаготовок)
        let restored = try DictionaryTransfer.merge(try DictionaryTransfer.decode(data),
                                                    intoCorrections: [],
                                                    snippets: [])
        let стало = processedDictationText(rawTranscript: "смолток и шапка иска",
                                           corrections: restored.corrections,
                                           snippets: restored.snippets)

        #expect(стало == было)
        #expect(стало.appliedCorrectionCount == 1)
        #expect(стало.appliedSnippetCount == 1)
    }
}
