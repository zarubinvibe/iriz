// Конвейер встречи: файл на входе, папка с доказательством на выходе.
//
// Порядок шагов не произволен и объясняется ценой отказа:
//
//   1. РАСШИФРОВКА первой. Без текста встреча бесполезна, и если распознаватель
//      не встал, дальше идти незачем.
//   2. ДОРОЖКИ ГОВОРЯЩИХ второй, и её отказ конвейер НЕ роняет. Протокол без
//      разделения по говорящим хуже полного, но лучше отсутствующего: у
//      владельца остаётся текст заседания, а имена он расставит руками.
//   3. ЗАПИСЬ последней и целиком: звук и протокол ложатся вместе или не
//      ложится ничего. Половина доказательства опаснее его отсутствия, потому
//      что создаёт видимость.
//
// run работает локально. Отдельный fillMinutes передаёт сохранённый текст
// выбранному CLI-агенту; UI требует отдельное согласие перед этим вызовом.
import Foundation
import IrizPrompt

public struct MeetingResult: Sendable {
    public let artifacts: MeetingArtifacts
    public let turns: [SpeakerTurn]
    /// Разобрались ли говорящие. Врать здесь нельзя: владелец должен знать,
    /// один это монолог или разделение не удалось.
    public let speakersResolved: Bool
    public let audioSeconds: Double
}

public enum MeetingPipelineFailure: String, Error, Equatable {
    case audioUnreadable = "запись не читается"
    case transcriptionFailed = "расшифровка не удалась"
    case nothingRecognized = "речь в записи не распознана"
    case storeFailed = "не удалось сохранить встречу на диск"
}

/// Whisper может вернуть текст без времён слов. Успешная диаризация сама по
/// себе ещё не связывает слова с людьми: весь исходный текст должен сохраниться.
func meetingSpeakerTurns(transcript: AudioFileTranscript, spans: [SpeakerSpan],
                         names: SpeakerNames = SpeakerNames())
    -> (turns: [SpeakerTurn], speakersResolved: Bool) {
    let snapshot = meetingTranscriptSnapshot(transcript: transcript, spans: spans)
    return (speakerTurnsNamed(snapshot.turns, names: names), snapshot.speakerQuality == .diarized)
}

@MainActor
public final class MeetingPipeline {
    private let transcriber: AudioFileTranscriber
    private let diarizer: SpeakerDiarizer
    private let storeRoot: URL?

    public init(transcriber: AudioFileTranscriber = AudioFileTranscriber(captureTokenTimings: true),
                diarizer: SpeakerDiarizer = SpeakerDiarizer(),
                storeRoot: URL? = nil) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.storeRoot = storeRoot
    }

    /// Прогон одной записи.
    ///
    /// - Parameter names: уже известные имена говорящих. Во второй встрече с
    ///   теми же участниками они не спрашиваются заново.
    public func run(audio url: URL, title: String, names: SpeakerNames = SpeakerNames(),
                    at date: Date = Date(),
                    recordedAt: Date? = nil,
                    progress: @escaping (String) -> Void = { _ in }) async throws -> MeetingResult {
        try Task.checkCancellation()
        progress("Читаю запись")
        let decoded: DecodedAudio
        do {
            decoded = try await AudioFileDecoder.decode(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw MeetingPipelineFailure.audioUnreadable
        }
        try Task.checkCancellation()

        progress("Расшифровываю")
        let transcript: AudioFileTranscript
        do {
            _ = try await transcriber.prepare()
            try Task.checkCancellation()
            transcript = try await transcriber.transcribe(decoded, language: .russian)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            log("meeting: расшифровка отказала")
            throw MeetingPipelineFailure.transcriptionFailed
        }
        try Task.checkCancellation()
        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingPipelineFailure.nothingRecognized
        }

        progress("Разбираю говорящих")
        // Отказ диаризатора конвейер не роняет: протокол без разделения хуже
        // полного, но лучше отсутствующего.
        let spans: [SpeakerSpan]
        do {
            spans = try await diarizer.spans(of: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            spans = []
        }
        try Task.checkCancellation()
        let snapshot = meetingTranscriptSnapshot(transcript: transcript, spans: spans)
        let resolved = (turns: speakerTurnsNamed(snapshot.turns, names: names),
                        speakersResolved: snapshot.speakerQuality == .diarized)
        let source = MeetingSource(title: title, importedAt: date, recordedAt: recordedAt,
                                   audioSeconds: transcript.audioSeconds, transcript: snapshot,
                                   originalFileName: url.lastPathComponent)

        progress("Сохраняю")
        let document = MeetingProtocolDocument(title: title, recordedAt: recordedAt,
                                               audioSeconds: transcript.audioSeconds,
                                               turns: resolved.turns)
        try Task.checkCancellation()
        let saved: MeetingArtifacts
        do {
            saved = try MeetingStore.save(audio: url, protocolText: document.text(),
                                           at: date, title: title, in: storeRoot, source: source)
        } catch {
            log("meeting: запись на диск отказала")
            throw MeetingPipelineFailure.storeFailed
        }
        // Источник уже сохранён: отказ заполнителя больше не теряет запись.
        progress("Собираю DOCX и JSON с расшифровкой")
        let artifacts: MeetingArtifacts
        do {
            let data = try MeetingMinutesGenerator.baseData(for: source)
            artifacts = try await Task.detached {
                try MeetingStore.exportMinutes(data, for: saved, filled: false)
            }.value
        } catch {
            log("meeting: форма не экспортирована; исходник сохранён")
            artifacts = saved
        }
        return MeetingResult(artifacts: artifacts, turns: resolved.turns,
                             speakersResolved: resolved.speakersResolved,
                             audioSeconds: transcript.audioSeconds)
    }

    /// Вызывается только после отдельного согласия UI на выбранного агента.
    /// Для повтора читается сохранённый источник, не запускается распознаватель.
    public func fillMinutes(for artifacts: MeetingArtifacts, using runner: CodexPromptGenerator,
                            progress: @escaping (String) -> Void = { _ in }) async throws -> MeetingArtifacts {
        try Task.checkCancellation()
        let source = try MeetingStore.loadSource(for: artifacts)
        progress("Заполняю протокол по расшифровке")
        let data = try await MeetingMinutesGenerator.generate(source: source, using: runner)
        try Task.checkCancellation()
        progress("Сохраняю DOCX, JSON и уточнения")
        let export = Task.detached {
            try MeetingStore.exportMinutes(data, for: artifacts, filled: true)
        }
        return try await withTaskCancellationHandler {
            try await export.value
        } onCancel: {
            export.cancel()
        }
    }
}
