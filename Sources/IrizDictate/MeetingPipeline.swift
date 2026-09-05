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
// Наружу не уходит ничего: и распознавание, и разделение по говорящим работают
// на этой машине.
import Foundation

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

@MainActor
public final class MeetingPipeline {
    private let transcriber: AudioFileTranscriber
    private let diarizer: SpeakerDiarizer
    private let storeRoot: URL?

    public init(transcriber: AudioFileTranscriber = AudioFileTranscriber(),
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
                    progress: @escaping (String) -> Void = { _ in }) async throws -> MeetingResult {
        progress("Читаю запись")
        guard let decoded = try? await AudioFileDecoder.decode(url) else {
            throw MeetingPipelineFailure.audioUnreadable
        }

        progress("Расшифровываю")
        _ = try? await transcriber.prepare()
        let transcript: AudioFileTranscript
        do {
            transcript = try await transcriber.transcribe(decoded, language: .russian)
        } catch {
            log("meeting: расшифровка отказала (\(error))")
            throw MeetingPipelineFailure.transcriptionFailed
        }
        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingPipelineFailure.nothingRecognized
        }

        progress("Разбираю говорящих")
        // Отказ диаризатора конвейер не роняет: протокол без разделения хуже
        // полного, но лучше отсутствующего.
        let spans = (try? await diarizer.spans(of: url)) ?? []
        let turns = spans.isEmpty
            ? [SpeakerTurn(speaker: "Запись", text: transcript.text,
                           start: 0, end: transcript.audioSeconds)]
            : speakerTurnsNamed(speakerTurns(tokens: transcript.tokenTimings, spans: spans),
                                names: names)

        progress("Сохраняю")
        let document = MeetingProtocolDocument(title: title, recordedAt: date,
                                               audioSeconds: transcript.audioSeconds,
                                               turns: turns)
        do {
            let artifacts = try MeetingStore.save(audio: url, protocolText: document.text(),
                                                  at: date, title: title, in: storeRoot)
            return MeetingResult(artifacts: artifacts, turns: turns,
                                 speakersResolved: !spans.isEmpty,
                                 audioSeconds: transcript.audioSeconds)
        } catch {
            log("meeting: запись на диск отказала (\(error))")
            throw MeetingPipelineFailure.storeFailed
        }
    }
}
