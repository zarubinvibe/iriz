// Проба протокола: форма документа, который подшивают к делу.
import Foundation
import Testing

@testable import IrizDictate

@Suite("Протокол встречи")
struct MeetingProtocolTests {
    private func document(_ turns: [SpeakerTurn]) -> MeetingProtocolDocument {
        MeetingProtocolDocument(title: "Заседание по делу А65-1234/2026",
                                recordedAt: Date(timeIntervalSince1970: 1_757_000_000),
                                audioSeconds: 3725,
                                turns: turns)
    }

    @Test("часы показываются всегда")
    func часыВсегда() {
        // Заседание идёт часами, и «04:12» на третьем часу читается неверно.
        #expect(meetingTimestamp(3725) == "01:02:05")
        #expect(meetingTimestamp(5) == "00:00:05")
        #expect(meetingTimestamp(-10) == "00:00:00")
    }

    @Test("участники идут в порядке вступления")
    func участникиВПорядкеВступления() {
        // Порядок вступления сам по себе сведения о встрече: кто открыл, кто
        // ответил. По алфавиту это теряется.
        let doc = document([
            SpeakerTurn(speaker: "Судья", text: "заседание открыто", start: 0, end: 2),
            SpeakerTurn(speaker: "Истец", text: "поддерживаю иск", start: 3, end: 5),
            SpeakerTurn(speaker: "Судья", text: "ответчик", start: 6, end: 7),
        ])
        #expect(doc.participants == ["Судья", "Истец"])
    }

    @Test("протокол несёт шапку, участников и метки времени")
    func протоколНесётШапку() {
        let text = document([
            SpeakerTurn(speaker: "Судья", text: "заседание открыто", start: 62, end: 64),
        ]).text()
        #expect(text.contains("# Заседание по делу А65-1234/2026"))
        #expect(text.contains("Длительность: 01:02:05"))
        #expect(text.contains("Участники: Судья"))
        #expect(text.contains("**Судья** [00:01:02]"))
        #expect(text.contains("заседание открыто"))
    }

    @Test("неразобранные говорящие названы прямо")
    func неразобранныеНазваныПрямо() {
        // Пустое место хуже честной строки: читатель должен понять, что
        // говорящих не разобрали, а не гадать, почему их нет.
        #expect(document([]).text().contains("Участники: не разобраны"))
        #expect(document([]).text().contains("Речь не распознана."))
    }

    @Test("хвост файла стабилен")
    func хвостСтабилен() {
        // Файл, который каждый раз разный на невидимый символ, шумит в истории
        // изменений и мешает увидеть настоящую правку.
        let text = document([
            SpeakerTurn(speaker: "Судья", text: "первое", start: 0, end: 1),
            SpeakerTurn(speaker: "Истец", text: "второе", start: 2, end: 3),
        ]).text()
        #expect(text.hasSuffix("второе\n"))
    }
}
