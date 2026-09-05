// Проба сшивки: кто что сказал.
//
// Судится то, от чего зависит протокол заседания: приписка слова верному
// говорящему на перебиве, целость реплики на паузе, и то, что ни одно слово не
// пропадает. Потерянное слово хуже неверно приписанного - приписку видно и
// можно поправить, пропажу не видно вовсе.
import Foundation
import Testing

@testable import IrizDictate

@Suite("Сшивка реплик по говорящим")
struct SpeakerTurnsTests {
    private func token(_ text: String, _ start: Double, _ end: Double) -> DictationTokenTiming {
        DictationTokenTiming(token: text, start: start, end: end, confidence: 1)
    }

    @Test("два говорящих по очереди дают две реплики")
    func двоеПоОчереди() {
        let turns = speakerTurns(
            tokens: [token("истец", 0.0, 0.5), token("заявил", 0.5, 1.0),
                     token("ответчик", 2.0, 2.5), token("возразил", 2.5, 3.0)],
            spans: [SpeakerSpan(speaker: "S1", start: 0, end: 1.2),
                    SpeakerSpan(speaker: "S2", start: 1.8, end: 3.2)]
        )
        #expect(turns.count == 2)
        #expect(turns[0] == SpeakerTurn(speaker: "S1", text: "истец заявил", start: 0.0, end: 1.0))
        #expect(turns[1] == SpeakerTurn(speaker: "S2", text: "ответчик возразил", start: 2.0, end: 3.0))
    }

    @Test("пауза внутри одного говорящего реплику не рвёт")
    func паузаНеРвётРеплику() {
        // Человек думает вслух. Разрыв в полторы секунды не означает новой
        // реплики: новая начинается со сменой говорящего.
        let turns = speakerTurns(
            tokens: [token("суд", 0.0, 0.4), token("удаляется", 2.0, 2.6)],
            spans: [SpeakerSpan(speaker: "S1", start: 0, end: 3)]
        )
        #expect(turns.count == 1)
        #expect(turns[0].text == "суд удаляется")
    }

    @Test("слово на перебиве идёт тому, с кем перекрытие больше")
    func перебивРешаетсяПерекрытием() {
        // Начало слова попало в чужой отрезок - так бывает постоянно, границы
        // диаризации плывут. Приписка по началу отдала бы слово предыдущему
        // говорящему, и в протоколе сменился бы автор заявления.
        let turns = speakerTurns(
            tokens: [token("возражаю", 0.9, 1.6)],
            spans: [SpeakerSpan(speaker: "S1", start: 0, end: 1.0),
                    SpeakerSpan(speaker: "S2", start: 1.0, end: 2.0)]
        )
        #expect(turns.map(\.speaker) == ["S2"])
    }

    @Test("слово в паузе между отрезками не теряется")
    func словоВПаузеНеТеряется() {
        let turns = speakerTurns(
            tokens: [token("да", 1.4, 1.5)],
            spans: [SpeakerSpan(speaker: "S1", start: 0, end: 1.0),
                    SpeakerSpan(speaker: "S2", start: 2.0, end: 3.0)]
        )
        #expect(turns.count == 1)
        #expect(turns[0].text == "да")
    }

    @Test("ни одно слово не пропадает")
    func ниОдноСловоНеПропадает() {
        let tokens = (0..<20).map { token("слово\($0)", Double($0) * 0.5, Double($0) * 0.5 + 0.4) }
        let turns = speakerTurns(
            tokens: tokens,
            spans: [SpeakerSpan(speaker: "S1", start: 0, end: 4),
                    SpeakerSpan(speaker: "S2", start: 4, end: 12)]
        )
        let words = turns.flatMap { $0.text.split(separator: " ") }
        #expect(words.count == tokens.count)
    }

    @Test("без дорожек говорящих реплика одна и без имени")
    func безДорожекОднаРеплика() {
        let turns = speakerTurns(
            tokens: [token("текст", 0, 1)],
            spans: []
        )
        #expect(turns.isEmpty)
    }

    @Test("слова приходят в порядке времени, а не в порядке списка")
    func порядокПоВремени() {
        let turns = speakerTurns(
            tokens: [token("второе", 1.0, 1.4), token("первое", 0.0, 0.4)],
            spans: [SpeakerSpan(speaker: "S1", start: 0, end: 2)]
        )
        #expect(turns[0].text == "первое второе")
    }

    @Test("имена подставляются и переживают запись на диск")
    func именаПодставляютсяИПереживают() throws {
        var names = SpeakerNames()
        names.set("Иванов И.И.", for: "S1")
        let data = try JSONEncoder().encode(names)
        let restored = try JSONDecoder().decode(SpeakerNames.self, from: data)
        #expect(restored.display("S1") == "Иванов И.И.")
        // Без подставленного имени показывается метка: пустое место в
        // протоколе хуже технической метки.
        #expect(restored.display("S2") == "S2")
    }

    @Test("пустое имя снимает подстановку")
    func пустоеИмяСнимаетПодстановку() {
        var names = SpeakerNames()
        names.set("Петров", for: "S1")
        names.set("   ", for: "S1")
        #expect(names.display("S1") == "S1")
    }

    @Test("реплики с именами показывают имена")
    func репликиСИменами() {
        var names = SpeakerNames()
        names.set("Судья", for: "S1")
        let turns = speakerTurnsNamed(
            [SpeakerTurn(speaker: "S1", text: "заседание открыто", start: 0, end: 1)],
            names: names
        )
        #expect(turns[0].speaker == "Судья")
    }
}
