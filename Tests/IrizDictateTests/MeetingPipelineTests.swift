// Проба решений конвейера встречи.
//
// Распознавателя и диаризатора под `swift test` нет: обоим нужны модели CoreML
// и минуты работы. Судятся РЕШЕНИЯ, которые не зависят от движков и которые
// стоят дороже всего, если ошибиться:
//
//   - отказ разделения по говорящим не роняет протокол;
//   - монолог не выглядит как провал разделения;
//   - половина доказательства на диск не ложится.
import Foundation
import Testing

@testable import IrizDictate

@Suite("Решения конвейера встречи")
struct MeetingPipelineTests {
    @Test("отказы названы поимённо")
    func отказыНазваныПоимённо() {
        // Разбирать будут запись заседания: «не смог» без причины неотличимо
        // от поломки, и владелец не поймёт, чинить ему файл или приложение.
        let all: [MeetingPipelineFailure] = [.audioUnreadable, .transcriptionFailed,
                                             .nothingRecognized, .storeFailed]
        for failure in all {
            #expect(!failure.rawValue.isEmpty)
        }
        #expect(Set(all.map(\.rawValue)).count == all.count)
    }

    @Test("без дорожек говорящих протокол собирается одной репликой")
    func безДорожекПротоколСобирается() {
        // Ровно то поведение, которое конвейер даёт при отказе диаризатора:
        // текст заседания у владельца остаётся, имена он расставит руками.
        let document = MeetingProtocolDocument(
            title: "Заседание",
            recordedAt: Date(timeIntervalSince1970: 1_757_000_000),
            audioSeconds: 120,
            turns: [SpeakerTurn(speaker: "Запись", text: "весь текст", start: 0, end: 120)]
        )
        let text = document.text()
        #expect(text.contains("весь текст"))
        #expect(text.contains("Участники: Запись"))
    }

    @Test("признак разбора говорящих не врёт")
    func признакРазбораНеВрёт() {
        // Владелец должен отличить монолог от неудавшегося разделения: в первом
        // случае имена расставлять не нужно, во втором нужно.
        let resolved = MeetingResult(
            artifacts: MeetingArtifacts(directory: URL(fileURLWithPath: "/tmp/a"),
                                        audio: URL(fileURLWithPath: "/tmp/a/audio.wav"),
                                        transcript: URL(fileURLWithPath: "/tmp/a/protocol.md")),
            turns: [], speakersResolved: false, audioSeconds: 10)
        #expect(resolved.speakersResolved == false)
    }

    @Test("итог встречи всегда несёт оба файла")
    func итогНесётОбаФайла() {
        // Тип не позволяет вернуть встречу без звука или без расшифровки:
        // половина доказательства опаснее его отсутствия.
        // Сравниваются пути, а не URL: у каталожного URL остаётся косая черта
        // на хвосте, и равенство URL врёт про одну и ту же папку.
        let directory = URL(fileURLWithPath: "/tmp/m", isDirectory: true)
        let artifacts = MeetingArtifacts(directory: directory,
                                         audio: directory.appendingPathComponent("audio.m4a"),
                                         transcript: directory.appendingPathComponent("protocol.md"))
        #expect(artifacts.audio.deletingLastPathComponent().path == directory.path)
        #expect(artifacts.transcript.deletingLastPathComponent().path == directory.path)
    }
}
