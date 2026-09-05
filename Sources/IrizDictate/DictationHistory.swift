// Модель окна истории надиктовок — свой код, чистые функции без AppKit.
//
// Почему отдельным файлом: живое окно под `swift test` не наблюдается, поэтому
// сюда вынесено всё, что проверяется целиком — чтение каталога, порядок,
// фильтр поиска, обрезка превью, что именно сносить при удалении. В окне
// (DictationHistoryWindow.swift) остаётся только рисование и клавиши.
import CoreGraphics
import Foundation
import IrizCore

/// Одна запись истории: каталог надиктовки и её сырьё.
///
/// `label` — имя каталога, оно же метка времени. Это ОДНОВРЕМЕННО ключ
/// сортировки и то, что показывается владельцу. Ключ именно имя, а не mtime:
/// после импорта из старого приложения mtime врёт (см. PromptEnvelope.swift,
/// `latestDictation`) — папки пишутся на диск в обратном порядку номеров.
public struct DictationHistoryEntry: Equatable, Identifiable {
    let directory: URL
    public let label: String
    /// Сырьё — ответ ASR байт в байт. Есть всегда, иначе записи нет.
    let text: String
    /// То, что фактически ушло в поле (inserted.txt), если файл есть.
    let insertedText: String?
    /// Готовый промпт, даже если фокус сменился или вставка не удалась.
    let generatedText: String?

    public var id: String { directory.path }

    /// Подтверждённая вставка точнее всего. Если её нет, prompt-запись отдаёт
    /// готовый `generated.txt`, а не сырую надиктовку. `prompt.md` здесь не читается.
    public var displayText: String { insertedText ?? generatedText ?? text }

    init(directory: URL,
         text: String,
         insertedText: String? = nil,
         generatedText: String? = nil) {
        self.directory = directory
        self.label = directory.lastPathComponent
        self.text = text
        self.insertedText = insertedText
        self.generatedText = generatedText
    }
}

// MARK: - Чтение каталога

/// Собирает историю из каталога `dictations`, свежие первыми.
///
/// Правила отбора те же, что у перечислителя промпт-режима: только подкаталоги,
/// только с `raw.txt`, скрытые пропускаются. Иначе история и промпт-режим
/// разошлись бы в том, что считается надиктовкой.
public func dictationHistoryEntries(in dictationsRoot: URL,
                             fileManager: FileManager = .default) -> [DictationHistoryEntry] {
    let urls = (try? fileManager.contentsOfDirectory(
        at: dictationsRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []

    return urls
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
        .compactMap { directory -> DictationHistoryEntry? in
            let rawURL = directory.appendingPathComponent(DICTATION_RAW_FILE_NAME)
            guard let data = fileManager.contents(atPath: rawURL.path),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let insertedURL = directory.appendingPathComponent(DICTATION_INSERTED_FILE_NAME)
            let inserted = fileManager.contents(atPath: insertedURL.path)
                .flatMap { String(data: $0, encoding: .utf8) }
            let generatedURL = directory.appendingPathComponent(DICTATION_GENERATED_PROMPT_FILE_NAME)
            let generated = fileManager.contents(atPath: generatedURL.path)
                .flatMap { String(data: $0, encoding: .utf8) }
            return DictationHistoryEntry(directory: directory,
                                         text: text,
                                         insertedText: inserted,
                                         generatedText: generated)
        }
}

// MARK: - Поиск

/// Находит ли запись запрос. Пустой запрос находит всё.
///
/// `.diacriticInsensitive` — и есть решение задачи «ё»: `ещё` находит `еще`
/// и наоборот. Проверено прогоном, а не предположением; побочный эффект того
/// же флага — `й` сводится к `и` (`йод` → `иод`), то есть поиск чуть шире
/// буквального. Для поиска по подстроке это приемлемо, промах по «ё» — нет.
/// `.caseInsensitive` нужен потому, что 99 надиктовок из 100 начинаются с
/// заглавной, а владелец набирает строчными.
func dictationHistoryMatches(text: String, query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    return text.range(of: trimmed,
                      options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

public func filteredDictationHistory(_ entries: [DictationHistoryEntry],
                              query: String) -> [DictationHistoryEntry] {
    entries.filter { dictationHistoryMatches(text: $0.displayText, query: query) }
}

// MARK: - Показ строки

public let DICTATION_HISTORY_PREVIEW_LIMIT = 220

/// Превью строки списка: переводы строк сплющены, длинный текст обрезан.
/// Обрезка по символам, а не по байтам — иначе кириллица режется посередине.
public func dictationHistoryPreview(_ text: String,
                             limit: Int = DICTATION_HISTORY_PREVIEW_LIMIT) -> String {
    let flat = text
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard limit > 0 else { return "" }
    guard flat.count > limit else { return flat }
    return String(flat.prefix(limit)) + "…"
}

/// Человекочитаемая метка времени из имени каталога.
///
/// На диске живут ДВА формата имён: `2026-08-04_10-00-00` от живой диктовки и
/// ISO8601 от импортёра старого приложения. Разобрать не удалось — показываем
/// имя как есть: соврать про время записи нельзя, а найти её по имени
/// каталога владелец сможет.
public func dictationHistoryTimeLabel(_ label: String,
                               locale: Locale = Locale(identifier: "ru_RU"),
                               timeZone: TimeZone = .current) -> String {
    guard let date = dictationHistoryDate(label) else { return label }
    let out = DateFormatter()
    out.locale = locale
    out.timeZone = timeZone
    out.dateFormat = "d MMMM, HH:mm"
    return out.string(from: date)
}

func dictationHistoryDate(_ label: String) -> Date? {
    // Дубликаты одной секунды store нумерует суффиксом «-2», «-3» — он в
    // разбор времени не входит.
    let stem = label.replacingOccurrences(of: #"-\d+$"#,
                                          with: "",
                                          options: .regularExpression)
    let local = DateFormatter()
    local.locale = Locale(identifier: "en_US_POSIX")
    local.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    if let date = local.date(from: stem) ?? local.date(from: label) { return date }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    return iso.date(from: stem) ?? iso.date(from: label)
}

// MARK: - Клавиши

/// Что делает нажатие в окне истории. Решение вынесено из монитора событий,
/// чтобы раскладка клавиш проверялась тестом, а не живым окном.
enum DictationHistoryKeyAction: Equatable {
    case insertSelected
    case copySelected
    case close
    /// Сдвиг выделения: −1 вверх, +1 вниз.
    case moveSelection(Int)
    /// Нажатие нас не касается — пусть уходит в поле поиска.
    case passThrough
}

func dictationHistoryKeyAction(keyCode: CGKeyCode,
                               charactersIgnoringModifiers: String?,
                               hasCommand: Bool) -> DictationHistoryKeyAction {
    if hasCommand {
        // ⌘⌫ здесь СОЗНАТЕЛЬНО не занят. Это документированный системный
        // шорткат текстового поля («удалить от курсора до начала строки»), а
        // поле поиска в окне в фокусе по умолчанию: владелец набрал запрос,
        // привычно жмёт ⌘⌫ вычистить поле — и по мышечной памяти сносит
        // расшифровку речи клиента. Удаление живёт в контекстном меню, где его
        // нельзя нажать не глядя.
        switch charactersIgnoringModifiers?.lowercased() {
        case "c": return .copySelected
        default: return .passThrough
        }
    }
    switch keyCode {
    case ESCAPE_KEYCODE: return .close
    case RETURN_KEYCODE, HISTORY_KEYPAD_ENTER_KEYCODE: return .insertSelected
    case HISTORY_ARROW_UP_KEYCODE: return .moveSelection(-1)
    case HISTORY_ARROW_DOWN_KEYCODE: return .moveSelection(1)
    default: return .passThrough
    }
}

let HISTORY_ARROW_UP_KEYCODE: CGKeyCode = 126
let HISTORY_ARROW_DOWN_KEYCODE: CGKeyCode = 125
let HISTORY_KEYPAD_ENTER_KEYCODE: CGKeyCode = 76
/// Клавиша ⌫. Ни с Command, ни без него окно её не забирает — она целиком
/// принадлежит полю поиска. Названа, чтобы тест мог прибить это гвоздём.
let HISTORY_DELETE_KEYCODE: CGKeyCode = 51

// MARK: - Выделение

/// Держит выделение внутри списка. Список меняется под руками — фильтр поиска
/// сужает его, удаление сокращает, — поэтому индекс всегда прижимается, а не
/// проверяется вызывающим.
func clampedHistorySelection(_ index: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(0, index), count - 1)
}

/// Сдвиг выделения без заворота: на первой записи ↑ оставляет на первой.
/// Заворот в короткой истории читается как «прыгнуло куда-то само».
func movedHistorySelection(from index: Int, by delta: Int, count: Int) -> Int {
    clampedHistorySelection(clampedHistorySelection(index, count: count) + delta, count: count)
}

// MARK: - Удаление

/// Что удалить, чтобы после записи не осталось ни файла, ни каталога.
/// Сносится КАТАЛОГ целиком: в нём лежат `raw.txt`, `inserted.txt` и, если
/// был промпт-режим, `prompt.md` и `generated.txt`. Оставленный пустой каталог перечислитель
/// промпт-режима пропустит, но в Finder владелец увидит мусор.
func dictationHistoryRemovalTarget(for entry: DictationHistoryEntry) -> URL {
    entry.directory
}

/// Отправляет запись в Корзину — каталогом целиком. Именно в Корзину, а НЕ
/// `removeItem`: в каталоге лежит первичный документ, расшифровка речи клиента.
/// Промах владельца обязан быть обратимым — та же политика, что у карантина
/// дублей (решение Д-13 этой сессии). Из Корзины запись возвращается, из
/// небытия — нет.
///
/// Возвращает путь в Корзине, если система его назвала. Бросает, если каталога
/// уже нет либо файловая система отказала; причина уходит в лог вызывающим.
@discardableResult
func removeDictationHistoryEntry(_ entry: DictationHistoryEntry,
                                 fileManager: FileManager = .default) throws -> URL? {
    var trashed: NSURL?
    try fileManager.trashItem(at: dictationHistoryRemovalTarget(for: entry),
                              resultingItemURL: &trashed)
    return trashed as URL?
}

/// Текст подтверждения «очистить всё» — с ПОКАЗАННЫМ числом записей до
/// удаления. Без числа владелец подтверждает вслепую.
///
/// Про Корзину сказано прямо: записи уезжают туда, а не в небытие. Обещать
/// «без возможности вернуть», когда возможность есть, — врать владельцу о
/// судьбе документов клиентов.
func dictationHistoryClearConfirmation(count: Int) -> String {
    guard count > 0 else { return "Удалять нечего — история пуста." }
    return "Переместить в Корзину \(count) \(russianDictationWordForm(count))?"
}

func russianDictationWordForm(_ count: Int) -> String {
    let tail = abs(count) % 100
    if (11...14).contains(tail) { return "надиктовок" }
    switch tail % 10 {
    case 1: return "надиктовку"
    case 2, 3, 4: return "надиктовки"
    default: return "надиктовок"
    }
}
