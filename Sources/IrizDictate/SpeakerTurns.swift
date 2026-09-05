// Сшивка расшифровки с дорожками говорящих.
//
// Распознаватель отдаёт слова со временем, диаризатор - отрезки «кто говорит».
// Здесь они сводятся в реплики: кто, что и когда сказал. Это ядро протокола
// встречи и судебного заседания, и оно чистое - ни моделей, ни файлов, ни
// разрешений системы. Проверяется пробой на выдуманных временах.
//
// ГЛАВНОЕ РЕШЕНИЕ. Слово приписывается говорящему по ПЕРЕКРЫТИЮ отрезков, а не
// по точке начала. Начало слова попадает в чужой отрезок постоянно: люди
// перебивают друг друга, а границы диаризации плывут на десятые доли секунды.
// Приписка по началу давала бы первое слово каждой реплики предыдущему
// говорящему - в протоколе заседания это меняет, кто что заявил.
//
// ВТОРОЕ РЕШЕНИЕ. Реплика не рвётся на паузе внутри одного говорящего. Человек
// думает вслух, и разрыв в полсекунды не означает новой реплики; новая реплика
// начинается тогда, когда меняется говорящий. Иначе протокол превращается в
// список обрывков.
import Foundation

/// Отрезок речи одного говорящего, как его видит диаризатор.
public struct SpeakerSpan: Equatable, Sendable {
    /// Метка диаризатора: «спикер 1», «спикер 2». Имя человека подставляется
    /// отдельно и хранится отдельно.
    public let speaker: String
    public let start: Double
    public let end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Реплика: кто, что и когда.
public struct SpeakerTurn: Equatable, Sendable {
    public let speaker: String
    public let text: String
    public let start: Double
    public let end: Double

    public init(speaker: String, text: String, start: Double, end: Double) {
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Сшивка слов и дорожек в реплики.
public func speakerTurns(tokens: [DictationTokenTiming],
                         spans: [SpeakerSpan]) -> [SpeakerTurn] {
    guard !tokens.isEmpty else { return [] }
    let sortedTokens = tokens.sorted { $0.start < $1.start }
    let sortedSpans = spans.sorted { $0.start < $1.start }

    var turns: [SpeakerTurn] = []
    var currentSpeaker: String?
    var words: [String] = []
    var turnStart: Double = 0
    var turnEnd: Double = 0

    func closeTurn() {
        guard let speaker = currentSpeaker, !words.isEmpty else { return }
        turns.append(SpeakerTurn(speaker: speaker,
                                 text: words.joined(separator: " "),
                                 start: turnStart,
                                 end: turnEnd))
        words = []
    }

    for token in sortedTokens {
        let speaker = speakerForToken(token, spans: sortedSpans)
        if speaker != currentSpeaker {
            closeTurn()
            currentSpeaker = speaker
            turnStart = token.start
        }
        words.append(token.token)
        turnEnd = token.end
    }
    closeTurn()
    return turns
}

/// Кому принадлежит слово: тот говорящий, с чьим отрезком перекрытие больше.
///
/// Слово, не попавшее ни в один отрезок, отдаётся ближайшему по времени, а не
/// теряется. Потерянное слово в протоколе заседания хуже неверно приписанного:
/// приписку видно и можно поправить, пропажу не видно вовсе.
func speakerForToken(_ token: DictationTokenTiming, spans: [SpeakerSpan]) -> String? {
    guard !spans.isEmpty else { return nil }
    var best: (speaker: String, overlap: Double)?
    for span in spans {
        let overlap = min(token.end, span.end) - max(token.start, span.start)
        guard overlap > 0 else { continue }
        if best == nil || overlap > best!.overlap {
            best = (span.speaker, overlap)
        }
    }
    if let best { return best.speaker }

    // Перекрытия нет: слово упало в паузу между отрезками. Отдаём ближайшему.
    let middle = (token.start + token.end) / 2
    return spans.min(by: { distance(from: middle, to: $0) < distance(from: middle, to: $1) })?.speaker
}

private func distance(from time: Double, to span: SpeakerSpan) -> Double {
    if time < span.start { return span.start - time }
    if time > span.end { return time - span.end }
    return 0
}

/// Имена говорящих: метка диаризатора -> имя человека.
///
/// Хранится отдельно от расшифровки и переживает перезапуск: владелец
/// подставляет имена один раз, и во второй встрече с теми же участниками они
/// не должны спрашиваться заново. Ключ - имя дела или встречи, чтобы «спикер 1»
/// из одного заседания не стал именем из другого.
public struct SpeakerNames: Codable, Equatable, Sendable {
    public private(set) var names: [String: String]

    public init(names: [String: String] = [:]) {
        self.names = names
    }

    public mutating func set(_ name: String, for speaker: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: speaker)
        } else {
            names[speaker] = trimmed
        }
    }

    /// Как показывать говорящего. Без подставленного имени показывается метка
    /// диаризатора: пустое место в протоколе хуже технической метки.
    public func display(_ speaker: String) -> String {
        names[speaker] ?? speaker
    }
}

/// Реплики с подставленными именами.
public func speakerTurnsNamed(_ turns: [SpeakerTurn], names: SpeakerNames) -> [SpeakerTurn] {
    turns.map {
        SpeakerTurn(speaker: names.display($0.speaker),
                    text: $0.text, start: $0.start, end: $0.end)
    }
}
