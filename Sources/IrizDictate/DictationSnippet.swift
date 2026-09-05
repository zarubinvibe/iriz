// Заготовки: короткая фраза вслух — на её место встаёт сохранённый блок текста.
//
// Механизм тот же, что у словаря замен (`TranscriptCorrector`): точное
// совпадение словоформы с границами слова, регистр не важен, подстановка
// идёт ОДНИМ проходом вместе со словарём — раскрытая заготовка не может
// попасть под замену, а замена не может собрать триггер заготовки.
//
// Данные держим ОТДЕЛЬНО от словаря намеренно: у них разный размер (тело
// заготовки многострочное), разная цена ошибки и разный редактор. Один
// список на двоих превратил бы «шапка иска» и «эцп → ЭЦП» в одну кучу.
//
// Заводского набора нет и не будет: заводской словарь уже научил, что
// раздавать всем личные шапки и реквизиты — ошибка.
import Foundation

public struct DictationSnippet: Codable, Equatable, Sendable {
    /// Что произносится. Может быть из нескольких слов.
    public let trigger: String
    /// Что встаёт на место триггера. Может быть многострочным.
    public let body: String

    public init(trigger: String, body: String) {
        self.trigger = trigger
        self.body = body
    }
}

/// Ключ склейки дубликатов: пробелы схлопнуты, регистр снят. Ровно тот же
/// принцип, что у словаря, — иначе «Шапка Иска» и «шапка  иска» жили бы
/// в списке как две разные записи, а срабатывала бы всё равно одна.
func normalizedDictationSnippetTrigger(_ trigger: String) -> String {
    trigger
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .lowercased()
}

/// Причина, по которой запись не годится. Нужна импорту: он обязан назвать
/// файл негодным вслух, а не молча выкинуть строку.
enum DictationSnippetDefect: Error, Equatable {
    case emptyTrigger
    case emptyBody
    case triggerWithoutLetterOrDigit
    case triggerTooLong
    case bodyTooLong
    case forbiddenCharacter

    var message: String {
        switch self {
        case .emptyTrigger: "фраза заготовки пуста"
        case .emptyBody: "текст заготовки пуст"
        case .triggerWithoutLetterOrDigit:
            "во фразе нет ни буквы, ни цифры — такую заготовку нечем поймать в речи"
        case .triggerTooLong:
            "фраза длиннее \(MAX_DICTATION_SNIPPET_TRIGGER_BYTES) байт"
        case .bodyTooLong:
            "текст длиннее \(MAX_DICTATION_SNIPPET_BODY_BYTES) байт"
        case .forbiddenCharacter: "внутри есть нулевой байт"
        }
    }
}

/// Обрезает края и проверяет запись. Внутренние переводы строк в теле
/// сохраняются: многострочность — весь смысл заготовки.
func validatedDictationSnippet(_ snippet: DictationSnippet)
    -> Result<DictationSnippet, DictationSnippetDefect> {
    let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = snippet.body.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trigger.isEmpty, !normalizedDictationSnippetTrigger(trigger).isEmpty else {
        return .failure(.emptyTrigger)
    }
    guard !body.isEmpty else { return .failure(.emptyBody) }
    guard trigger.contains(where: { $0.isLetter || $0.isNumber }) else {
        return .failure(.triggerWithoutLetterOrDigit)
    }
    guard trigger.utf8.count <= MAX_DICTATION_SNIPPET_TRIGGER_BYTES else {
        return .failure(.triggerTooLong)
    }
    guard body.utf8.count <= MAX_DICTATION_SNIPPET_BODY_BYTES else {
        return .failure(.bodyTooLong)
    }
    guard !trigger.unicodeScalars.contains(where: { $0.value == 0 }),
          !body.unicodeScalars.contains(where: { $0.value == 0 }) else {
        return .failure(.forbiddenCharacter)
    }
    return .success(DictationSnippet(trigger: trigger, body: body))
}

/// Негодное молча выкидывается, дубликаты склеиваются по ключу — последняя
/// запись побеждает НА МЕСТЕ первой, чтобы порядок списка в редакторе не
/// прыгал. Ровно так же ведёт себя словарь замен.
func normalizedDictationSnippets(_ snippets: [DictationSnippet]) -> [DictationSnippet] {
    var result: [DictationSnippet] = []
    var indexByTrigger: [String: Int] = [:]

    for snippet in snippets {
        guard case .success(let cleaned) = validatedDictationSnippet(snippet) else { continue }
        let key = normalizedDictationSnippetTrigger(cleaned.trigger)
        if let existing = indexByTrigger[key] {
            result[existing] = cleaned
        } else {
            guard result.count < MAX_DICTATION_SNIPPETS else { continue }
            indexByTrigger[key] = result.count
            result.append(cleaned)
        }
    }

    return result
}
