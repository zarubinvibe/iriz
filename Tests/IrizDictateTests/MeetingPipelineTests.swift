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
    @MainActor
    @Test("отменённый разбор не читает запись и не начинает распознавание")
    func отменаДоНачалаОстанавливаетКонвейер() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            var startedStages: [String] = []
            do {
                _ = try await MeetingPipeline().run(
                    audio: URL(fileURLWithPath: "/iriz-test-no-audio.wav"), title: "Встреча",
                    progress: { startedStages.append($0) })
                Issue.record("Отменённый разбор не должен завершаться успешно")
            } catch is CancellationError {
                #expect(startedStages.isEmpty)
            } catch {
                Issue.record("Отмена подменена отказом обработки: \(error)")
            }
        }
        await task.value
    }

    @Test("без времён слов полный текст сохраняется даже при успешной диаризации")
    func текстБезТайминговНеТеряется() {
        let spans = [SpeakerSpan(speaker: "speaker-1", start: 0, end: 12)]
        let tokenCases: [[DictationTokenTiming]] = [
            [], [DictationTokenTiming(token: " ", start: 0, end: 1, confidence: 1)]
        ]
        for tokens in tokenCases {
            let transcript = AudioFileTranscript(text: "Первая реплика.\nВторая реплика.",
                                                  processingSeconds: 1, audioSeconds: 12,
                                                  tokenTimings: tokens)
            let resolved = meetingSpeakerTurns(transcript: transcript, spans: spans)
            #expect(!resolved.speakersResolved)
            #expect(resolved.turns == [SpeakerTurn(speaker: "Запись", text: transcript.text,
                                                  start: 0, end: 12)])
            let document = MeetingProtocolDocument(title: "Встреча", recordedAt: Date(),
                                                   audioSeconds: 12, turns: resolved.turns)
            #expect(document.text().contains(transcript.text))
        }
    }

    @Test("при пригодных таймингах сохраняются реплики и имена говорящих")
    func таймингиПозволяютРазделитьГоворящих() {
        let transcript = AudioFileTranscript(text: "Да. Нет.", processingSeconds: 1, audioSeconds: 2,
                                              tokenTimings: [
                                                DictationTokenTiming(token: "Да.", start: 0, end: 1, confidence: 1),
                                                DictationTokenTiming(token: "Нет.", start: 1, end: 2, confidence: 1)
                                              ])
        let resolved = meetingSpeakerTurns(
            transcript: transcript,
            spans: [SpeakerSpan(speaker: "one", start: 0, end: 1),
                    SpeakerSpan(speaker: "two", start: 1, end: 2)],
            names: SpeakerNames(names: ["one": "Анна", "two": "Борис"]))
        #expect(resolved.speakersResolved)
        #expect(resolved.turns.map(\.speaker) == ["Анна", "Борис"])
        #expect(resolved.turns.map(\.text) == ["Да.", "Нет."])
    }

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
