import Foundation
import IrizCore

public enum PromptMode: String, Sendable {
    case addition = "ДОБАВКА"
    case correction = "ПРАВКА"
    case prompt = "ПРОМПТ"
    case undefined = "НЕ ОПРЕДЕЛЕНО"
}

public struct TextMatch: Equatable, Sendable {
    public let text: String
    public let position: Int
}

public struct TermReplacement: Equatable, Sendable {
    public let source: String
    public let canonical: String
}

public struct PromptMarkup: Sendable {
    public let mode: PromptMode
    public let characterCount: Int
    public let negations: [TextMatch]
    public let deictics: [TextMatch]
    public let spokenNumbersAndDates: [TextMatch]
    public let listMarkers: [TextMatch]
    public let selfCorrections: [TextMatch]
    public let terms: [TermReplacement]
}

public enum PromptEnvelopeError: Error {
    case noDictations
    case unreadableRaw
}

public struct PromptEnvelopeBuilder: Sendable {
    public static let defaultTerms: [String: String] = [
        // Только общедоступные имена моделей: словарь уезжает в чужие руки внутри
        // бинарника, поэтому личного тут нет — ни имён частных проектов, ни
        // записей о том, как распознавание расслышало владельца. Своё он
        // добавляет себе сам, и наружу это не уезжает.
        "клод": "Claude", "кодекс": "Codex", "кими": "Kimi",
    ]

    public init() {}

    public func latestDictation(in root: URL) throws -> URL {
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
                FileManager.default.fileExists(atPath: url.appendingPathComponent("raw.txt").path)
        }
        // Ключ сортировки — ИМЯ папки, а не время изменения файла. Имя и есть отметка
        // времени надиктовки (ISO8601), оно не меняется, если что-то тронуло файл.
        // Время изменения тут врёт: импорт из старого приложения нумерует папки назад
        // от текущего момента, но пишет их в порядке «свежие первыми», поэтому
        // последней на диск ложится САМАЯ СТАРАЯ папка. По mtime «последней надиктовкой»
        // оказывалась бы запись столетней давности.
        guard let latest = urls.max(by: { $0.lastPathComponent < $1.lastPathComponent })
        else { throw PromptEnvelopeError.noDictations }
        return latest
    }

    public func build(for directory: URL, termsURL: URL? = nil) throws -> String {
        let rawURL = directory.appendingPathComponent("raw.txt")
        guard let data = try? Data(contentsOf: rawURL), let raw = String(data: data, encoding: .utf8) else {
            throw PromptEnvelopeError.unreadableRaw
        }
        let terms = loadTerms(from: termsURL)
        let markup = analyze(raw, hasPreviousPrompt: hasPreviousPrompt(before: directory))
        return render(raw: raw, rawURL: rawURL, markup: markup, terms: terms)
    }

    public func analyze(_ raw: String, hasPreviousPrompt: Bool = false, terms: [String: String] = Self.defaultTerms) -> PromptMarkup {
        let beginning = String(raw.prefix(160))
        // Основа, а не словоформа: владелец говорит и «дополни», и «дополню», и «дополнить».
        // По «дополни\w*» форма «дополню» не ловилась — после основы идёт «ю», а не «и».
        let addition = matches(beginning, patterns: [#"\bдополн\w*"#, #"\bдобав\w*"#, #"\bкроме того\b"#, #"\bтакже\b"#])
        let correction = matches(raw, patterns: [#"\bнет\b"#, #"\bне надо\b"#, #"\bточнее\b"#, #"\bвернее\b"#])
        let oldReference = matches(raw, patterns: [#"\bпрежн\w*"#, #"\bпредыдущ\w*"#, #"\bдо этого\b"#, #"\bто,? что\b"#])
        let asksPrompt = matches(raw, patterns: [#"\bпромпт\w*"#, #"\bпромп\w*"#])
        let actionWithObject = matches(raw, patterns: [#"\b(сделай|создай|напиши|исправь|добавь|удали|проверь|собери)\s+[^\s,.!?]+"#])
        let mode: PromptMode
        if hasPreviousPrompt && !addition.isEmpty { mode = .addition }
        else if !correction.isEmpty && !oldReference.isEmpty { mode = .correction }
        else if !asksPrompt.isEmpty || !actionWithObject.isEmpty { mode = .prompt }
        else { mode = .undefined }

        return PromptMarkup(
            mode: mode,
            characterCount: raw.count,
            negations: matches(raw, patterns: [#"\b(не|нет|ни|без|нельзя|никогда)\b"#]),
            deictics: matches(raw, patterns: [
                #"\bэт(?:о|от|а|у|и|ого|ому|им|ом|ой|ою|ими|их)\b"#,
                #"\bтекущ\p{L}*\b"#,
                #"\bтам\b"#,
                #"\bтот\b"#,
                #"\bтуда\b"#,
                #"\bкак обсуждали\b"#,
                #"\bв прошлый раз\b"#,
                #"\b(?:то,?\s*)?на ч[её]м остановились\b"#,
            ]),
            spokenNumbersAndDates: numberMatches(raw),
            listMarkers: matches(raw, patterns: [#"\bпервое\b"#, #"\bвторое\b"#, #"\bтретье\b"#, #"\bкроме того\b"#, #"\bну и\b"#, #"\bи ещё\b"#, #"\bи еще\b"#, #"\bа именно\b"#]),
            selfCorrections: matches(raw, patterns: [#"\bто есть\b"#, #"\bточнее\b"#, #"\bвернее\b"#, #"\bнет(?=,)"#, #"\bхотя\b"#]),
            terms: termMatches(raw, terms: terms)
        )
    }

    private func render(raw: String, rawURL: URL, markup: PromptMarkup, terms _: [String: String]) -> String {
        return """
        СМЛТЛК · РЕЧЬ → ПРОМПТ
        Сырьё (канон, байт в байт): \(displayPath(rawURL.path))
        Результат LLM: только PromptSpec по зафиксированной JSON Schema.
        Готовый промпт и prompt.md собирает приложение; модель их не пишет.

        \(PromptGenerationContract().request(raw: raw, markup: markup))
        """
    }

    public func hasPreviousPrompt(before directory: URL) -> Bool {
        let siblings = (try? FileManager.default.contentsOfDirectory(at: directory.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        return siblings.filter { $0.lastPathComponent < directory.lastPathComponent }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("prompt.md").path) } ?? false
    }

    private func loadTerms(from url: URL?) -> [String: String] {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return Self.defaultTerms }
        return decoded
    }
}

private func matches(_ text: String, patterns: [String]) -> [TextMatch] {
    patterns.flatMap { pattern -> [TextMatch] in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            TextMatch(text: ns.substring(with: $0.range), position: text.distance(from: text.startIndex, to: Range($0.range, in: text)?.lowerBound ?? text.startIndex))
        }
    }.sorted { $0.position < $1.position }
}

private func numberMatches(_ text: String) -> [TextMatch] {
    let words = "ноль|один|одна|два|две|три|четыре|пять|шесть|семь|восемь|девять|десять|одиннадцать|двенадцать|тринадцать|четырнадцать|пятнадцать|шестнадцать|семнадцать|восемнадцать|девятнадцать|двадцать|тридцать|сорок|пятьдесят|сто|первого|второго|третьего|четвертого|пятого|шестого|седьмого|восьмого|девятого|десятого|января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря"
    return matches(text, patterns: ["\\b\\d+(?:[.:/-]\\d+)*\\b", "\\b(?:\(words))(?:\\s+(?:\(words))){0,4}\\b"])
}

private func termMatches(_ text: String, terms: [String: String]) -> [TermReplacement] {
    terms.keys.sorted { $0.count > $1.count }.flatMap { source -> [TermReplacement] in
        matches(text, patterns: ["(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: source))(?![\\p{L}\\p{N}])"]).map {
            TermReplacement(source: $0.text, canonical: terms[source]!)
        }
    }
}

private func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
