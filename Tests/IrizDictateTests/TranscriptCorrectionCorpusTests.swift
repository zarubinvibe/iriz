// Синтетическая корпусная проверка проходит через настоящий
// `processedDictationText`, а не через копию его логики.
import Foundation
import Testing

@testable import IrizDictate

// MARK: - Синтетический корпус

struct SyntheticCorpusEntry: Decodable {
    let id: String
    let synthetic: Bool
    let text: String
    let expectedText: String
    let expectedAppliedCorrections: Int
}

enum SyntheticCorrectionCorpus {
    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/transcripts.json")

    static let entries: [SyntheticCorpusEntry] = {
        guard let data = try? Data(contentsOf: fixtureURL),
              let entries = try? JSONDecoder().decode([SyntheticCorpusEntry].self, from: data)
        else { return [] }
        return entries
    }()

    static let processed: [DictationTextProcessingResult] = entries.map {
        processedDictationText(rawTranscript: $0.text,
                               corrections: defaultTranscriptCorrections)
    }
}

private func applyDefaults(_ text: String) -> String {
    processedDictationText(rawTranscript: text,
                           corrections: defaultTranscriptCorrections).text
}

@Suite("Заводской словарь: синтетический корпус", .serialized)
struct DefaultCorrectionsSyntheticCorpusTests {
    @Test func корпусИОжиданияПолны() {
        let entries = SyntheticCorrectionCorpus.entries
        let processed = SyntheticCorrectionCorpus.processed

        #expect(entries.count == 12, "синтетическая fixture не прочиталась")
        #expect(entries.allSatisfy { $0.synthetic })
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(entries.contains { $0.id.hasPrefix("synthetic-correction-") })
        #expect(entries.contains { $0.id.hasPrefix("synthetic-trap-") })
        #expect(entries.contains { $0.id.hasPrefix("synthetic-idempotent-") })
        #expect(processed.count == entries.count)

        for (entry, result) in zip(entries, processed) {
            #expect(result.text == entry.expectedText, "неверный результат для \(entry.id)")
            #expect(result.appliedCorrectionCount == entry.expectedAppliedCorrections,
                    "неверное число замен для \(entry.id)")
        }
    }

    @Test func словарьПереживаетВалидациюИХранилище() {
        // Заводской словарь уезжает в чужие руки внутри бинарника, поэтому он
        // закреплён поимённо: любая новая запись обязана пройти через этот список
        // и через глаза человека. Так личное имя не попадёт в раздачу молча.
        //
        // Проверка списком, а не запретом подстроки: тест с запрещённым словом
        // внутри сам становится тем, что гейт публикации обязан ловить.
        let shippedSources = defaultTranscriptCorrections.map(\.source)
        #expect(shippedSources == [
            "smalltalk", "смолток", "ирида", "ириду", "ириды",
            "клод", "клода", "кими",
            "гидхаб", "нещатно", "промп",
            "эцп", "омвд", "гибдд", "мвд", "ндс", "ип",
        ])
        #expect(normalizedTranscriptCorrections(defaultTranscriptCorrections)
                == defaultTranscriptCorrections)

        let name = "smltlk-dictionary-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { removeSuiteFile(named: name, defaults: defaults) }

        let settings = DictationSettings(defaults: defaults)
        #expect(settings.transcriptCorrections == defaultTranscriptCorrections)

        settings.transcriptCorrections = []
        let afterRestart = DictationSettings(defaults: defaults)
        #expect(afterRestart.transcriptCorrections.isEmpty)

        afterRestart.transcriptCorrections = defaultTranscriptCorrections
        #expect(afterRestart.transcriptCorrections == defaultTranscriptCorrections)
    }

    @Test func ужеВерныеАббревиатурыИдемпотентны() {
        let result = processedDictationText(rawTranscript: "ЭЦП и ГИБДД отмечены на синей схеме.",
                                           corrections: defaultTranscriptCorrections)
        #expect(result.text == "ЭЦП и ГИБДД отмечены на синей схеме.")
        #expect(result.appliedCorrectionCount == 2)
    }
}

// MARK: - Границы и омографы

@Suite("Ловушки словаря замен", .serialized)
struct DefaultCorrectionsTrapTests {
    @Test func точнаяФормаНеЗадеваетПадежи() {
        for form in ["промпт", "промпта", "промптом", "промптов", "Промпт", "промптами"] {
            let sentence = "Фиолетовая карточка хранит \(form) отдельно."
            #expect(applyDefaults(sentence) == sentence)
        }
        #expect(applyDefaults("Фиолетовая карточка хранит промп отдельно.")
                == "Фиолетовая карточка хранит промпт отдельно.")
    }

    @Test func омографыНеПереписываются() {
        let all = "Все кубики и все сферы лежат рядом."
        #expect(applyDefaults(all) == all)
        #expect(!applyDefaults(all).contains("ё"))

        let code = "Гражданский кодекс лежит под зелёной лампой."
        #expect(applyDefaults(code) == code)
        #expect(!applyDefaults(code).contains("Codex"))
    }

    @Test func падежныеФормыГитхабаОстаютсяРусскими() {
        let sentence = "Макет гитхаба сравнили с гитхабом."
        #expect(applyDefaults(sentence) == sentence)
        #expect(applyDefaults("Робот открыл гидхаб.") == "Робот открыл гитхаб.")
    }

    @Test func словарныеГраницыНеЗадеваютСоседниеСлова() {
        let sentence = "Кимика и кимии просят дополнить и исполнить макет."
        #expect(applyDefaults(sentence) == sentence)
        #expect(applyDefaults("Клад и склад отмечены на карте.")
                == "Клад и склад отмечены на карте.")
    }

    @Test func закрытыйСписокНеКапситКороткиеСлова() {
        for word in ["Это", "Ну", "Да", "Во", "Он", "Мы", "То", "Ооо", "Тс"] {
            let sentence = "\(word) возле синего куба."
            #expect(applyDefaults(sentence) == sentence)
        }
        #expect(applyDefaults("Эцп рядом с Омвд и Гибдд.")
                == "ЭЦП рядом с ОМВД и ГИБДД.")
    }
}

// MARK: - Форма текста

struct PunctuationMetrics: Equatable {
    var recordsWithFinalMark = 0
    var recordsStartingLowercase = 0
    var doubleSpaces = 0
    var spacesBeforeMark = 0
    var commas = 0
    var periods = 0

    static func measure(_ texts: [String]) -> PunctuationMetrics {
        let spaceBeforeMark = try? NSRegularExpression(pattern: #"\s[.,!?;:]"#)
        var metrics = PunctuationMetrics()
        for text in texts {
            if let last = text.last, ".!?…".contains(last) { metrics.recordsWithFinalMark += 1 }
            if let first = text.first, first.isLowercase { metrics.recordsStartingLowercase += 1 }
            metrics.doubleSpaces += text.components(separatedBy: "  ").count - 1
            metrics.spacesBeforeMark += spaceBeforeMark?.numberOfMatches(
                in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
            metrics.commas += text.filter { $0 == "," }.count
            metrics.periods += text.filter { $0 == "." }.count
        }
        return metrics
    }
}

@Suite("Форма текста: синтетический корпус", .serialized)
struct SyntheticPunctuationGuardTests {
    @Test func словарьНеЛомаетПунктуацию() {
        let entries = SyntheticCorrectionCorpus.entries
        let raw = PunctuationMetrics.measure(entries.map(\.text))
        let expected = PunctuationMetrics.measure(entries.map(\.expectedText))
        let actual = PunctuationMetrics.measure(SyntheticCorrectionCorpus.processed.map(\.text))

        #expect(actual == expected)
        #expect(actual.recordsWithFinalMark == raw.recordsWithFinalMark)
        #expect(actual.recordsStartingLowercase == raw.recordsStartingLowercase)
        #expect(actual.doubleSpaces == raw.doubleSpaces)
        #expect(actual.spacesBeforeMark == raw.spacesBeforeMark)
        #expect(actual.commas == raw.commas)
        // Ни одна заводская замена не добавляет и не убирает точку: в словаре не
        // осталось правил, у которых замена содержит знак препинания.
        #expect(actual.periods == raw.periods)
    }

    @Test func обработкаНеМеняетФайлыСырья() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smltlk-synthetic-raw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rawURL = directory.appendingPathComponent("raw.txt")
        let source = "Картонный смолток пишет промп про гидхаб."
        try Data(source.utf8).write(to: rawURL)
        let before = try Data(contentsOf: rawURL)

        let result = processedDictationText(
            rawTranscript: String(decoding: before, as: UTF8.self),
            corrections: defaultTranscriptCorrections)
        #expect(result.text == "Картонный iriz пишет промпт про гитхаб.")
        #expect(result.appliedCorrectionCount == 3)
        #expect(try Data(contentsOf: rawURL) == before)

        let fixtureBefore = try Data(contentsOf: SyntheticCorrectionCorpus.fixtureURL)
        _ = SyntheticCorrectionCorpus.processed
        #expect(try Data(contentsOf: SyntheticCorrectionCorpus.fixtureURL) == fixtureBefore)
    }
}
