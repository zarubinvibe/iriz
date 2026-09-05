// Заготовки: подстановка, границы слова, отказы, хранение.
//
// Проверяется настоящий `processedDictationText` — тот самый вызов, который
// делает `DictationController`, — а не копия его логики.
import Foundation
import Testing

@testable import IrizDictate

// MARK: - Подстановка

@Suite("Заготовки: подстановка")
struct DictationSnippetSubstitutionTests {
    private let шапка = DictationSnippet(
        trigger: "шапка иска",
        body: "В Верховный суд\nот ИП Иванова И. И.\nИНН 000000000000"
    )

    @Test func фразаИзДвухСловРаскрываетсяВМногострочныйБлок() {
        let result = processedDictationText(rawTranscript: "шапка иска далее по тексту",
                                            corrections: [],
                                            snippets: [шапка])
        #expect(result.text == "В Верховный суд\nот ИП Иванова И. И.\nИНН 000000000000 далее по тексту")
        #expect(result.appliedSnippetCount == 1)
        #expect(result.appliedCorrectionCount == 0)
    }

    /// Главное обещание: внутри большего слова заготовка не срабатывает.
    /// Без этого «иск» переписывал бы «иска», «искать» и «изыскание».
    @Test func заготовкаНеСрабатываетВнутриБольшегоСлова() {
        let snippet = DictationSnippet(trigger: "иск", body: "исковое заявление")
        let unchanged = ["иска", "искать", "изыскание", "Иском"]

        for word in unchanged {
            let result = processedDictationText(rawTranscript: word, corrections: [], snippets: [snippet])
            #expect(result.text == word, "заготовка не должна была сработать в «\(word)»")
            #expect(result.appliedSnippetCount == 0)
        }

        let fired = processedDictationText(rawTranscript: "иск подан",
                                           corrections: [],
                                           snippets: [snippet])
        #expect(fired.text == "исковое заявление подан")
        #expect(fired.appliedSnippetCount == 1)
    }

    /// Речь не знает регистра: с большой буквы начинается любое первое слово.
    @Test func регистрФразыЗначенияНеИмеет() {
        let result = processedDictationText(rawTranscript: "Шапка Иска.",
                                            corrections: [],
                                            snippets: [шапка])
        #expect(result.text.hasPrefix("В Верховный суд"))
        #expect(result.appliedSnippetCount == 1)
    }

    /// Пробелы во фразе — любые: ASR ставит и двойной пробел, и перевод строки.
    @Test func разделителиВнутриФразыЛюбые() {
        let result = processedDictationText(rawTranscript: "шапка\n  иска",
                                            corrections: [],
                                            snippets: [шапка])
        #expect(result.appliedSnippetCount == 1)
    }

    /// Один проход, направление первое: словарь НЕ переписывает раскрытую
    /// заготовку. Иначе шапка документа менялась бы за спиной владельца.
    @Test func словарьНеПравитРаскрытуюЗаготовку() {
        let result = processedDictationText(
            rawTranscript: "шапка иска",
            corrections: [TranscriptCorrection(source: "суд", replacement: "СУД")],
            snippets: [шапка]
        )
        #expect(result.text.contains("В Верховный суд"))
        #expect(!result.text.contains("СУД"))
        #expect(result.appliedCorrectionCount == 0)
        #expect(result.appliedSnippetCount == 1)
    }

    /// Один проход, направление второе: замена не собирает фразу заготовки.
    @Test func заменаНеСобираетФразуЗаготовки() {
        let result = processedDictationText(
            rawTranscript: "смолток шапка",
            corrections: [TranscriptCorrection(source: "смолток", replacement: "smltlk")],
            snippets: [DictationSnippet(trigger: "smltlk шапка", body: "РАСКРЫТО")]
        )
        #expect(result.text == "smltlk шапка")
        #expect(result.appliedCorrectionCount == 1)
        #expect(result.appliedSnippetCount == 0)
    }

    /// Длинная фраза бьёт короткую — как и в словаре.
    @Test func длиннаяФразаБьётКороткую() {
        let result = processedDictationText(
            rawTranscript: "шапка иска",
            corrections: [],
            snippets: [
                DictationSnippet(trigger: "шапка", body: "КОРОТКО"),
                шапка,
            ]
        )
        #expect(result.text.hasPrefix("В Верховный суд"))
        #expect(result.appliedSnippetCount == 1)
    }

    /// Равная длина — побеждает заготовка: произнести фразу ради блока текста
    /// намереннее, чем совпасть с записью словаря.
    @Test func приРавнойДлинеПобеждаетЗаготовка() {
        let result = processedDictationText(
            rawTranscript: "а б",
            corrections: [TranscriptCorrection(source: "а б", replacement: "ЗАМЕНА")],
            snippets: [DictationSnippet(trigger: "а б", body: "ЗАГОТОВКА")]
        )
        #expect(result.text == "ЗАГОТОВКА")
        #expect(result.appliedSnippetCount == 1)
        #expect(result.appliedCorrectionCount == 0)
    }

    @Test func счётчикиРазделены() {
        let result = processedDictationText(
            rawTranscript: "шапка иска, эцп и снова шапка иска",
            corrections: [TranscriptCorrection(source: "эцп", replacement: "ЭЦП")],
            snippets: [шапка]
        )
        #expect(result.appliedSnippetCount == 2)
        #expect(result.appliedCorrectionCount == 1)
    }

    @Test func пустойСписокЗаготовокНичегоНеМеняет() {
        let result = processedDictationText(rawTranscript: "как есть",
                                            corrections: [],
                                            snippets: [])
        #expect(result.text == "как есть")
        #expect(result.appliedSnippetCount == 0)
    }

    /// Сырьё не трогаем: на диск ложится оно, а всё это — только текст к вставке.
    @Test func сырьёОстаётсяНетронутым() {
        let raw = "шапка иска"
        let result = processedDictationText(rawTranscript: raw, corrections: [], snippets: [шапка])
        #expect(raw == "шапка иска")
        #expect(result.text != raw)
    }
}

// MARK: - Отказы нормализации

@Suite("Заготовки: что отклоняется")
struct DictationSnippetNormalizationTests {
    @Test func пустаяФразаИлиТелоОтклоняются() {
        #expect(validatedDictationSnippet(DictationSnippet(trigger: "  ", body: "текст"))
                == .failure(.emptyTrigger))
        #expect(validatedDictationSnippet(DictationSnippet(trigger: "фраза", body: " \n "))
                == .failure(.emptyBody))
    }

    /// Фраза без буквы и цифры ловится границами слова где попало — такую
    /// заготовку в речи не произнести, а вреда от неё сколько угодно.
    @Test func фразаБезБуквыИЦифрыОтклоняется() {
        #expect(validatedDictationSnippet(DictationSnippet(trigger: "...", body: "текст"))
                == .failure(.triggerWithoutLetterOrDigit))
        #expect(validatedDictationSnippet(DictationSnippet(trigger: "№ 1", body: "текст")).isSuccess)
    }

    @Test func переборПоДлинеОтклоняется() {
        let longTrigger = String(repeating: "ы", count: MAX_DICTATION_SNIPPET_TRIGGER_BYTES)
        #expect(validatedDictationSnippet(DictationSnippet(trigger: longTrigger, body: "т"))
                == .failure(.triggerTooLong))

        let longBody = String(repeating: "ы", count: MAX_DICTATION_SNIPPET_BODY_BYTES)
        #expect(validatedDictationSnippet(DictationSnippet(trigger: "т", body: longBody))
                == .failure(.bodyTooLong))
    }

    @Test func нулевойБайтОтклоняется() {
        #expect(validatedDictationSnippet(DictationSnippet(trigger: "фра\0за", body: "текст"))
                == .failure(.forbiddenCharacter))
    }

    /// Края обрезаются, внутренние переводы строк остаются: многострочность —
    /// весь смысл заготовки.
    @Test func краяОбрезаютсяВнутренниеПереносыОстаются() {
        let cleaned = try? validatedDictationSnippet(
            DictationSnippet(trigger: "  шапка иска  ", body: "\n первая\nвторая \n")
        ).get()
        #expect(cleaned == DictationSnippet(trigger: "шапка иска", body: "первая\nвторая"))
    }

    @Test func дубликатыСклеиваютсяПоследняяПобеждаетНаМесте() {
        let normalized = normalizedDictationSnippets([
            DictationSnippet(trigger: "Шапка  Иска", body: "первая"),
            DictationSnippet(trigger: "вторая фраза", body: "вторая"),
            DictationSnippet(trigger: "шапка иска", body: "переписанная"),
        ])
        #expect(normalized == [
            DictationSnippet(trigger: "шапка иска", body: "переписанная"),
            DictationSnippet(trigger: "вторая фраза", body: "вторая"),
        ])
    }

    @Test func негодноеВыкидываетсяАСписокОграничен() {
        let mixed = [
            DictationSnippet(trigger: "", body: "нет фразы"),
            DictationSnippet(trigger: "есть", body: "тело"),
        ]
        #expect(normalizedDictationSnippets(mixed) == [DictationSnippet(trigger: "есть", body: "тело")])

        let overflow = (0..<(MAX_DICTATION_SNIPPETS + 10)).map {
            DictationSnippet(trigger: "фраза\($0)", body: "тело")
        }
        #expect(normalizedDictationSnippets(overflow).count == MAX_DICTATION_SNIPPETS)
    }
}

// MARK: - Хранение

@Suite("Заготовки: хранение")
struct DictationSnippetStorageTests {
    private func withIsolatedDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
        let name = "smltlk-snippets-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { removeSuiteFile(named: name, defaults: defaults) }
        return try body(defaults)
    }

    /// Заводского набора НЕТ и быть не должно: заводской словарь уже научил,
    /// что раздавать всем чужие шапки и реквизиты — ошибка.
    @Test func поУмолчаниюПусто() {
        withIsolatedDefaults { d in
            #expect(DictationSettings(defaults: d).snippets.isEmpty)
        }
    }

    @Test func переживаетПерезапуск() {
        withIsolatedDefaults { d in
            let settings = DictationSettings(defaults: d)
            settings.snippets = [DictationSnippet(trigger: "шапка иска", body: "первая\nвторая")]
            #expect(DictationSettings(defaults: d).snippets
                    == [DictationSnippet(trigger: "шапка иска", body: "первая\nвторая")])
            _ = settings
        }
    }

    @Test func записьНормализуетсяАМусорВКлючеДаётПустоту() {
        withIsolatedDefaults { d in
            let settings = DictationSettings(defaults: d)
            settings.snippets = [
                DictationSnippet(trigger: " ", body: "нет фразы"),
                DictationSnippet(trigger: "  есть  ", body: "  тело  "),
            ]
            #expect(settings.snippets == [DictationSnippet(trigger: "есть", body: "тело")])

            d.set(Data("не json".utf8), forKey: "dictation_snippets_v1")
            #expect(DictationSettings(defaults: d).snippets.isEmpty)
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
