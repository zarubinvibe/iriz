// Основано на SuperDictate (MIT, © 2026 Richard Courtman), коммит 83dd7e4.
// Постобработка расшифровки и решение о судьбе записи.
// Отличие от донора: фильтр слов-паразитов (FillerWordRemover) не взят —
// у владельца он выключен; параметр removeFillerWords удалён.
import Foundation

// MARK: - Пользовательские замены

public struct TranscriptCorrection: Codable, Equatable, Sendable {
    public let source: String
    public let replacement: String

    public init(source: String, replacement: String) {
        self.source = source
        self.replacement = replacement
    }
}

func normalizedTranscriptCorrectionSource(_ source: String) -> String {
    source
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .lowercased()
}

/// Причина негодности записи словаря. Раньше её знал только `guard` внутри
/// нормализации и молча выкидывал строку. Импорту файла молчать нельзя:
/// он обязан сказать, какая запись и чем плоха.
enum TranscriptCorrectionDefect: Error, Equatable {
    case emptySource
    case emptyReplacement
    case sourceTooLong
    case replacementTooLong
    case forbiddenCharacter

    var message: String {
        switch self {
        case .emptySource: "левая часть замены пуста"
        case .emptyReplacement: "правая часть замены пуста"
        case .sourceTooLong: "левая часть длиннее \(MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES) байт"
        case .replacementTooLong:
            "правая часть длиннее \(MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES) байт"
        case .forbiddenCharacter: "внутри есть нулевой байт"
        }
    }
}

func validatedTranscriptCorrection(_ correction: TranscriptCorrection)
    -> Result<TranscriptCorrection, TranscriptCorrectionDefect> {
    let source = correction.source.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacement = correction.replacement.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !source.isEmpty, !normalizedTranscriptCorrectionSource(source).isEmpty else {
        return .failure(.emptySource)
    }
    guard !replacement.isEmpty else { return .failure(.emptyReplacement) }
    guard source.utf8.count <= MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES else {
        return .failure(.sourceTooLong)
    }
    guard replacement.utf8.count <= MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES else {
        return .failure(.replacementTooLong)
    }
    guard !source.unicodeScalars.contains(where: { $0.value == 0 }),
          !replacement.unicodeScalars.contains(where: { $0.value == 0 }) else {
        return .failure(.forbiddenCharacter)
    }
    return .success(TranscriptCorrection(source: source, replacement: replacement))
}

func normalizedTranscriptCorrections(_ corrections: [TranscriptCorrection]) -> [TranscriptCorrection] {
    var result: [TranscriptCorrection] = []
    var indexBySource: [String: Int] = [:]

    for correction in corrections {
        guard case .success(let cleaned) = validatedTranscriptCorrection(correction) else { continue }
        let key = normalizedTranscriptCorrectionSource(cleaned.source)
        if let existing = indexBySource[key] {
            result[existing] = cleaned
        } else {
            guard result.count < MAX_TRANSCRIPT_CORRECTIONS else { continue }
            indexBySource[key] = result.count
            result.append(cleaned)
        }
    }

    return result
}

enum TranscriptCorrector {
    /// Что именно подставилось. Считаем раздельно: словарь и заготовки —
    /// разные обещания владельцу, и в логе они не должны сливаться.
    private enum Kind: Int {
        case snippet = 0
        case correction = 1
    }

    private struct Rule {
        let source: String
        let replacement: String
        let kind: Kind
    }

    private struct Match {
        let range: NSRange
        let replacement: String
        let kind: Kind
    }

    struct Outcome: Equatable {
        let text: String
        /// Сработавших замен словаря.
        let appliedCount: Int
        /// Раскрытых заготовок.
        let appliedSnippetCount: Int
    }

    /// Один проход на словарь и заготовки сразу. Это не оптимизация, а
    /// требование к смыслу: два прохода означали бы, что раскрытая заготовка
    /// попадает под словарь (шапка иска молча переписалась бы) или что замена
    /// собирает триггер заготовки из соседних слов. Здесь каждый участок
    /// текста подставляется ровно один раз.
    static func apply(to text: String,
                      corrections: [TranscriptCorrection],
                      snippets: [DictationSnippet] = []) -> Outcome {
        let rules = activeRules(corrections: corrections, snippets: snippets)
        guard !text.isEmpty, !rules.isEmpty else {
            return Outcome(text: text, appliedCount: 0, appliedSnippetCount: 0)
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [Match] = []

        for rule in rules {
            guard let pattern = pattern(for: rule.source),
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }

            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound else { return }
                guard !matches.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
                matches.append(Match(range: range, replacement: rule.replacement, kind: rule.kind))
            }
        }

        guard !matches.isEmpty else {
            return Outcome(text: text, appliedCount: 0, appliedSnippetCount: 0)
        }

        let rewritten = NSMutableString(string: text)
        for match in matches.sorted(by: { $0.range.location > $1.range.location }) {
            rewritten.replaceCharacters(in: match.range, with: match.replacement)
        }
        return Outcome(text: rewritten as String,
                       appliedCount: matches.filter { $0.kind == .correction }.count,
                       appliedSnippetCount: matches.filter { $0.kind == .snippet }.count)
    }

    /// Порядок решает споры: длинный источник бьёт короткий (иначе «а» съело
    /// бы «а б»), а при равной длине первой идёт заготовка — произнести целую
    /// фразу ради блока текста намереннее, чем совпасть с записью словаря.
    /// Хвост — алфавит, чтобы порядок не зависел от того, как список лёг.
    private static func activeRules(corrections: [TranscriptCorrection],
                                    snippets: [DictationSnippet]) -> [Rule] {
        let correctionRules = normalizedTranscriptCorrections(corrections).map {
            Rule(source: $0.source, replacement: $0.replacement, kind: .correction)
        }
        let snippetRules = normalizedDictationSnippets(snippets).map {
            Rule(source: $0.trigger, replacement: $0.body, kind: .snippet)
        }
        return (snippetRules + correctionRules).sorted { lhs, rhs in
            if lhs.source.count != rhs.source.count { return lhs.source.count > rhs.source.count }
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.source.localizedCaseInsensitiveCompare(rhs.source) == .orderedAscending
        }
    }

    private static func pattern(for source: String) -> String? {
        let parts = source
            .split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }
        return #"(?<![\p{L}\p{N}_])"# + parts.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}_])"#
    }
}

// MARK: - Починка <unk> → ё (Parakeet TDT v3 на русском)

enum SpeechModelTextRepair {
    /// Parakeet TDT v3 emits `<unk>` for Cyrillic "ё" in Russian text.
    /// For Russian and auto-detect (the app's default audience) the
    /// token is replaced with "ё"/"Ё". For every other language the
    /// token is genuinely unknown and is removed entirely so a stray
    /// Cyrillic character doesn't appear in English/French/etc. text.
    static func apply(to text: String,
                      language: DictationLanguage = .auto) -> String {
        guard text.localizedCaseInsensitiveContains("<unk>") else { return text }

        let replaceWithYo: Bool
        switch language {
        case .auto, .russian:
            replaceWithYo = true
        default:
            replaceWithYo = false
        }

        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            if matchesUnknownToken(in: text, at: index) {
                if replaceWithYo {
                    result.append(shouldCapitalizeYo(before: result) ? "Ё" : "ё")
                }
                index = text.index(index, offsetBy: 5)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }

        if !replaceWithYo {
            result = result
                .replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func matchesUnknownToken(in text: String, at index: String.Index) -> Bool {
        let token = "<unk>"
        guard let end = text.index(index, offsetBy: token.count, limitedBy: text.endIndex) else {
            return false
        }
        return text[index..<end].lowercased() == token
    }

    private static func shouldCapitalizeYo(before prefix: String) -> Bool {
        guard let last = prefix.last(where: { !$0.isWhitespace }) else { return true }
        return ".!?".contains(last)
    }
}

// MARK: - Решения по записи

enum RecordingReleaseAction: Equatable {
    case discardTooShort(duration: Double)
    case transcribe(duration: Double)
}

func recordingReleaseAction(capturedSampleCount: Int,
                            sampleRate: Double = SAMPLE_RATE,
                            minimumClipSeconds: Double = MIN_CLIP_SECONDS) -> RecordingReleaseAction {
    let duration = sampleRate > 0 ? Double(max(0, capturedSampleCount)) / sampleRate : 0
    return duration < minimumClipSeconds
        ? .discardTooShort(duration: duration)
        : .transcribe(duration: duration)
}

struct DictationTextProcessingResult: Equatable {
    let text: String
    let appliedCorrectionCount: Int
    let appliedSnippetCount: Int

    init(text: String, appliedCorrectionCount: Int, appliedSnippetCount: Int = 0) {
        self.text = text
        self.appliedCorrectionCount = appliedCorrectionCount
        self.appliedSnippetCount = appliedSnippetCount
    }
}

func removingFinalPeriod(from text: String) -> String {
    guard text.last == "." else { return text }
    let textWithoutFinalPeriod = text.dropLast()
    guard textWithoutFinalPeriod.last != "." else { return text }
    return String(textWithoutFinalPeriod)
}

/// Порядок проходов: trim → SpeechModelTextRepair → TranscriptCorrector
/// (словарь и заготовки одним проходом) → снятие финальной точки (если
/// включено). `rawTranscript` не меняется ни на одном шаге: на диск ложится
/// он сам, байт в байт, а всё это — только текст к вставке.
func processedDictationText(rawTranscript: String,
                            corrections: [TranscriptCorrection],
                            snippets: [DictationSnippet] = [],
                            removeFinalPeriod: Bool = false,
                            language: DictationLanguage = .auto) -> DictationTextProcessingResult {
    let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    let repaired = SpeechModelTextRepair.apply(to: trimmed, language: language)
    let corrected = TranscriptCorrector.apply(to: repaired,
                                              corrections: corrections,
                                              snippets: snippets)

    let finalText = removeFinalPeriod
        ? removingFinalPeriod(from: corrected.text)
        : corrected.text
    return DictationTextProcessingResult(text: finalText,
                                         appliedCorrectionCount: corrected.appliedCount,
                                         appliedSnippetCount: corrected.appliedSnippetCount)
}

// MARK: - Текст к вставке

func pastedText(from correctedTranscript: String, suffix: PasteSuffix) -> String {
    switch suffix {
    case .appendSpace:
        return correctedTranscript + " "
    case .none:
        return correctedTranscript
    case .appendNewline:
        return correctedTranscript + "\n"
    }
}
