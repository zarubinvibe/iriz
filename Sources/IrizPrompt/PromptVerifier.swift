import Foundation

public enum VerificationVerdict: String, Sendable {
    case yes = "ДА"
    case no = "НЕТ"
    case notApplicable = "н/п"
    case needsEyes = "ТРЕБУЕТ ГЛАЗ"
}

public struct VerificationItem: Sendable {
    public let id: String
    public let verdict: VerificationVerdict
    public let detail: String
    public let blocking: Bool
}

public struct VerificationReport: Sendable {
    public let items: [VerificationItem]
    public var hasBlockingFailure: Bool { items.contains { $0.blocking && $0.verdict == .no } }

    public var text: String {
        items.map { "\($0.id) \($0.verdict.rawValue) — \($0.detail)" }.joined(separator: "\n") + "\n"
    }
}

public enum PromptVerifierError: Error {
    case filesMissingOrUnreadable
}

public struct PromptVerifier: Sendable {
    public init() {}

    public func verify(directory: URL) throws -> VerificationReport {
        guard let rawData = try? Data(contentsOf: directory.appendingPathComponent("raw.txt")),
              let promptData = try? Data(contentsOf: directory.appendingPathComponent("prompt.md")),
              let raw = String(data: rawData, encoding: .utf8),
              let prompt = String(data: promptData, encoding: .utf8) else {
            throw PromptVerifierError.filesMissingOrUnreadable
        }
        return verify(raw: raw, prompt: prompt)
    }

    public func verify(raw: String, prompt: String) -> VerificationReport {
        let sections = parseSections(prompt)
        let executableLines = (sections["ТРЕБОВАНИЯ"] ?? []) + (sections["ЗАПРЕТЫ"] ?? [])
        let classifiedLines = (sections["НЕ ВОССТАНОВЛЕНО"] ?? []) + (sections["КОНТЕКСТ"] ?? [])
        let anchors = (executableLines + classifiedLines).flatMap { quotedStrings(in: $0) }
        let short = raw.count < 60

        let embeddedRaw = between(prompt, "<сырьё>", "</сырьё>")
        let b1 = embeddedRaw == nil || embeddedRaw == raw
        let anchorFailures = executableLines.flatMap { line in quotedStrings(in: line) }.filter { !raw.contains($0) }
        let missingAnchors = executableLines.filter { quotedStrings(in: $0).isEmpty }
        let b2 = missingAnchors.isEmpty && anchorFailures.isEmpty
        let badProvenance = executableLines.filter { line in
            if line.contains("[Р]") { return false }
            if line.contains("[В]") { return !line.lowercased().contains("источник") }
            return true
        }
        let defaultsInside = executableLines.filter { $0.contains("[У]") }
        let defaultsOutside = prompt.split(separator: "\n").map(String.init).filter { $0.contains("[У]") && !executableLines.contains($0) }
        let badDefaults = defaultsOutside.filter { !$0.lowercased().contains("источник") || !$0.contains("/") }
        let b3 = badProvenance.isEmpty && defaultsInside.isEmpty && badDefaults.isEmpty

        let rawNegations = tokenMatches(raw, pattern: "\\b(не|нет|ни|без|нельзя|никогда)\\b")
        let coveredRanges = anchors.flatMap { allRanges(of: $0, in: raw) }
        let lost = rawNegations.filter { match in !coveredRanges.contains { NSLocationInRange(match.range.location, $0) } }
        let promptWithoutQuotes = executableLines.map(removingQuotedStrings).joined(separator: "\n")
        let normalizeNegation: (String) -> String = { token in
            ["не", "нет", "ни", "без"].contains(token.lowercased()) ? "обычное" : token.lowercased()
        }
        let rawNegationCounts = Dictionary(grouping: rawNegations.map { normalizeNegation($0.text) }, by: { $0 }).mapValues(\.count)
        let promptNegationCounts = Dictionary(grouping: tokenMatches(promptWithoutQuotes, pattern: "\\b(не|нет|ни|без|нельзя|никогда)\\b").map { normalizeNegation($0.text) }, by: { $0 }).mapValues(\.count)
        let addedTokens = promptNegationCounts.flatMap { token, count in
            Array(repeating: token, count: max(0, count - rawNegationCounts[token, default: 0]))
        }
        let b5 = lost.isEmpty && addedTokens.isEmpty

        let suspiciousFacts = executableLines.flatMap { line -> [String] in
            // Нумерация пунктов и маркеры списка — структура артефакта, а не факт из речи.
            // Пути к файлам — это ПЕЧАТЬ ИСТОЧНИКА, которую требует Б3; её нельзя объявлять
            // выдумкой, иначе метка [В] с источником становится технически невозможной.
            let body = removingPaths(removingTags(removingQuotedStrings(stripListMarker(line))))
            let numbers = tokenMatches(body, pattern: "\\b\\d+(?:[.:/-]\\d+)*\\b").map(\.text)
            // caseSensitive: true — иначе \p{Lu} под caseInsensitive матчит ЛЮБУЮ букву,
            // и проверка «имена имеют опору» превращается в «каждое слово длиннее двух
            // букв обязано быть в сырье»: «указать», «владелец», «источник» — выдумка.
            let names = tokenMatches(body, pattern: "(?<![.\\[])\\b[\\p{Lu}][\\p{L}\\p{N}_-]{2,}\\b", caseSensitive: true)
                .filter { m in
                    let token = m.text
                    // ЗАГЛАВНЫЕ целиком — это либо аббревиатура (HTML, JSON), либо запрет,
                    // который спека требует писать капсом. Проверяем всегда.
                    if token == token.uppercased() { return true }
                    // Иначе заглавная может быть просто началом предложения. Слово,
                    // капитализованное только позицией, именем собственным не является.
                    return !isSentenceInitial(m.range, in: body)
                }
                .map(\.text)
            return (numbers + names).filter { !hasSupport($0, in: raw) && !prompt.contains("«\($0)» →") }
        }
        let b6 = suspiciousFacts.isEmpty

        let unresolvedDeictics = linesForDeicticVerification(prompt).flatMap { line -> [RegexMatch] in
            let found = tokenMatches(removingQuotedStrings(line), pattern: "\\b(это|там|тот файл|как обсуждали|в прошлый раз)\\b")
            if line.lowercased().contains("источник") || line.contains("НЕ ВОССТАНОВЛЕНО") { return [] }
            return found
        }
        let b8 = unresolvedDeictics.isEmpty
        let boundaries = sections["ГРАНИЦЫ ДЕЙСТВИЙ"] ?? []
        let b10 = !boundaries.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let executableLength = executableLines.joined(separator: "\n").count
        // Обвязка — это УЛИКИ: восстановления с напечатанными источниками, карта сегментов,
        // термины. Голый множитель 6x наказывал за доказательность (чем честнее агент сходил
        // на диск, тем краснее) и вырождался на коротком входе: 6 x 13 знаков = 78, куда
        // не влезает даже один источник. Пол в 1500 знаков снимает обе патологии, не ослабляя
        // проверку исполняемой части — а раздувают именно её.
        // Каждый напечатанный источник — это улика, которую сам же гейт требует (Б3).
        // Считать её раздутием значит штрафовать за то, что агент честно сходил на диск.
        let printedSources = prompt.split(separator: "\n").filter { $0.lowercased().contains("источник") }.count
        let wrapperLimit = max(raw.count * 6, 1500) + printedSources * 300
        let p1 = executableLength <= raw.count * 2 && prompt.count <= wrapperLimit
        let imperativePattern = "\\b(сделай|создай|напиши|исправь|добавь|удали|проверь|собери|используй|запусти|доведи)\\b"
        let p2 = executableLines.allSatisfy { tokenMatches(removingQuotedStrings($0), pattern: imperativePattern).count <= 1 }

        func item(_ id: String, _ verdict: VerificationVerdict, _ detail: String, blocking: Bool = true) -> VerificationItem {
            VerificationItem(id: id, verdict: verdict, detail: detail, blocking: blocking)
        }
        return VerificationReport(items: [
            item("Б1", b1 ? .yes : .no, b1 ? "файл сырья читается; встроенная копия, если есть, совпадает" : "встроенное сырьё не совпадает с raw.txt"),
            item("Б2", short ? .notApplicable : (b2 ? .yes : .no),
                 short ? "короткий сквозной вход — якоря не требуются"
                       : (b2 ? "якоря найдены в сырье" : "нет якоря или он не встречается в raw.txt")),
            item("Б3", short ? .notApplicable : (b3 ? .yes : .no),
                 short ? "короткий сквозной вход — метки не требуются"
                       : (b3 ? "метки провенанса разобраны" : "нарушены правила [Р]/[В]/[У]")),
            item("Б4", short ? .notApplicable : .needsEyes, "сверить судьбу каждого сегмента"),
            item("Б5", b5 ? .yes : .no, "потеряно: \(lost.count), добавлено: \(addedTokens.count)"),
            item("Б6", b6 ? .yes : .no, b6 ? "числа и имена имеют опору" : "без опоры: \(suspiciousFacts.joined(separator: ", "))"),
            item("Б7", short ? .notApplicable : .needsEyes, "проверить развилки и метку БЛОКИРУЕТ ИСПОЛНЕНИЕ"),
            item("Б8", short ? .notApplicable : (b8 ? .yes : .no), b8 ? "неразрешённых дейктиков нет" : "есть дейктики без источника"),
            item("Б9", short ? .notApplicable : .needsEyes, "сверить ОЦЕНКУ с требованиями"),
            item("Б10", short ? .notApplicable : (b10 ? .yes : .no), b10 ? "блок границ непуст" : "нет непустого блока ГРАНИЦЫ ДЕЙСТВИЙ"),
            item("П1", p1 ? .yes : .no, "исполняемая часть \(executableLength) при норме \(raw.count * 2), обвязка \(prompt.count) при норме \(wrapperLimit)", blocking: false),
            item("П2", short ? .notApplicable : (p2 ? .yes : .no), p2 ? "не больше одного императива на строку" : "есть строки с несколькими императивами", blocking: false),
            item("П3", short ? .notApplicable : .needsEyes, "проверить pass/fail-критерий готовности", blocking: false),
            item("П4", short ? .notApplicable : .needsEyes, "проверить координаты, не вклейки, и отсутствие ссылок на диалог", blocking: false),
        ])
    }
}

private struct RegexMatch { let text: String; let range: NSRange }

private func tokenMatches(_ text: String, pattern: String, caseSensitive: Bool = false) -> [RegexMatch] {
    let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { RegexMatch(text: ns.substring(with: $0.range), range: $0.range) }
}

private func quotedStrings(in text: String) -> [String] {
    tokenMatches(text, pattern: #"«([^»]+)»|⟨([^⟩]+)⟩"#).map { match in
        String(match.text.dropFirst().dropLast())
    }
}

private func removingQuotedStrings(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"«[^»]*»|⟨[^⟩]*⟩"#) else { return text }
    return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
}

private func allRanges(of needle: String, in haystack: String) -> [NSRange] {
    guard !needle.isEmpty else { return [] }
    let ns = haystack as NSString
    var result: [NSRange] = []
    var search = NSRange(location: 0, length: ns.length)
    while true {
        let range = ns.range(of: needle, options: [], range: search)
        if range.location == NSNotFound { break }
        result.append(range)
        let next = NSMaxRange(range)
        search = NSRange(location: next, length: ns.length - next)
    }
    return result
}

private func between(_ text: String, _ opening: String, _ closing: String) -> String? {
    guard let start = text.range(of: opening), let end = text.range(of: closing, range: start.upperBound..<text.endIndex) else { return nil }
    return String(text[start.upperBound..<end.lowerBound])
}

private func parseSections(_ prompt: String) -> [String: [String]] {
    var result: [String: [String]] = [:]
    var current: String?
    for rawLine in prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if let heading = promptSectionHeading(rawLine) { current = heading; result[heading] = []; continue }
        if let current, !rawLine.trimmingCharacters(in: .whitespaces).isEmpty { result[current, default: []].append(rawLine) }
    }
    return result
}

private func linesForDeicticVerification(_ prompt: String) -> [String] {
    let ignoredSections = Set(["РАЗВИЛКИ", "НЕ ВОССТАНОВЛЕНО", "ИСПОЛНЯЕМЫЙ ПРОМПТ"])
    var result: [String] = []
    var insideRaw = false
    var ignoredSection = false

    for line in prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        let opensRaw = line.contains("<сырьё>")
        let closesRaw = line.contains("</сырьё>")
        if insideRaw {
            if closesRaw { insideRaw = false }
            continue
        }
        if opensRaw {
            insideRaw = !closesRaw
            continue
        }
        if let heading = promptSectionHeading(line) {
            ignoredSection = ignoredSections.contains(heading)
            continue
        }
        if !ignoredSection { result.append(line) }
    }
    return result
}

private func promptSectionHeading(_ line: String) -> String? {
    let headings = Set(["ТРЕБОВАНИЯ", "ЗАПРЕТЫ", "ГРАНИЦЫ ДЕЙСТВИЙ", "КОНТЕКСТ", "ОЦЕНКА", "РАЗВИЛКИ", "НЕ ВОССТАНОВЛЕНО", "КРИТЕРИЙ ГОТОВНОСТИ", "ИСПОЛНЯЕМЫЙ ПРОМПТ"])
    let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "#*:"))
    return headings.contains(normalized) ? normalized : nil
}

/// Есть ли у слова опора в сырье. Точного совпадения мало: спека требует писать запреты
/// ЗАГЛАВНЫМИ («НЕ ТРОГАТЬ ТЕСТЫ»), а в сырье владелец сказал «не трогай тесты» — другая
/// словоформа. Без учёта основы гейт краснел бы на каждом правильно оформленном запрете,
/// то есть был бы бесполезен. Для кириллицы сверяем основу, для латиницы и чисел — точно.
private func hasSupport(_ token: String, in raw: String) -> Bool {
    if raw.localizedCaseInsensitiveContains(token) { return true }
    let isCyrillic = token.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "А"..."я").contains($0) || $0 == "ё" || $0 == "Ё" }
    guard isCyrillic, token.count >= 5 else { return false }
    let stem = String(token.prefix(token.count - 2))
    return raw.localizedCaseInsensitiveContains(stem)
}

/// Убирает ведущий маркер списка: «1. », «2) », «- », «• ».
private func stripListMarker(_ line: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "^\\s*(?:[-•*]\\s*)?(?:\\d+[.)]\\s*)?") else { return line }
    let ns = line as NSString
    return regex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "")
}

/// Убирает пути к файлам: они печатаются как источник восстановления, а не как факт из речи.
private func removingPaths(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "[~/][^\\s,;]+") else { return text }
    let ns = text as NSString
    return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
}

/// Стоит ли слово в начале предложения — тогда его заглавная буква ничего не значит.
private func isSentenceInitial(_ range: NSRange, in text: String) -> Bool {
    let ns = text as NSString
    var i = range.location - 1
    while i >= 0, CharacterSet.whitespacesAndNewlines.contains(ns.character(at: i).unicodeScalar) { i -= 1 }
    if i < 0 { return true }
    return ".!?:\u{2014}".unicodeScalars.map { Character($0) }.contains(Character(ns.character(at: i).unicodeScalar))
}

private extension unichar {
    var unicodeScalar: Unicode.Scalar { Unicode.Scalar(self) ?? " " }
}

/// Убирает метки провенанса [Р] [В] [?] [У]: это разметка артефакта, а не содержание.
/// Без этого первое слово после метки считалось бы именем собственным — оно стоит после
/// «]», а не после точки, значит формально не начало предложения.
private func removingTags(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "\\[[РВ?У]\\]") else { return text }
    let ns = text as NSString
    return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
}
