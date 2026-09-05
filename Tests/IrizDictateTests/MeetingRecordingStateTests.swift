// Проба цветного состояния записи встречи.
//
// Требование владельца: «нужно как-то выделять отдельно, чтобы было видно по
// цвету, что идёт работа по записи встречи». Судится машиной, а не глазом:
// разница между режимами - сохранённый звук, и путаница здесь стоит записи
// заседания.
import AppKit
import Testing

@testable import IrizDictate

@Suite("Состояние записи встречи")
struct MeetingRecordingStateTests {
    @Test("у записи встречи свой цвет, не совпадающий ни с одним другим")
    func свойЦвет() {
        let meeting = dictationHUDWaveColor(.meeting)
        for other in [DictationHUDWaveTone.normal, .prompt, .translation, .failure] {
            #expect(dictationHUDWaveColor(other) != meeting)
        }
    }

    @Test("цвет записи заметно отличается от соседей по палитре")
    func заметноОтличается() {
        // «Идёт запись» обязано читаться одним взглядом через комнату, а не
        // сравнением оттенков рядом. Порог по сумме различий каналов.
        let meeting = dictationHUDWaveColor(.meeting)
        for other in [DictationHUDWaveTone.prompt, .failure] {
            let colour = dictationHUDWaveColor(other)
            let delta = abs(meeting.redComponent - colour.redComponent)
                + abs(meeting.greenComponent - colour.greenComponent)
                + abs(meeting.blueComponent - colour.blueComponent)
            #expect(delta > 0.2)
        }
    }

    @Test("режим записи встречи отдельный, а не настройка диктовки")
    func режимОтдельный() {
        // Цена путаницы несимметрична: диктовку, принятую за встречу, человек
        // заметит по лишнему файлу; встречу, принятую за диктовку, он заметит
        // тогда, когда запись заседания не сохранилась.
        #expect(DictationRecordingPurpose.meeting != .dictation)
        #expect(dictationHUDWaveTone(stage: .listening(.meeting), purpose: .meeting) == .meeting)
    }

    @Test("голосовой доступ называет запись встречи словами")
    func голосовойДоступНазывает() {
        // Цвет видит зрячий. На слух запись встречи от диктовки не отличить, а
        // разница между ними - сохранённый звук.
        #expect(dictationHUDTitle(for: .listening(.meeting)).contains("встречу"))
    }
}
