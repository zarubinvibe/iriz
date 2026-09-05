// Тесты спасения надиктовки, которая никуда не вставилась.
//
// Живое окно, живой буфер и живой фокус под `swift test` не наблюдаются —
// проверяются РЕШЕНИЯ: показывать ли окно на каждом классе провала, что делают
// клавиши в этом режиме, какой именно текст попадает владельцу в руки и что
// хранит настройка.
import Foundation
import IrizCore
import Testing

@testable import IrizDictate

// MARK: - Показывать окно или молчать

@Suite("спасение: показывать окно или молчать")
struct DictationRecoveryPresentationTests {

    /// Ожидание по КАЖДОМУ классу провала. Таблица здесь, а не в теле теста,
    /// чтобы соседний тест мог проверить её полноту.
    private static let expected: [TextInsertionFailure: DictationRecoveryPresentation] = [
        .insertionFailed: .rescueWindow(.insertionFailed),
        .targetNeverRequestedText: .rescueWindow(.targetNeverRequestedText),
        // Главное решение этапа: прямой ввод юникодом ЗАПУСТИЛСЯ и все события
        // ушли — наблюдать нечем только факт забора. Окно «не доставлено» поверх
        // удавшейся вставки зовёт вставить абзац второй раз.
        .deliveryNotObservable: .stayQuiet(.mayHaveBeenInserted),
    ]

    /// Гейт полноты: новый класс провала без явного решения роняет тест здесь,
    /// а не в проде через полгода.
    @Test func решениеЕстьНаКаждыйКлассПровала() {
        #expect(Set(Self.expected.keys) == Set(TextInsertionFailure.allCases))
    }

    @Test(arguments: TextInsertionFailure.allCases)
    func каждыйКлассПровалаРешаетсяОжидаемо(failure: TextInsertionFailure) throws {
        let presentation = dictationRecoveryPresentation(verdict: .notDelivered(failure),
                                                         rescueEnabled: true,
                                                         hasText: true)
        #expect(presentation == (try #require(Self.expected[failure])))
    }

    /// Наблюдаемый провал прямого ввода молчит ДАЖЕ при включённой настройке —
    /// и молчит по своей причине, а не «потому что выключено».
    @Test func прямойВводНеПоднимаетОкноНиПриКакойНастройке() {
        for enabled in [true, false] {
            let presentation = dictationRecoveryPresentation(
                verdict: .notDelivered(.deliveryNotObservable),
                rescueEnabled: enabled,
                hasText: true
            )
            #expect(presentation == .stayQuiet(.mayHaveBeenInserted))
        }
    }

    @Test func подтверждённаяДоставкаОкнаНеПоднимает() {
        #expect(dictationRecoveryPresentation(verdict: .delivered,
                                              rescueEnabled: true,
                                              hasText: true) == .stayQuiet(.delivered))
    }

    /// `.waiting` — не исход, а «ещё ждём». Живьём сюда не приходит, но ветка
    /// названа: окно посреди удачной вставки хуже отсутствия окна.
    @Test func неокончательныйВердиктОкнаНеПоднимает() {
        #expect(dictationRecoveryPresentation(verdict: .waiting,
                                              rescueEnabled: true,
                                              hasText: true) == .stayQuiet(.verdictNotFinal))
    }

    @Test func выключеннаяНастройкаМолчит() {
        #expect(dictationRecoveryPresentation(verdict: .notDelivered(.insertionFailed),
                                              rescueEnabled: false,
                                              hasText: true) == .stayQuiet(.turnedOff))
    }

    /// Пустая строка окном не разворачивается: показывать нечего.
    @Test func пустомуТекстуОкноНеПоднимается() {
        #expect(dictationRecoveryPresentation(verdict: .notDelivered(.insertionFailed),
                                              rescueEnabled: true,
                                              hasText: false) == .stayQuiet(.nothingToShow))
    }
}

// MARK: - Что попадает владельцу в руки

@Suite("спасение: какой текст видит владелец")
struct DictationRescueTextTests {

    /// Ловушка, ради которой этап и написан. `inserted.txt` пишется ТОЛЬКО по
    /// подтверждённой доставке, поэтому история на провале откатывается к
    /// сырью ASR. Сырьё — это фамилия клиента в том виде, как её послышало
    /// распознавание; отдать её владельцу в окне «вот ваш текст» значит отдать
    /// её в исковое заявление. Окно спасения обязано нести ОБРАБОТАННЫЙ текст.
    @Test func спасаетсяОбработанныйТекстАНеСырьёASR() {
        let raw = "иск к Петрову"
        let corrections = [TranscriptCorrection(source: "Петрову", replacement: "Петрухину")]
        let processed = processedDictationText(rawTranscript: raw, corrections: corrections)
        let textToInsert = pastedText(from: processed.text, suffix: .appendSpace)

        let rescue = DictationRescue(text: textToInsert, failure: .targetNeverRequestedText)

        #expect(rescue.text.contains("Петрухину"))
        #expect(!rescue.text.contains("Петрову"))
        #expect(rescue.text != raw)

        // И то же самое с другой стороны: запись истории на провале отдала бы
        // ровно сырьё, потому что inserted.txt не появился.
        let entry = DictationHistoryEntry(directory: URL(fileURLWithPath: "/tmp/none"), text: raw)
        #expect(entry.displayText == raw)
        #expect(rescue.text != entry.displayText)
    }

    /// Неудачный повтор объясняется словами, а не гудком: окно спасения —
    /// единственная копия текста, и владелец должен прочитать, что делать
    /// дальше.
    @Test func уКаждогоИсходаПовтораЕстьСвояСтрока() {
        let outcomes: [DictationRescueRetryOutcome] = [.unknownTarget, .focusDidNotReturn, .notDelivered]
        let texts = outcomes.map(dictationRescueRetryNotice)
        #expect(texts.allSatisfy { !$0.isEmpty })
        #expect(Set(texts).count == outcomes.count)
        // Во всех трёх есть выход: скопировать. Иначе строка только огорчает.
        #expect(texts.allSatisfy { $0.lowercased().contains("копир") })
    }

    @Test func объяснениеЕстьНаКаждыйКлассПровалаИОниРазные() {
        let texts = TextInsertionFailure.allCases.map(dictationRescueExplanation(for:))
        #expect(texts.allSatisfy { !$0.isEmpty })
        #expect(Set(texts).count == TextInsertionFailure.allCases.count)
        #expect(!DICTATION_RESCUE_TITLE.isEmpty)
    }
}

// MARK: - Клавиши в режиме спасения

@Suite("спасение: клавиши")
struct DictationRescueKeyTests {

    /// ⏎ и ⌘C относятся к спасённому тексту, а не к невидимой выделенной
    /// записи истории: списка на экране в этом режиме нет.
    @Test func вводИКопияОтносятсяКСпасённомуТексту() {
        #expect(dictationRescueKeyOutcome(.insertSelected) == .insertRescueText)
        #expect(dictationRescueKeyOutcome(.copySelected) == .copyRescueText)
    }

    @Test func escapeЗакрываетОкно() {
        #expect(dictationRescueKeyOutcome(.close) == .close)
    }

    @Test func двигатьВРежимеСпасенияНечего() {
        #expect(dictationRescueKeyOutcome(.moveSelection(-1)) == .ignore)
        #expect(dictationRescueKeyOutcome(.moveSelection(1)) == .ignore)
        #expect(dictationRescueKeyOutcome(.passThrough) == .ignore)
    }

    /// Раскладка входа та же, что у истории: Escape закрывает, ⏎ вставляет,
    /// ⌘C копирует, ⌫ окну не принадлежит.
    @Test func раскладкаВходаТаЖеЧтоУИстории() {
        let escape = dictationHistoryKeyAction(keyCode: ESCAPE_KEYCODE,
                                               charactersIgnoringModifiers: nil,
                                               hasCommand: false)
        #expect(dictationRescueKeyOutcome(escape) == .close)

        let enter = dictationHistoryKeyAction(keyCode: RETURN_KEYCODE,
                                              charactersIgnoringModifiers: nil,
                                              hasCommand: false)
        #expect(dictationRescueKeyOutcome(enter) == .insertRescueText)

        let copy = dictationHistoryKeyAction(keyCode: 8,
                                             charactersIgnoringModifiers: "c",
                                             hasCommand: true)
        #expect(dictationRescueKeyOutcome(copy) == .copyRescueText)

        let backspace = dictationHistoryKeyAction(keyCode: HISTORY_DELETE_KEYCODE,
                                                  charactersIgnoringModifiers: nil,
                                                  hasCommand: false)
        #expect(dictationRescueKeyOutcome(backspace) == .ignore)
    }
}

// MARK: - Настройка

@Suite("спасение: настройка")
struct DictationRescueSettingTests {

    private func makeSettings(_ body: (DictationSettings, UserDefaults) throws -> Void) rethrows {
        let name = "ru.smltlk.tests.rescue.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(DictationSettings(defaults: defaults), defaults)
    }

    /// Заводское состояние — включено: провал доставки редок, а молчаливый
    /// провал стоит владельцу целой надиктовки.
    @Test func поУмолчаниюВключено() {
        makeSettings { settings, _ in
            #expect(settings.rescueWindowEnabled)
        }
    }

    @Test func выключениеСохраняетсяИЧитается() {
        makeSettings { settings, _ in
            settings.rescueWindowEnabled = false
            #expect(!settings.rescueWindowEnabled)
            settings.rescueWindowEnabled = true
            #expect(settings.rescueWindowEnabled)
        }
    }

    /// Настройка обязана доходить до решения, а не просто лежать в defaults.
    @Test func настройкаУправляетРешением() {
        makeSettings { settings, _ in
            settings.rescueWindowEnabled = false
            #expect(dictationRecoveryPresentation(verdict: .notDelivered(.insertionFailed),
                                                  rescueEnabled: settings.rescueWindowEnabled,
                                                  hasText: true) == .stayQuiet(.turnedOff))

            settings.rescueWindowEnabled = true
            #expect(dictationRecoveryPresentation(verdict: .notDelivered(.insertionFailed),
                                                  rescueEnabled: settings.rescueWindowEnabled,
                                                  hasText: true) == .rescueWindow(.insertionFailed))
        }
    }
}

// MARK: - Модель окна

@Suite("спасение: модель окна")
@MainActor
struct DictationRescueModelTests {

    /// Окно одно на два режима: пока висит спасение, список не показывается —
    /// иначе непонятно, что именно вставит ⏎.
    @Test func спасениеСменяетРежимОкнаИСнимается() {
        let model = DictationHistoryModel()
        #expect(model.rescue == nil)

        let rescue = DictationRescue(text: "текст, который не уехал",
                                     failure: .targetNeverRequestedText)
        model.showRescue(rescue)
        #expect(model.rescue == rescue)

        model.showRescue(nil)
        #expect(model.rescue == nil)
    }

    /// Строка про неудачный повтор не имеет права пережить сам повтор: новый
    /// показ окна начинается с чистого листа, иначе владелец читает жалобу от
    /// прошлой попытки поверх свежего текста.
    @Test func строкаОНеудачеСбрасываетсяНаНовомПоказе() {
        let model = DictationHistoryModel()
        model.showRescue(DictationRescue(text: "текст", failure: .insertionFailed))
        #expect(model.rescueNotice == nil)

        model.showRescueNotice(dictationRescueRetryNotice(.notDelivered))
        #expect(model.rescueNotice == dictationRescueRetryNotice(.notDelivered))

        model.showRescue(DictationRescue(text: "другой текст", failure: .insertionFailed))
        #expect(model.rescueNotice == nil)
    }
}
