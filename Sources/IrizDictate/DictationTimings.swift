// Тайминги токенов распознавателя — улика для будущего разреза абзацев по паузам.
//
// ЗАЧЕМ. FEATURES.md §3 откладывает «абзацы по паузам» с условием «вернуться,
// когда tokenTimings начнут сохраняться». Условие блокировало само себя:
// проверить его нельзя, пока Transcriber выбрасывает тайминги сразу после
// вызова FluidAudio. Здесь они ложатся на диск рядом с сырьём — timings.json,
// тот же каталог надиктовки, те же права 0600.
//
// ЧЕГО ЗДЕСЬ НЕТ. Разреза абзацев. Этот файл только перестаёт уничтожать
// данные; решение «где абзац» принимает будущая фича, уже по замеру.
//
// Сырьё не трогается ничем отсюда: raw.txt пишется отдельным вызовом и
// байт в байт остаётся тем, что вернул распознаватель.
import Foundation

/// Один токен распознавателя с границами внутри клипа.
///
/// Токен — ровно то, что отдал распознаватель (SentencePiece: «▁» на границе
/// слова, куски слов отдельными записями). Ничего не склеиваем и не чистим:
/// склейка в слова — работа читателя, а испорченную улику назад не вернуть.
public struct DictationTokenTiming: Codable, Equatable, Sendable {
    public let token: String
    /// Секунды от начала клипа.
    public let start: Double
    public let end: Double
    /// Уверенность распознавателя, 0…1.
    public let confidence: Double

    /// Санитайзер на входе, а не на чтении: в файл не должно попасть ничего,
    /// от чего у читателя получится NaN. Распознаватель изредка отдаёт
    /// нефинитные значения, и один такой токен обесценил бы весь файл.
    public init(token: String, start: Double, end: Double, confidence: Double) {
        self.token = token
        let safeStart = start.isFinite ? max(0, start) : 0
        let safeEnd = end.isFinite ? max(safeStart, end) : safeStart
        self.start = safeStart
        self.end = safeEnd
        self.confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
    }
}

/// Содержимое `timings.json` рядом с `raw.txt`.
///
/// `schemaVersion` — чтобы читатель, написанный через полгода, отличил свой
/// формат от чужого и не гадал по форме ключей.
public struct DictationTimings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// Длительность клипа по данным распознавателя, секунды.
    public let audioSeconds: Double
    public let tokens: [DictationTokenTiming]

    public init(audioSeconds: Double,
                tokens: [DictationTokenTiming],
                schemaVersion: Int = DictationTimings.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.audioSeconds = audioSeconds.isFinite ? max(0, audioSeconds) : 0
        self.tokens = tokens
    }

    /// Пустое сохранять незачем: файл-обещание без данных хуже отсутствующего.
    public var isEmpty: Bool { tokens.isEmpty }

    /// Стабильная форма на диске: ключи по алфавиту, перенос строк —
    /// чтобы файл читался глазами и диффился построчно.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> DictationTimings {
        try JSONDecoder().decode(DictationTimings.self, from: data)
    }
}
