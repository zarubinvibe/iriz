// Полный исходный текст и проверяемая привязка к машинным таймкодам.
// Никакой литературной правки: реплики вырезаются только из rawText.
import Foundation

public enum MeetingTimingQuality: String, Codable, Equatable, Sendable {
    /// Текст точно сопоставлен с таймкодами ASR; это не оценка точности модели.
    case aligned
    case unavailable
}

public enum MeetingSpeakerQuality: String, Codable, Equatable, Sendable {
    /// Технические метки диаризации, а не установленные личности людей.
    case diarized
    case partial
    case unavailable
}

public enum MeetingTranscriptWarning: String, Codable, Equatable, Sendable {
    case missingTimings
    case invalidTimings
    case overlappingTimings
    case textMismatch
    case missingSpeakers
    case invalidSpeakerSpans
    case overlappingSpeakers
    case unassignedSpeech
}

public struct MeetingTranscriptSnapshot: Codable, Equatable, Sendable {
    public let rawText: String
    public let turns: [SpeakerTurn]
    public let timingQuality: MeetingTimingQuality
    public let speakerQuality: MeetingSpeakerQuality
    public let warnings: [MeetingTranscriptWarning]
}

/// Пустой speaker означает неизвестного говорящего. При неполной привязке
/// таймкодов возвращается весь rawText одной репликой с hasKnownTiming=false.
public func meetingTranscriptSnapshot(transcript: AudioFileTranscript,
                                      spans: [SpeakerSpan]) -> MeetingTranscriptSnapshot {
    let raw = transcript.text
    let tokens = transcript.tokenTimings
    var warnings: [MeetingTranscriptWarning] = []
    func warn(_ warning: MeetingTranscriptWarning) {
        if !warnings.contains(warning) { warnings.append(warning) }
    }
    func fallback(_ warning: MeetingTranscriptWarning) -> MeetingTranscriptSnapshot {
        warn(warning)
        return MeetingTranscriptSnapshot(rawText: raw, turns: [SpeakerTurn(speaker: "", text: raw)],
                                         timingQuality: .unavailable, speakerQuality: .unavailable,
                                         warnings: warnings)
    }

    guard !tokens.isEmpty else { return fallback(.missingTimings) }
    guard transcript.audioSeconds.isFinite, transcript.audioSeconds > 0 else {
        return fallback(.invalidTimings)
    }
    var previousStart: Double = 0
    var previousEnd: Double = 0
    for token in tokens {
        guard token.start.isFinite, token.end.isFinite,
              token.start >= 0, token.end > token.start, token.end <= transcript.audioSeconds,
              token.confidence.isFinite, (0...1).contains(token.confidence),
              token.start >= previousStart else { return fallback(.invalidTimings) }
        // Перестановка токенов по времени могла бы изменить сказанное.
        // Перекрытие не превращаем в выдуманную последовательность реплик.
        guard token.start >= previousEnd else { return fallback(.overlappingTimings) }
        previousStart = token.start
        previousEnd = token.end
    }

    guard let words = meetingAlignedWords(raw: raw, tokens: tokens), !words.isEmpty else {
        return fallback(.textMismatch)
    }

    let usableSpans: [SpeakerSpan]
    if spans.isEmpty {
        warn(.missingSpeakers)
        usableSpans = []
    } else if spans.contains(where: {
        !$0.start.isFinite || !$0.end.isFinite || $0.start < 0 || $0.end <= $0.start
            || $0.end > transcript.audioSeconds
            || $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) {
        warn(.invalidSpeakerSpans)
        usableSpans = []
    } else {
        usableSpans = spans.sorted { $0.start < $1.start }
    }

    var turns: [SpeakerTurn] = []
    var turnStartIndex = raw.unicodeScalars.startIndex
    var currentSpeaker: String?
    var turnStart: Double = 0
    var turnEnd: Double = 0
    for word in words {
        var speaker = ""
        if !usableSpans.isEmpty {
            // ponytail: проверяем интервалы без собственного индекса. Индекс
            // нужен только при измеренной задержке на длинных расшифровках.
            let matches = usableSpans.filter { $0.start < word.end && $0.end > word.start }
            let speakers = Set(matches.map(\.speaker))
            if speakers.count > 1 {
                warn(.overlappingSpeakers)
            } else if let candidate = speakers.first {
                var coveredUntil = word.start
                for span in matches {
                    guard span.start <= coveredUntil else { break }
                    coveredUntil = max(coveredUntil, span.end)
                }
                if coveredUntil >= word.end { speaker = candidate }
                else { warn(.unassignedSpeech) }
            } else {
                warn(.unassignedSpeech)
            }
        }
        if speaker != currentSpeaker {
            if let currentSpeaker {
                let text = String(raw.unicodeScalars[turnStartIndex..<word.range.lowerBound])
                turns.append(SpeakerTurn(speaker: currentSpeaker, text: text,
                                         start: turnStart, end: turnEnd))
            }
            currentSpeaker = speaker
            turnStartIndex = word.range.lowerBound
            turnStart = word.start
        }
        turnEnd = word.end
    }
    if let currentSpeaker {
        turns.append(SpeakerTurn(speaker: currentSpeaker,
                                 text: String(raw.unicodeScalars[turnStartIndex...]),
                                 start: turnStart, end: turnEnd))
    }
    // Проверка по байтам: Swift String equality допускает Unicode normalization.
    guard turns.map(\.text).joined().utf8.elementsEqual(raw.utf8) else {
        return fallback(.textMismatch)
    }
    let knownSpeakers = turns.filter { !$0.speaker.isEmpty }.count
    let quality: MeetingSpeakerQuality = knownSpeakers == 0 ? .unavailable
        : knownSpeakers == turns.count ? .diarized : .partial
    return MeetingTranscriptSnapshot(rawText: raw, turns: turns, timingQuality: .aligned,
                                     speakerQuality: quality, warnings: warnings)
}

private struct MeetingAlignedWord {
    var range: Range<String.Index>
    let start: Double
    var end: Double
}

/// SentencePiece сохраняет границу слова как ▁ или ведущий пробел. Сопоставляем
/// скаляры буквально, разрешая различия только в пробельных разделителях.
/// Пунктуация, регистр, числа и непокрытый хвост требуют полного raw fallback.
private func meetingAlignedWords(raw: String, tokens: [DictationTokenTiming]) -> [MeetingAlignedWord]? {
    let scalars = raw.unicodeScalars
    var cursor = scalars.startIndex
    var words: [MeetingAlignedWord] = []
    for token in tokens {
        let piece = token.token.replacingOccurrences(of: "▁", with: " ").unicodeScalars
        guard piece.contains(where: { !$0.properties.isWhitespace }) else { continue }
        let lowerBound = cursor
        var firstContent = true
        var startsWord = words.isEmpty || (cursor > scalars.startIndex
            && scalars[scalars.index(before: cursor)].properties.isWhitespace)
        var previousWasWhitespace = false
        for scalar in piece {
            if scalar.properties.isWhitespace {
                if previousWasWhitespace { continue }
                previousWasWhitespace = true
                let before = cursor
                while cursor < scalars.endIndex, scalars[cursor].properties.isWhitespace {
                    cursor = scalars.index(after: cursor)
                }
                // Ведущий marker первого слова может отсутствовать в rawText.
                guard cursor != before || cursor == scalars.startIndex || cursor == scalars.endIndex else {
                    return nil
                }
                if firstContent { startsWord = true }
            } else {
                previousWasWhitespace = false
                if firstContent {
                    while cursor < scalars.endIndex, scalars[cursor].properties.isWhitespace {
                        startsWord = true
                        cursor = scalars.index(after: cursor)
                    }
                }
                guard cursor < scalars.endIndex, scalars[cursor] == scalar else { return nil }
                cursor = scalars.index(after: cursor)
                firstContent = false
            }
        }
        if startsWord {
            words.append(MeetingAlignedWord(range: lowerBound..<cursor, start: token.start, end: token.end))
        } else {
            words[words.count - 1].range = words[words.count - 1].range.lowerBound..<cursor
            words[words.count - 1].end = token.end
        }
    }
    guard scalars[cursor...].allSatisfy({ $0.properties.isWhitespace }) else { return nil }
    return words
}
