// Локальная очистка речи: снятие запинок с оглядкой на контекст.
//
// ЗДЕСЬ БЫЛА МОЯ ОШИБКА, И ОНА СТОИТ ТОГО, ЧТОБЫ БЫТЬ ЗАПИСАННОЙ.
//
// Враждебный разбор убил почти все правила снятия запинок юридическими
// контрпримерами: «ЭЭ» - электроэнергия в договоре энергоснабжения, «м-м» -
// машино-место в ДДУ, «эм» - буква в государственном знаке. Я их принял и
// собрал очистку, которая почти ничего не чистит.
//
// Владелец поправил, и поправка бьёт в основание: контрпримеры взяты из
// ПИСЬМЕННОГО юридического текста, а на вход приходит РАСПОЗНАННАЯ РЕЧЬ. Это
// разные корпуса. Диктуя договор энергоснабжения, человек произносит
// «электроэнергии», и распознаватель пишет слово целиком; «ЭЭ» в расшифровке
// взяться неоткуда, потому что так не говорят. Сокращение живёт на бумаге, а
// не во рту. Разбор судил не тот корпус, и я это пропустил.
//
// ЧТО ОСТАЛОСЬ ПРАВДОЙ. Буква, названная вслух, в расшифровке выглядит ровно
// как запинка: «подпункт э», «серия эм», «знак а». Отличает их КОНТЕКСТ -
// слово рядом, а не сам звук. Значит и правило контекстное, а не запретительное.
//
// Что кодом не берётся - уходит во внешний режим, где есть понимание смысла:
// там очистка агрессивнее, и владелец включает её руками.
//
// Все контрпримеры обоих разборов стали пробами: и те, где чистить НАДО, и те,
// где текст обязан остаться нетронутым.
import Foundation

/// Усилители: их удвоение осмысленно и повтором не считается.
private let speechCleanupIntensifiers: Set<String> = [
    "очень", "совсем", "чуть", "еле", "едва", "давно", "долго", "далеко",
    "глубоко", "тихо", "быстро", "сильно", "много", "крепко", "часто",
    "редко", "рано", "поздно", "низко", "высоко", "близко",
]

/// Предлоги, повтор которых вокруг вставки - запинка.
private let speechCleanupPrepositions: Set<String> = [
    "в", "во", "на", "с", "со", "к", "ко", "по", "за", "из", "от", "до",
    "для", "при", "про", "над", "под", "без", "через",
]

/// Слова, после которых следующий короткий токен - НАЗВАННАЯ ВСЛУХ БУКВА, а не
/// запинка: «подпункт э», «серия эм», «корпус а». Отличить их от звука можно
/// только по соседу, поэтому список закрытый и проверяется на два токена влево.
private let speechCleanupLetterContext: Set<String> = [
    "пункт", "пункте", "пункта", "подпункт", "подпункте", "подпункта",
    "буква", "букве", "буквы", "литера", "литере", "литеры",
    "графа", "графе", "графы", "столбец", "столбце",
    "приложение", "приложении", "приложения", "норма", "норме", "нормы",
    "серия", "серии", "знак", "знаке", "знака", "корпус", "корпусе",
    "строение", "строении", "класс", "классе", "часть", "части",
    "п", "пп", "абзац", "абзаце", "раздел", "разделе",
]

/// Токены-запинки. Пишутся так, как их отдаёт распознаватель со слуха.
private let speechCleanupFillerPattern =
    "(?:э+|э(?:-э)+|ээ+|м{2,}|м(?:-м)+|эм+|э-м|а{3,}|а(?:-а)+|ну-?у{1,3}|мда|ага)"

/// Числительные словом: пара с числом не трогается никогда.
private let speechCleanupNumerals: Set<String> = [
    "ноль", "один", "одна", "два", "две", "три", "четыре", "пять", "шесть",
    "семь", "восемь", "девять", "десять", "сто", "тысяча", "миллион",
]

/// Очистка на этой машине. Наружу не уходит ничего.
public func speechCleanupLocal(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    var result = ""
    result.reserveCapacity(text.count)
    // Текст режется на защищённые и открытые куски. Внутри защищённых не
    // трогается ничего: чужие слова цитируются как сказаны, и правка внутри
    // цитаты меняет показания.
    for piece in speechCleanupSegments(text) {
        result += piece.protected ? piece.text : speechCleanupOpenText(piece.text)
    }
    return result
}

struct SpeechCleanupSegment {
    let text: String
    let protected: Bool
}

/// Разбор текста на защищённые и открытые куски.
///
/// Защищены: содержимое ЗАКРЫТОЙ пары кавычек и строка прямой речи, начатая
/// с тире. Незакрытая кавычка защищает только до конца своего абзаца - иначе
/// одна кривая кавычка выключила бы очистку до конца документа.
///
/// Вложенные кавычки считаются глубиной, а не первой попавшейся парой:
/// «Я работал в ООО «Ромашка», и, э-э, не выезжал» - при наивном счёте
/// защищённая зона обрывалась бы на внутренней кавычке, и хвост показаний
/// оставался голым.
func speechCleanupSegments(_ text: String) -> [SpeechCleanupSegment] {
    var segments: [SpeechCleanupSegment] = []
    for (index, paragraph) in text.components(separatedBy: "\n").enumerated() {
        if index > 0 { segments.append(SpeechCleanupSegment(text: "\n", protected: true)) }
        // Строка прямой речи защищается целиком: это воспроизведённая реплика.
        if paragraph.trimmingCharacters(in: .whitespaces).hasPrefix("-")
            || paragraph.trimmingCharacters(in: .whitespaces).hasPrefix("\u{2014}") {
            segments.append(SpeechCleanupSegment(text: paragraph, protected: true))
            continue
        }
        segments.append(contentsOf: speechCleanupQuoteSegments(paragraph))
    }
    return segments
}

private func speechCleanupQuoteSegments(_ paragraph: String) -> [SpeechCleanupSegment] {
    var segments: [SpeechCleanupSegment] = []
    var current = ""
    var depth = 0
    for character in paragraph {
        switch character {
        case "\u{00AB}", "\u{201E}":  // открывающие кавычки
            if depth == 0 {
                segments.append(SpeechCleanupSegment(text: current, protected: false))
                current = ""
            }
            depth += 1
            current.append(character)
        case "\u{00BB}", "\u{201C}":  // закрывающие кавычки
            current.append(character)
            depth = max(0, depth - 1)
            if depth == 0 {
                segments.append(SpeechCleanupSegment(text: current, protected: true))
                current = ""
            }
        default:
            current.append(character)
        }
    }
    // Хвост: если кавычка осталась незакрытой, он защищается - в открытой
    // цитате мы не знаем, где кончаются чужие слова.
    segments.append(SpeechCleanupSegment(text: current, protected: depth > 0))
    return segments
}

/// Очистка открытого куска: четыре правила, пережившие проверку.
private func speechCleanupOpenText(_ text: String) -> String {
    var out = text
    out = speechCleanupFillers(out)
    out = speechCleanupLeadingNu(out)
    out = speechCleanupWordRepeats(out)
    out = speechCleanupRepeatedPreposition(out)
    return out
}

/// Снятие запинок: «э», «э-э», «ммм», «эм», «а-а-а».
///
/// Токен снимается, если он стоит отдельным словом строчными буквами И рядом
/// нет признаков названной вслух буквы:
///   - слева в двух токенах нет слова из `speechCleanupLetterContext`;
///   - соседний токен не число (государственный знак: «Т 512 эм 116»);
///   - справа не идёт «)» или «.» - так выглядит маркер перечня «э)».
///
/// Прописные формы не трогаются вовсе: «ЭМ» в расшифровке речи означает, что
/// человек произнёс аббревиатуру по буквам намеренно.
func speechCleanupFillers(_ text: String) -> String {
    let pattern = "(?<![\\p{L}-])(\\p{Ll}[\\p{Ll}-]*)?(\\s*)(?<![\\p{L}-])"
        + speechCleanupFillerPattern + "(?![\\p{L}-])"
    guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\d-])"
        + speechCleanupFillerPattern + "(?![\\p{L}\\d-])") else { return text }
    _ = pattern

    var result = text
    var searchStart = result.startIndex
    while searchStart < result.endIndex {
        let range = NSRange(searchStart..<result.endIndex, in: result)
        guard let match = regex.firstMatch(in: result, range: range),
              let hit = Range(match.range, in: result) else { break }
        let token = String(result[hit])
        if speechCleanupFillerIsRemovable(token, in: result, at: hit) {
            var lower = hit.lowerBound
            var upper = hit.upperBound
            // Вправо: своя запятая запинки и пробелы за ней. Распознаватель
            // ставит их на паузу дыхания, а не на смысл.
            while upper < result.endIndex, result[upper] == "," || result[upper] == " " {
                upper = result.index(after: upper)
            }
            // Влево: пробелы и своя запятая. Обе запятые снимать нельзя -
            // оставшаяся одна вклинивается между подлежащим и сказуемым и
            // меняет разбор: «Директор, Иванов подписал акт».
            while lower > result.startIndex, result[result.index(before: lower)] == " " {
                lower = result.index(before: lower)
            }
            if lower > result.startIndex, result[result.index(before: lower)] == "," {
                lower = result.index(before: lower)
            }
            let offset = result.distance(from: result.startIndex, to: lower)
            result.removeSubrange(lower..<upper)
            // Стык: если по обе стороны выреза оказались буквы, между ними
            // обязан остаться пробел, иначе слова слипаются.
            let cutIndex = result.index(result.startIndex, offsetBy: offset)
            if cutIndex > result.startIndex, cutIndex < result.endIndex {
                let left = result[result.index(before: cutIndex)]
                let right = result[cutIndex]
                if (left.isLetter || left.isNumber) && (right.isLetter || right.isNumber) {
                    result.insert(" ", at: cutIndex)
                }
            }
            searchStart = result.index(result.startIndex, offsetBy: min(offset, result.count))
        } else {
            searchStart = hit.upperBound
        }
    }
    return result
}

/// Можно ли снять этот токен: решает КОНТЕКСТ, а не сам звук.
func speechCleanupFillerIsRemovable(_ token: String, in text: String,
                                    at range: Range<String.Index>) -> Bool {
    // Прописная форма - намеренно произнесённая аббревиатура, не запинка.
    guard token.allSatisfy({ !$0.isUppercase }) else { return false }

    // Маркер перечня: «э)» или «э.» после числа-пункта.
    let after = text[range.upperBound...].prefix(1)
    if after == ")" { return false }

    // Два токена слева: «подпункт э», «серия эм».
    let before = String(text[..<range.lowerBound])
    let words = before.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .suffix(2).map { String($0).lowercased() }
    if words.contains(where: { speechCleanupLetterContext.contains($0) }) { return false }
    // Число вплотную слева или справа: государственный знак, «Т 512 эм 116».
    if let last = words.last, last.allSatisfy(\.isNumber) { return false }
    let nextWord = text[range.upperBound...]
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .first.map(String.init) ?? ""
    if !nextWord.isEmpty, nextWord.allSatisfy(\.isNumber) { return false }
    return true
}

/// Начальное «Ну» в начале предложения, включая «Ну вот», «Ну и», «Ну а».
///
/// Требуется ЗАГЛАВНАЯ буква. Это не косметика: строчное «ну» после «Петров
/// А. В.» стоит в середине фразы, а точка после инициала позиционно читается
/// как конец предложения. Опора на регистр отделяет одно от другого без
/// разбора смысла.
func speechCleanupLeadingNu(_ text: String) -> String {
    let pattern = "(^|(?<=[.!?]\\s))Ну(?:\\s+(?:вот|и|а))?[,]?\\s+(\\p{Ll})"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    var result = text
    var offset = 0
    for match in regex.matches(in: text, range: range) {
        guard let whole = Range(match.range, in: text),
              let letter = Range(match.range(at: 2), in: text) else { continue }
        let replacement = String(text[letter]).uppercased()
        let start = result.index(result.startIndex, offsetBy: text.distance(from: text.startIndex, to: whole.lowerBound) + offset)
        let end = result.index(result.startIndex, offsetBy: text.distance(from: text.startIndex, to: whole.upperBound) + offset)
        let prefix = match.range(at: 1).length > 0 ? String(text[Range(match.range(at: 1), in: text)!]) : ""
        result.replaceSubrange(start..<end, with: prefix + replacement)
        offset += (prefix.count + replacement.count) - text.distance(from: whole.lowerBound, to: whole.upperBound)
    }
    return result
}

/// Немедленный повтор слова схлопывается до одного.
///
/// Семь запретов, и каждый стоит за контрпримером:
///   знак между словами  «Иванов, Иванов» - перечисление, не запинка
///   усилители           «очень очень важно» - осмысленное усиление
///   числа               «два два» - номер или дата
///   второй с заглавной  «дело Дело» - потерянная точка между предложениями
///   отрицания           «не не» меняет утверждение на противоположное
///   неточное совпадение совпадение по корню повтором не считается
///   кавычки             защищены разбором выше
func speechCleanupWordRepeats(_ text: String) -> String {
    let pattern = "(?<![\\p{L}-])(\\p{L}+)(\\s+)(\\p{L}+)(?![\\p{L}-])"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    var result = text
    var searchStart = result.startIndex
    while searchStart < result.endIndex {
        let range = NSRange(searchStart..<result.endIndex, in: result)
        guard let match = regex.firstMatch(in: result, range: range),
              let whole = Range(match.range, in: result),
              let firstRange = Range(match.range(at: 1), in: result),
              let secondRange = Range(match.range(at: 3), in: result) else { break }
        let first = String(result[firstRange])
        let second = String(result[secondRange])
        if speechCleanupIsStutterRepeat(first: first, second: second) {
            result.replaceSubrange(whole, with: first)
            searchStart = result.index(whole.lowerBound, offsetBy: first.count)
        } else {
            searchStart = firstRange.upperBound
        }
    }
    return result
}

func speechCleanupIsStutterRepeat(first: String, second: String) -> Bool {
    guard first.lowercased() == second.lowercased() else { return false }
    let lower = first.lowercased()
    guard !speechCleanupIntensifiers.contains(lower) else { return false }
    guard !speechCleanupNumerals.contains(lower) else { return false }
    guard lower != "не", lower != "ни" else { return false }
    guard !first.contains(where: \.isNumber), !second.contains(where: \.isNumber) else { return false }
    // Первый со строчной, второй с заглавной - между ними потерянная точка.
    if let a = first.first, let b = second.first, a.isLowercase, b.isUppercase { return false }
    return true
}

/// Повтор предлога вокруг вставки: «в, значит, в суд» -> «в суд».
///
/// Только закрытый список предлогов и только точный повтор: за пределами
/// списка та же форма бывает знаменательным словом.
func speechCleanupRepeatedPreposition(_ text: String) -> String {
    let pattern = "(?<![\\p{L}-])(\\p{L}+),\\s+([^,]{1,30}),\\s+(\\p{L}+)(?=\\s)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    var result = text
    var searchStart = result.startIndex
    while searchStart < result.endIndex {
        let range = NSRange(searchStart..<result.endIndex, in: result)
        guard let match = regex.firstMatch(in: result, range: range),
              let whole = Range(match.range, in: result),
              let firstRange = Range(match.range(at: 1), in: result),
              let insertRange = Range(match.range(at: 2), in: result),
              let secondRange = Range(match.range(at: 3), in: result) else { break }
        let first = String(result[firstRange]).lowercased()
        let second = String(result[secondRange]).lowercased()
        if first == second, speechCleanupPrepositions.contains(first) {
            let kept = String(result[insertRange]) + ", " + String(result[secondRange])
            result.replaceSubrange(whole, with: kept)
            searchStart = result.index(whole.lowerBound, offsetBy: kept.count)
        } else {
            searchStart = firstRange.upperBound
        }
    }
    return result
}

/// Замена по образцу с молчаливым отказом при кривом образце: очистка не имеет
/// права ронять диктовку.
private func speechCleanupReplace(_ text: String, pattern: String, with template: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
}
