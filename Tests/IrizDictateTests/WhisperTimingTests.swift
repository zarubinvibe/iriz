import Foundation
import Testing

@testable import IrizDictate

@Suite("Таймкоды Whisper только по запросу")
struct WhisperTimingTests {
    @Test("диктовка не включает таймкоды; файловый opt-in включает реальные token timestamps")
    func timestampWorkIsExplicitlyOptedIn() {
        let normal = whisperTranscriptionParameters()
        let meeting = whisperTranscriptionParameters(captureTokenTimings: true)
        #expect(normal.no_timestamps && !normal.token_timestamps)
        #expect(!meeting.no_timestamps && meeting.token_timestamps)
        #expect(normal.n_threads == meeting.n_threads)
        #expect(!normal.print_progress && !meeting.print_progress)
        #expect(!normal.print_realtime && !meeting.print_realtime)
        #expect(!normal.print_special && !meeting.print_special)
        #expect(!normal.translate && !meeting.translate)
    }

    @Test("разрезанные UTF-8 токены собираются без replacement и изменения пробелов")
    func bytePiecesPreserveExactTextAndNativeBounds() {
        let raw = " Привет, 👩🏽‍💻!\n"
        let pieces = Array(raw.utf8).enumerated().map {
            WhisperTimingPiece(bytes: Data([$0.element]), startCentiseconds: Int64($0.offset),
                               endCentiseconds: Int64($0.offset + 1), confidence: 0.9)
        }
        let result = whisperTokenTimings(from: pieces, matching: raw, audioSeconds: 6)
        #expect(!result.isEmpty)
        #expect(Array(result.map(\.token).joined().utf8) == Array(raw.utf8))
        #expect(result.first?.start == 0)
        #expect(result.last?.end == Double(raw.utf8.count) / 100)
        #expect(!result.map(\.token).joined().contains("\u{FFFD}"))
    }

    @Test("неполный UTF-8 или непокрытый текст не получают ложной привязки")
    func incompleteTokensCannotTruncateRawText() {
        let pieces = [WhisperTimingPiece(bytes: Data("Да.".utf8), startCentiseconds: 0,
                                         endCentiseconds: 100, confidence: 1)]
        #expect(whisperTokenTimings(from: pieces, matching: "Да. Ещё текст.", audioSeconds: 6).isEmpty)
        let broken = [WhisperTimingPiece(bytes: Data([0xD0]), startCentiseconds: 0,
                                         endCentiseconds: 100, confidence: 1)]
        #expect(whisperTokenTimings(from: broken, matching: "Д", audioSeconds: 6).isEmpty)
    }

    @Test("невалидные границы не исправляются санитайзером в правдоподобные времена")
    func invalidNativeBoundsAreUnavailable() {
        for (start, end): (Int64, Int64) in [(-1, 100), (100, 50), (0, 601)] {
            let piece = WhisperTimingPiece(bytes: Data("Да.".utf8), startCentiseconds: start,
                                            endCentiseconds: end, confidence: 1)
            #expect(whisperTokenTimings(from: [piece], matching: "Да.", audioSeconds: 6).isEmpty)
        }
        let piece = WhisperTimingPiece(bytes: Data("Да.".utf8), startCentiseconds: 0,
                                        endCentiseconds: 100, confidence: .nan)
        #expect(whisperTokenTimings(from: [piece], matching: "Да.", audioSeconds: 6).isEmpty)
    }

    @Test("нулевая длительность движка сохраняется как есть и честно отклоняется resolver")
    func zeroDurationIsNotInventedIntoPositiveTiming() {
        let piece = WhisperTimingPiece(bytes: Data("Да.".utf8), startCentiseconds: 12,
                                        endCentiseconds: 12, confidence: 1)
        let timings = whisperTokenTimings(from: [piece], matching: "Да.", audioSeconds: 6)
        #expect(timings.first?.start == 0.12 && timings.first?.end == 0.12)
        let snapshot = meetingTranscriptSnapshot(
            transcript: AudioFileTranscript(text: "Да.", processingSeconds: 0, audioSeconds: 6,
                                            tokenTimings: timings), spans: [])
        #expect(snapshot.timingQuality == .unavailable)
        #expect(snapshot.rawText == "Да.")
    }
}
