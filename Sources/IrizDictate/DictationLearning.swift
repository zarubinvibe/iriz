// Обучение словаря из правок после вставки.
//
// Человек надиктовал, текст встал в поле, человек поправил слово руками. Эта
// правка - самое дешёвое обучение, какое бывает: она уже сделана, её не надо
// просить. Осталось её заметить и предложить в словарь.
//
// ГРАНИЦА, КОТОРУЮ ЭТОТ ФАЙЛ ДЕРЖИТ.
//
// Чужие поля мы не читаем как содержимое. Сравнение идёт только с тем текстом,
// который вставили МЫ, и наружу этого файла выходят только пары слов - «было» и
// «стало». Ни одна строка чужого поля не сохраняется, не логируется и не
// уезжает никуда: она живёт внутри одного вызова функции и умирает вместе с ним.
//
// Почему это важно назвать: диктовка с доступом к полям ввода отличается от
// клавиатурного шпиона ровно тем, что она забывает прочитанное. Здесь это
// свойство кода, а не обещание в документации, и его держит проба
// `парыНеСодержатЧужогоТекста`.
//
// ЧТО ЛОВИМ И ЧЕГО НЕ ЛОВИМ.
//
// Ловим замену ОДНОГО слова на одно: «нещатно» -> «нещадно». Это словарная
// единица, её можно применить в следующий раз.
//
// Не ловим: вставку слов, удаление слов, перестановку, замену нескольких слов
// подряд. Это правка смысла, а не распознавания, и в словарь ей нельзя - она
// сломает следующую диктовку, где те же слова стояли осмысленно.
import Foundation

/// Пара «было -> стало», найденная в правке человека.
public struct DictationLearnedPair: Equatable, Sendable {
    public let heard: String
    public let fixed: String

    public init(heard: String, fixed: String) {
        self.heard = heard
        self.fixed = fixed
    }
}

/// Слова текста вместе с их границами: правка сравнивается по словам, а не по
/// буквам. Побуквенное сравнение на «нещатно/нещадно» даёт замену одной буквы,
/// из которой словарной пары не собрать.
func dictationLearningWords(_ text: String) -> [String] {
    text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
        .map(String.init)
        .filter { !$0.isEmpty }
}

/// Пары для словаря из правки человека.
///
/// - Parameters:
///   - inserted: текст, который вставили мы.
///   - current: текст поля ПОСЛЕ правки. Живёт только внутри вызова.
public func dictationLearnedPairs(inserted: String, current: String) -> [DictationLearnedPair] {
    let before = dictationLearningWords(inserted)
    let after = dictationLearningWords(current)
    guard !before.isEmpty, !after.isEmpty else { return [] }

    // Правка ищется в ОКНЕ вокруг нашей вставки, а не по всему полю. В поле
    // может лежать чужой текст любой длины, и выравнивать по нему целиком
    // значит ловить чужие слова как «правку».
    guard let window = dictationLearningWindow(before: before, after: after) else { return [] }

    // Длины окна и вставки совпадают - значит слова не добавляли и не удаляли,
    // и позиции сравнимы напрямую. Разная длина означает правку структуры, а
    // не распознавания: такое в словарь не идёт.
    guard window.count == before.count else { return [] }

    var pairs: [DictationLearnedPair] = []
    for (heard, fixed) in zip(before, window) where heard != fixed {
        guard dictationLearningPairIsUsable(heard: heard, fixed: fixed) else { return [] }
        pairs.append(DictationLearnedPair(heard: heard, fixed: fixed))
    }

    // Больше двух изменённых слов - это переписывание, а не исправление
    // расслышанного. Порог не круглое число ради красоты: одна правка обычна,
    // две бывают, три подряд означают, что человек передумал.
    guard pairs.count <= 2 else { return [] }
    return pairs
}

/// Окно в тексте поля, соответствующее нашей вставке.
///
/// Ищется по опорным словам: берутся первое и последнее слово вставки, которые
/// человек не тронул. Если тронуты оба края, окно не строится - и это честно:
/// без опоры мы не знаем, где кончается наш текст и начинается чужой.
private func dictationLearningWindow(before: [String], after: [String]) -> [String]? {
    guard let first = before.first, let last = before.last else { return nil }

    if before.count == 1 {
        // Одно слово: окно строится только если поле состоит ровно из него.
        // Иначе мы не отличим правку своего слова от чужого текста рядом.
        return after.count == 1 ? after : nil
    }

    // Хватает ОДНОЙ уцелевшей опоры, и это не послабление, а разбор случая:
    // человек чаще всего правит именно крайнее слово вставки. Требовать оба
    // края целыми значит пропускать самый частый вид правки - первая версия
    // так и делала, и проба это поймала.
    if let start = after.firstIndex(of: first) {
        let end = start + before.count
        if end <= after.count {
            return Array(after[start..<end])
        }
    }
    if let end = after.lastIndex(of: last) {
        let start = end - before.count + 1
        if start >= 0 {
            return Array(after[start...end])
        }
    }
    // Обе опоры тронуты - молчим, а не гадаем: без якоря мы не знаем, где
    // кончается наш текст и начинается чужой.
    return nil
}

/// Годится ли пара в словарь.
///
/// Отсев здесь строгий нарочно: словарь применяется молча к каждой следующей
/// диктовке, и мусорная пара будет портить текст, пока её не заметят руками.
private func dictationLearningPairIsUsable(heard: String, fixed: String) -> Bool {
    guard !heard.isEmpty, !fixed.isEmpty else { return false }
    // Слишком короткое слово в словаре опасно: «а» -> «и» сломает всё.
    guard heard.count >= 3 else { return false }
    // Слова должны быть похожи. Замена «понедельник» -> «вторник» - это правка
    // смысла, и в словарь ей нельзя: распознавание тут ни при чём.
    return dictationLearningSimilar(heard, fixed)
}

/// Похожи ли слова настолько, чтобы считать правку исправлением расслышанного.
///
/// Порог - треть длины: «нещатно/нещадно» проходит (одна буква из семи),
/// «понедельник/вторник» нет.
func dictationLearningSimilar(_ a: String, _ b: String) -> Bool {
    let lowerA = Array(a.lowercased())
    let lowerB = Array(b.lowercased())
    // Регистровая правка - всегда исправление: «омвд» -> «ОМВД».
    if lowerA == lowerB { return true }
    let distance = dictationLearningDistance(lowerA, lowerB)
    let limit = max(1, min(lowerA.count, lowerB.count) / 3)
    return distance <= limit
}

/// Расстояние Левенштейна. Своя реализация вместо зависимости: строки здесь
/// короче двадцати символов, и тянуть ради этого пакет незачем.
func dictationLearningDistance(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}
