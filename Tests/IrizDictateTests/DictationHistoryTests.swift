// Тесты окна истории надиктовок.
//
// Живое окно под `swift test` не наблюдается: нет NSApplication, нет экрана,
// нет фокуса чужого приложения. Поэтому проверяются РЕШЕНИЯ — чтение каталога,
// порядок, фильтр поиска, раскладка клавиш, что именно сносится при удалении,
// восстановление буфера обмена — и работа с диском на ВРЕМЕННОМ каталоге.
//
// В ~/Library/Application Support/smltlk эти тесты не заходят: корень
// хранилища всегда подменён, там живые расшифровки речи владельца.
import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import IrizDictate

// MARK: - Опора: временное хранилище надиктовок

@MainActor
private func withDictationsRoot(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("smltlk-history-\(UUID().uuidString)", isDirectory: true)
    let dictations = root.appendingPathComponent("dictations", isDirectory: true)
    try FileManager.default.createDirectory(at: dictations, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(dictations)
}

/// Заводит запись руками, а не через DictationStore: нужны точные имена папок
/// (в том числе задом наперёд по времени записи на диск).
private func makeEntryOnDisk(in dictations: URL,
                             label: String,
                             raw: String,
                             inserted: String? = nil,
                             generated: String? = nil) throws -> URL {
    let dir = dictations.appendingPathComponent(label, isDirectory: true)
    try FileManager.default.createDirectory(at: dir,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try Data(raw.utf8).write(to: dir.appendingPathComponent("raw.txt"))
    if let inserted {
        try Data(inserted.utf8).write(to: dir.appendingPathComponent("inserted.txt"))
    }
    if let generated {
        try Data(generated.utf8).write(to: dir.appendingPathComponent("generated.txt"))
    }
    return dir
}

/// Удаляет запись и ВЫЧИЩАЕТ за собой Корзину владельца: удаление теперь
/// отправляет папки в ~/.Trash, и прогон тестов не имеет права оставлять там
/// свой мусор. Возвращает путь в Корзине — по нему тест проверяет обратимость,
/// пока копия ещё жива.
@discardableResult
private func trashEntryAndCleanUp(_ entry: DictationHistoryEntry,
                                  inspect: (URL) throws -> Void = { _ in }) throws -> URL? {
    let trashed = try removeDictationHistoryEntry(entry)
    if let trashed {
        try inspect(trashed)
        try? FileManager.default.removeItem(at: trashed)
    }
    return trashed
}

// MARK: - Поиск

@Suite("Поиск по истории надиктовок")
struct DictationHistorySearchTests {

    private let text = "Подготовь ходатайство о приобщении документов и отправь ещё раз в суд"

    /// Главное требование: слово из СЕРЕДИНЫ текста, а не только из начала.
    @Test func находитСловоИзСередины() {
        #expect(dictationHistoryMatches(text: text, query: "приобщении"))
        #expect(dictationHistoryMatches(text: text, query: "документов и отправь"))
    }

    @Test func регистрНеМешает() {
        #expect(dictationHistoryMatches(text: text, query: "ПОДГОТОВЬ"))
        #expect(dictationHistoryMatches(text: text, query: "подготовь"))
        #expect(dictationHistoryMatches(text: "ХОДАТАЙСТВО", query: "ходатайство"))
    }

    /// «ё» не мешает — в ОБЕ стороны. Ради этого в фильтре стоит
    /// `.diacriticInsensitive`, и поведение проверено прогоном, а не выведено
    /// из документации: для кириллицы оно неочевидно.
    @Test func ёИЕНеРазличаются() {
        #expect(dictationHistoryMatches(text: "Отправь еще раз", query: "ещё"))
        #expect(dictationHistoryMatches(text: "Отправь ещё раз", query: "еще"))
        #expect(dictationHistoryMatches(text: "ЁЛКА стоит", query: "елка"))
        #expect(dictationHistoryMatches(text: "елка стоит", query: "Ёлка"))
    }

    /// Побочный эффект того же флага, зафиксирован сознательно: «й» тоже
    /// сводится к «и». Поиск чуть шире буквального — это цена за «ё».
    @Test func йТожеСводитсяКИ_этоИзвестнаяЦенаЗаЁ() {
        #expect(dictationHistoryMatches(text: "йод в аптечке", query: "иод"))
    }

    @Test func чегоНетНеНаходится() {
        #expect(!dictationHistoryMatches(text: text, query: "апелляция"))
    }

    @Test func пустойЗапросНаходитВсё() {
        #expect(dictationHistoryMatches(text: text, query: ""))
        #expect(dictationHistoryMatches(text: text, query: "   "))
        #expect(dictationHistoryMatches(text: "", query: ""))
    }

    @Test func фильтрОставляетТолькоПодходящие() {
        let entries = [
            DictationHistoryEntry(directory: URL(fileURLWithPath: "/tmp/a"), text: "Отправь ещё раз"),
            DictationHistoryEntry(directory: URL(fileURLWithPath: "/tmp/b"), text: "Позвони в сервис"),
        ]
        let found = filteredDictationHistory(entries, query: "еще")
        #expect(found.count == 1)
        #expect(found.first?.text == "Отправь ещё раз")
        #expect(filteredDictationHistory(entries, query: "").count == 2)
    }

    /// Ищется то, что владелец ВИДЕЛ в поле: если рядом лежит inserted.txt,
    /// поиск идёт по нему, а не по артефактам ASR в сырье.
    @Test func ищетПоВставленномуЕслиОноЕсть() {
        let entry = DictationHistoryEntry(directory: URL(fileURLWithPath: "/tmp/a"),
                                          text: "напиши в смолток",
                                          insertedText: "напиши в smltlk")
        #expect(filteredDictationHistory([entry], query: "smltlk").count == 1)
        #expect(filteredDictationHistory([entry], query: "смолток").isEmpty)
    }
}

// MARK: - Порядок

@Suite("Порядок записей истории")
struct DictationHistoryOrderTests {

    /// Ключ сортировки — ИМЯ каталога (метка времени), а не mtime. Макет
    /// повторяет импорт из старого приложения: папки пишутся на диск в порядке
    /// «свежие первыми», поэтому по mtime самой свежей оказалась бы САМАЯ
    /// СТАРАЯ запись. То же уже задокументировано в PromptEnvelope.swift.
    @MainActor
    @Test func свежиеСверхуПоИмениАНеПоВремениЗаписи() throws {
        try withDictationsRoot { dictations in
            for label in ["2026-08-04_22-32-50", "2026-08-04_22-32-00", "2026-08-04_22-31-11"] {
                _ = try makeEntryOnDisk(in: dictations, label: label, raw: label)
            }
            let entries = dictationHistoryEntries(in: dictations)
            #expect(entries.map(\.label) == ["2026-08-04_22-32-50",
                                             "2026-08-04_22-32-00",
                                             "2026-08-04_22-31-11"])

            // Проверяем, что mtime действительно врёт — иначе тест ничего не
            // доказывает: он мог бы проходить и на сортировке по mtime.
            let modified = try entries.map {
                try $0.directory.appendingPathComponent("raw.txt")
                    .resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate ?? .distantPast
            }
            #expect(modified.first! <= modified.last!)
        }
    }

    @MainActor
    @Test func каталогБезСырьяЗаписьюНеСчитается() throws {
        try withDictationsRoot { dictations in
            _ = try makeEntryOnDisk(in: dictations, label: "2026-08-04_10-00-00", raw: "есть")
            // Папка с одним inserted.txt — не запись: сырьё канон.
            let orphan = dictations.appendingPathComponent("2026-08-04_11-00-00", isDirectory: true)
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            try Data("сирота".utf8).write(to: orphan.appendingPathComponent("inserted.txt"))

            let entries = dictationHistoryEntries(in: dictations)
            #expect(entries.count == 1)
            #expect(entries.first?.text == "есть")
        }
    }

    @MainActor
    @Test func несуществующийКаталогДаётПустуюИсторию() {
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("smltlk-nope-\(UUID().uuidString)")
        #expect(dictationHistoryEntries(in: nowhere).isEmpty)
    }

    @MainActor
    @Test func вставленноеЧитаетсяРядомССырьём() throws {
        try withDictationsRoot { dictations in
            _ = try makeEntryOnDisk(in: dictations,
                                    label: "2026-08-04_10-00-00",
                                    raw: "напиши в смолток",
                                    inserted: "напиши в smltlk ")
            let entry = dictationHistoryEntries(in: dictations).first
            #expect(entry?.text == "напиши в смолток")
            #expect(entry?.insertedText == "напиши в smltlk ")
            #expect(entry?.displayText == "напиши в smltlk ")
        }
    }

    @Test func безВставленногоПоказываетсяСырьё() {
        let entry = DictationHistoryEntry(directory: URL(fileURLWithPath: "/tmp/a"), text: "сырьё")
        #expect(entry.displayText == "сырьё")
    }

    @MainActor
    @Test func promptБерётПодтверждённуюВставкуЗатемГотовыйПромптИТолькоПотомСырьё() throws {
        try withDictationsRoot { dictations in
            _ = try makeEntryOnDisk(
                in: dictations,
                label: "2026-08-07_10-00-00",
                raw: "сырая надиктовка",
                inserted: "подтверждённая вставка",
                generated: "готовый промпт"
            )
            _ = try makeEntryOnDisk(
                in: dictations,
                label: "2026-08-07_09-00-00",
                raw: "второе сырьё",
                generated: "второй готовый промпт"
            )
            _ = try makeEntryOnDisk(
                in: dictations,
                label: "2026-08-07_08-00-00",
                raw: "только сырьё"
            )

            let entries = dictationHistoryEntries(in: dictations)
            #expect(entries[0].displayText == "подтверждённая вставка")
            #expect(entries[1].displayText == "второй готовый промпт")
            #expect(entries[2].displayText == "только сырьё")
        }
    }
}

// MARK: - Удаление

@Suite("Удаление записей истории")
struct DictationHistoryRemovalTests {

    /// Из каталога надиктовок запись уходит целиком — ни файла, ни пустой папки.
    @MainActor
    @Test func удалениеСноситФайлИКаталог() throws {
        try withDictationsRoot { dictations in
            let dir = try makeEntryOnDisk(in: dictations,
                                          label: "2026-08-04_10-00-00",
                                          raw: "удали меня",
                                          inserted: "удали меня")
            let entry = try #require(dictationHistoryEntries(in: dictations).first)
            // Сравнение по resolved-пути: /var — симлинк на /private/var, и
            // contentsOfDirectory возвращает уже разрешённый путь.
            #expect(dictationHistoryRemovalTarget(for: entry).resolvingSymlinksInPath()
                    == dir.resolvingSymlinksInPath())

            try trashEntryAndCleanUp(entry)

            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("raw.txt").path))
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("inserted.txt").path))
            #expect(!FileManager.default.fileExists(atPath: dir.path))
            #expect(dictationHistoryEntries(in: dictations).isEmpty)
        }
    }

    /// Удаление ОБРАТИМО: запись уезжает в Корзину, а не в небытие. Промах по
    /// первичному документу — расшифровке речи клиента — владелец обязан иметь
    /// возможность отменить.
    @MainActor
    @Test func удалениеОтправляетВКорзинуАНеУничтожает() throws {
        try withDictationsRoot { dictations in
            let dir = try makeEntryOnDisk(in: dictations,
                                          label: "2026-08-04_10-00-00",
                                          raw: "черновик письма",
                                          inserted: "Черновик письма")
            let entry = try #require(dictationHistoryEntries(in: dictations).first)

            var seenInTrash: String?
            let trashed = try trashEntryAndCleanUp(entry) { inTrash in
                // Пока копия в Корзине жива — её содержимое читается, значит
                // запись действительно можно вернуть.
                seenInTrash = try String(contentsOf: inTrash.appendingPathComponent("raw.txt"),
                                         encoding: .utf8)
            }

            #expect(trashed != nil, "система не назвала путь в Корзине — удаление не было обратимым")
            #expect(seenInTrash == "черновик письма")
            #expect(!FileManager.default.fileExists(atPath: dir.path))
        }
    }

    @MainActor
    @Test func удалениеОднойЗаписиНеТрогаетОстальные() throws {
        try withDictationsRoot { dictations in
            for label in ["2026-08-04_10-00-00", "2026-08-04_11-00-00", "2026-08-04_12-00-00"] {
                _ = try makeEntryOnDisk(in: dictations, label: label, raw: label)
            }
            let entries = dictationHistoryEntries(in: dictations)
            try trashEntryAndCleanUp(entries[1])

            let left = dictationHistoryEntries(in: dictations)
            #expect(left.map(\.label) == ["2026-08-04_12-00-00", "2026-08-04_10-00-00"])
        }
    }

    /// «Очистить всё» знает ТОЧНОЕ число до удаления и произносит его.
    @Test func подтверждениеНазываетЧислоЗаписейДоУдаления() {
        #expect(dictationHistoryClearConfirmation(count: 7).contains("7"))
        #expect(dictationHistoryClearConfirmation(count: 1).contains("1"))
        #expect(dictationHistoryClearConfirmation(count: 58).contains("58"))
        #expect(dictationHistoryClearConfirmation(count: 0) == "Удалять нечего — история пуста.")
    }

    @Test func числоЗаписейСклоняетсяПоРусски() {
        #expect(russianDictationWordForm(1) == "надиктовку")
        #expect(russianDictationWordForm(2) == "надиктовки")
        #expect(russianDictationWordForm(5) == "надиктовок")
        #expect(russianDictationWordForm(11) == "надиктовок")
        #expect(russianDictationWordForm(21) == "надиктовку")
        #expect(russianDictationWordForm(112) == "надиктовок")
    }

    @MainActor
    @Test func числоВПодтвержденииСовпадаетСтем_чтоНаДиске() throws {
        try withDictationsRoot { dictations in
            for label in ["2026-08-04_10-00-00", "2026-08-04_11-00-00", "2026-08-04_12-00-00"] {
                _ = try makeEntryOnDisk(in: dictations, label: label, raw: label)
            }
            let entries = dictationHistoryEntries(in: dictations)
            #expect(dictationHistoryClearConfirmation(count: entries.count).contains("3"))

            for entry in entries { try trashEntryAndCleanUp(entry) }
            #expect(dictationHistoryEntries(in: dictations).isEmpty)
            // Каталог dictations на месте, внутри пусто — мусора не осталось.
            #expect(try FileManager.default
                .contentsOfDirectory(atPath: dictations.path).isEmpty)
        }
    }
}

// MARK: - inserted.txt рядом с сырьём

@Suite("inserted.txt рядом с сырьём")
struct InsertedTextStoreTests {

    /// Закон проекта: сырьё неприкосновенно. Появление inserted.txt не меняет
    /// raw.txt ни на байт.
    @MainActor
    @Test func сырьёОстаётсяБайтВБайтПослеПоявленияВставленного() throws {
        let raw = "  напиши в смолток.  "
        let inserted = "Напиши в smltlk "
        try withDictationsRoot { dictations in
            let rawURL = try DictationStore.save(rawText: raw, in: dictations.deletingLastPathComponent())
            #expect(try Data(contentsOf: rawURL) == Data(raw.utf8))

            #expect(try DictationStore.saveInsertedText(inserted, besideRawAt: rawURL))

            // Сырьё — то же самое.
            #expect(try Data(contentsOf: rawURL) == Data(raw.utf8))
            let insertedURL = rawURL.deletingLastPathComponent()
                .appendingPathComponent("inserted.txt")
            #expect(try Data(contentsOf: insertedURL) == Data(inserted.utf8))
            #expect(inserted != raw)
        }
    }

    /// Права 0600, как у сырья: в файле расшифровка речи клиента.
    @MainActor
    @Test func вставленноеПишетсяПриватно() throws {
        try withDictationsRoot { dictations in
            let rawURL = try DictationStore.save(rawText: "текст", in: dictations.deletingLastPathComponent())
            try DictationStore.saveInsertedText("текст ", besideRawAt: rawURL)
            let insertedURL = rawURL.deletingLastPathComponent()
                .appendingPathComponent("inserted.txt")
            let mode = try FileManager.default
                .attributesOfItem(atPath: insertedURL.path)[.posixPermissions] as? NSNumber
            #expect(mode?.int16Value == 0o600)
        }
    }

    /// Приватная запись ДОПИСЫВАЕТ. Второй вызов не имеет права склеить две
    /// вставки в одну строку — он отказывается и говорит об этом.
    @MainActor
    @Test func второйВызовНеДописываетКУжеСохранённому() throws {
        try withDictationsRoot { dictations in
            let rawURL = try DictationStore.save(rawText: "текст", in: dictations.deletingLastPathComponent())
            #expect(try DictationStore.saveInsertedText("первое", besideRawAt: rawURL))
            #expect(try DictationStore.saveInsertedText("второе", besideRawAt: rawURL) == false)

            let insertedURL = rawURL.deletingLastPathComponent()
                .appendingPathComponent("inserted.txt")
            #expect(try Data(contentsOf: insertedURL) == Data("первое".utf8))
        }
    }

    @MainActor
    @Test func вставленноеЛожитсяРядомССырьёмАНеВДругуюПапку() throws {
        try withDictationsRoot { dictations in
            let rawURL = try DictationStore.save(rawText: "текст", in: dictations.deletingLastPathComponent())
            try DictationStore.saveInsertedText("текст ", besideRawAt: rawURL)
            let names = try FileManager.default
                .contentsOfDirectory(atPath: rawURL.deletingLastPathComponent().path)
                .sorted()
            #expect(names == ["inserted.txt", "raw.txt"])
        }
    }
}

// MARK: - Буфер обмена: живой NSPasteboard

/// Лог прогона вместо живого лога владельца: в
/// `~/Library/Logs/smltlk-dictate.log` тесты не дописывают ничего.
private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// Приватный буфер на тест: общий трогать нельзя — в нём буфер владельца.
private func privateTestPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("ru.smltlk.tests.\(UUID().uuidString)"))
}

private func put(_ text: String, on pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    pasteboard.writeObjects([item])
}

/// Пауза заведомо длиннее и прежней паузы восстановления (2 с), и коротких окон
/// удержания в тестах ниже.
///
/// Именно `Task.sleep`, а не прокрутка RunLoop: под `swift test` блокирующая
/// прокрутка не даёт сработать таймеру главной очереди, и тест на окно удержания
/// молча проходил бы, ничего не проверив. Проверено прогоном.
private func пауза3с() async throws {
    try await Task.sleep(nanoseconds: 3_000_000_000)
}

/// Поведение самого копирования, а не только решения о восстановлении.
///
/// Раньше здесь стоял тест ЧИСТОЙ функции `pasteboardRestoreDecision` — и он
/// пропустил дефект: `copy()` возвращал прежний буфер через 2 с после того, как
/// запись кто-нибудь прочитал, а «прочитал» ≠ «владелец вставил». Тезис «живой
/// NSPasteboard под `swift test` недоступен» оказался неверным: приватный
/// `NSPasteboard(name:)` работает без NSApplication.
/// `.serialized` обязателен: незакрытая транзакция буфера — ОДИН статик на всё
/// приложение (в системе один буфер обмена и один владелец). Без сериализации
/// тесты расходятся на `await` и гасят транзакции друг друга — проверено
/// прогоном: главный тест падал не на дефекте, а на чужом `quench`.
@MainActor
@Suite("Копирование в живой буфер обмена", .serialized)
struct DictationHistoryClipboardLiveTests {

    /// ГЛАВНОЕ: запись остаётся доступной ПОСЛЕ того, как её прочитали.
    ///
    /// Провайдер зовёт любой читатель буфера — менеджер буфера (Raycast, Paste,
    /// Maccy), Universal Clipboard. Владелец жмёт ⌘C в истории, переключается в
    /// Pages и жмёт ⌘V через три секунды. Он обязан получить надиктовку, а не
    /// свой прежний буфер.
    @Test func записьЖивётПослеЧтенияСторонним() async throws {
        let pasteboard = privateTestPasteboard()
        let box = LogBox()
        defer {
            DictationHistoryClipboard.quench(reason: "конец теста")
            pasteboard.releaseGlobally()
        }
        put("прежний буфер владельца", on: pasteboard)

        #expect(DictationHistoryClipboard.copy("Черновик письма подрядчику",
                                               pasteboard: pasteboard,
                                               hold: 30,
                                               logLine: box.append))

        // Менеджер буфера прочитал запись сразу после ⌘C. Это чтение вызывает
        // провайдер и НЕ меняет changeCount.
        #expect(pasteboard.string(forType: .string) == "Черновик письма подрядчику")

        // Владелец добрался до документа и жмёт ⌘V. Три секунды — больше прежней
        // паузы восстановления, на которой дефект и срабатывал.
        try await пауза3с()

        #expect(pasteboard.string(forType: .string) == "Черновик письма подрядчику",
                "запись подменена прежним буфером — ⌘V вставит владельцу чужой текст")
    }

    /// Многократное чтение записи не отменяет и не ускоряет её судьбу.
    @Test func многократноеЧтениеНеСноситЗапись() async throws {
        let pasteboard = privateTestPasteboard()
        let box = LogBox()
        defer {
            DictationHistoryClipboard.quench(reason: "конец теста")
            pasteboard.releaseGlobally()
        }
        put("прежнее", on: pasteboard)
        #expect(DictationHistoryClipboard.copy("надиктовка",
                                               pasteboard: pasteboard,
                                               hold: 30,
                                               logLine: box.append))
        for _ in 0..<5 {
            #expect(pasteboard.string(forType: .string) == "надиктовка")
        }
    }

    /// Окно удержания кончилось — расшифровка из буфера УХОДИТ: держать чужие
    /// персональные данные в общем буфере весь день нельзя.
    ///
    /// Уходит именно в пустоту, а не подменяется прежним содержимым: «⌘V ничего
    /// не вставил» владелец замечает сразу, а подменённый старый текст в
    /// договоре — не замечает.
    @Test func поОкнуУдержанияЗаписьУходитИзБуфера() async throws {
        let pasteboard = privateTestPasteboard()
        let box = LogBox()
        defer {
            DictationHistoryClipboard.quench(reason: "конец теста")
            pasteboard.releaseGlobally()
        }
        put("прежний буфер владельца", on: pasteboard)
        #expect(DictationHistoryClipboard.copy("Расшифровка речи клиента",
                                               pasteboard: pasteboard,
                                               hold: 0.3,
                                               logLine: box.append))
        #expect(pasteboard.string(forType: .string) == "Расшифровка речи клиента")

        try await пауза3с()

        let left = pasteboard.string(forType: .string)
        #expect(left != "Расшифровка речи клиента",
                "расшифровка осталась в общем буфере после окна удержания")
        #expect(left != "прежний буфер владельца",
                "по истечении окна буфер подменён старым текстом — это молчаливая подстановка")
        #expect(box.lines.contains { $0.contains("cleared") })
    }

    /// Явное гашение (вставка из окна, следующее ⌘C) возвращает владельцу его
    /// прежний буфер — там он сам перешёл к другому действию.
    @Test func явноеГашениеВозвращаетПрежнийБуфер() async throws {
        let pasteboard = privateTestPasteboard()
        let box = LogBox()
        defer { pasteboard.releaseGlobally() }
        put("прежний буфер владельца", on: pasteboard)
        #expect(DictationHistoryClipboard.copy("текст клиента",
                                               pasteboard: pasteboard,
                                               hold: 30,
                                               logLine: box.append))
        #expect(pasteboard.string(forType: .string) == "текст клиента")

        DictationHistoryClipboard.quench(reason: "вставка из окна истории")

        #expect(pasteboard.string(forType: .string) == "прежний буфер владельца")
    }

    /// Гашение перед вставкой обязано случиться ДО снятия снимка: иначе снимок
    /// TextInserter захватил бы текст клиента и в конце вернул бы его же в
    /// буфер — навсегда.
    @Test func послеГашенияСнимокНеСодержитТекстКлиента() async throws {
        let pasteboard = privateTestPasteboard()
        let box = LogBox()
        defer { pasteboard.releaseGlobally() }
        put("прежний буфер владельца", on: pasteboard)
        #expect(DictationHistoryClipboard.copy("Расшифровка речи клиента",
                                               pasteboard: pasteboard,
                                               hold: 30,
                                               logLine: box.append))

        DictationHistoryClipboard.quench(reason: "вставка из окна истории")

        // То, что увидит TextInserter, снимая снимок сразу после гашения.
        let snapshotSees = pasteboard.string(forType: .string)
        #expect(snapshotSees == "прежний буфер владельца")
        #expect(snapshotSees != "Расшифровка речи клиента")
    }

    /// Буфер изменили извне — чужое не затираем даже по истечении окна.
    @Test func чужуюЗаписьПоОкнуУдержанияНеТрогаем() async throws {
        let pasteboard = privateTestPasteboard()
        let box = LogBox()
        defer {
            DictationHistoryClipboard.quench(reason: "конец теста")
            pasteboard.releaseGlobally()
        }
        put("прежнее", on: pasteboard)
        #expect(DictationHistoryClipboard.copy("надиктовка",
                                               pasteboard: pasteboard,
                                               hold: 0.3,
                                               logLine: box.append))
        // Владелец скопировал что-то своё в другом приложении.
        put("совсем другое", on: pasteboard)

        try await пауза3с()

        #expect(pasteboard.string(forType: .string) == "совсем другое")
        #expect(box.lines.contains { $0.contains("left alone") && $0.contains("извне") })
    }

    /// В логе только длина и вердикт — ни самого текста, ни имени приложения.
    @Test func логНеСодержитТекстаЗаписи() async throws {
        let pasteboard = privateTestPasteboard()
        let box = LogBox()
        defer {
            DictationHistoryClipboard.quench(reason: "конец теста")
            pasteboard.releaseGlobally()
        }
        let secret = "Иванов передал задаток триста тысяч"
        #expect(DictationHistoryClipboard.copy(secret,
                                               pasteboard: pasteboard,
                                               hold: 30,
                                               logLine: box.append))
        #expect(!box.lines.isEmpty)
        for line in box.lines {
            #expect(!line.contains(secret))
            #expect(!line.contains("Иванов"))
        }
        #expect(box.lines.contains { $0.contains("\(secret.count) chars") })
    }
}


// MARK: - Буфер обмена: решение о восстановлении

@Suite("Восстановление буфера обмена")
struct PasteboardRestoreDecisionTests {

    /// На буфере всё ещё наша запись — прежнее содержимое можно вернуть.
    @Test func нашуЗаписьМожноЗаменитьПрежнимСодержимым() {
        #expect(pasteboardRestoreDecision(transientChangeCount: 42,
                                          currentChangeCount: 42) == .restore)
    }

    /// Буфер изменили извне — затирать чужое нельзя, и это НЕ молчаливый
    /// пропуск: причина уходит в лог строкой из решения.
    @Test func чужуюЗаписьНеЗатираем_иГоворимПочему() {
        let decision = pasteboardRestoreDecision(transientChangeCount: 42,
                                                 currentChangeCount: 43)
        #expect(decision != .restore)
        guard case .skip(let why) = decision else {
            Issue.record("ожидался пропуск с причиной, пришло \(decision)")
            return
        }
        #expect(!why.isEmpty)
        #expect(why.contains("извне"))
    }

    /// Записи в буфер не было вообще — восстанавливать не над чем, и это тоже
    /// названо причиной, а не проглочено.
    @Test func безНашейЗаписиВосстанавливатьНечего() {
        let decision = pasteboardRestoreDecision(transientChangeCount: nil,
                                                 currentChangeCount: 7)
        guard case .skip(let why) = decision else {
            Issue.record("ожидался пропуск с причиной, пришло \(decision)")
            return
        }
        #expect(!why.isEmpty)
    }

    /// Держать чужие персональные данные в общем буфере вечно нельзя, но и
    /// секунды владельцу не хватит: он идёт в другое приложение руками.
    @Test func окноУдержанияДостаточноеИКонечное() {
        #expect(HISTORY_CLIPBOARD_HOLD_SECONDS > 10)
        #expect(HISTORY_CLIPBOARD_HOLD_SECONDS <= 600)
    }
}

// MARK: - Клавиши

@Suite("Клавиши окна истории")
struct DictationHistoryKeyTests {

    private func action(_ keyCode: CGKeyCode,
                        _ characters: String? = nil,
                        command: Bool = false) -> DictationHistoryKeyAction {
        dictationHistoryKeyAction(keyCode: keyCode,
                                  charactersIgnoringModifiers: characters,
                                  hasCommand: command)
    }

    @Test func escapeЗакрывает() {
        #expect(action(ESCAPE_KEYCODE) == .close)
    }

    @Test func enterВставляет() {
        #expect(action(RETURN_KEYCODE) == .insertSelected)
        #expect(action(HISTORY_KEYPAD_ENTER_KEYCODE) == .insertSelected)
    }

    @Test func командаCКопирует() {
        #expect(action(8, "c", command: true) == .copySelected)
        #expect(action(8, "C", command: true) == .copySelected)
    }

    /// ⌫ целиком принадлежит полю поиска — и с Command, и без.
    ///
    /// ⌘⌫ окно НЕ забирает намеренно: это документированный системный шорткат
    /// текстового поля («удалить от курсора до начала строки»), а поле поиска в
    /// фокусе по умолчанию. Забрав его под удаление записи, окно уносило бы
    /// расшифровку речи клиента по мышечной памяти — без подтверждения и на
    /// привычной клавише. Удаление живёт в контекстном меню.
    @Test func backspaceНеУдаляетЗаписьНиСКомандойНиБез() {
        #expect(action(HISTORY_DELETE_KEYCODE, "\u{8}") == .passThrough)
        #expect(action(HISTORY_DELETE_KEYCODE, "\u{8}", command: true) == .passThrough)
        #expect(action(HISTORY_DELETE_KEYCODE, "\u{7F}", command: true) == .passThrough)
        // Forward delete тоже не наш.
        #expect(action(117, "\u{7F}", command: true) == .passThrough)
    }

    @Test func стрелкиДвигаютВыделение() {
        #expect(action(HISTORY_ARROW_UP_KEYCODE) == .moveSelection(-1))
        #expect(action(HISTORY_ARROW_DOWN_KEYCODE) == .moveSelection(1))
    }

    /// Буквы окно не съедает: они набираются в поле поиска.
    @Test func буквыУходятВПолеПоиска() {
        #expect(action(0, "а") == .passThrough)
        #expect(action(1, "s") == .passThrough)
        #expect(action(0, "а", command: true) == .passThrough)
    }
}

// MARK: - Выделение

@Suite("Выделение в списке истории")
struct DictationHistorySelectionTests {

    @Test func выделениеНеВыходитЗаСписок() {
        #expect(clampedHistorySelection(-5, count: 3) == 0)
        #expect(clampedHistorySelection(99, count: 3) == 2)
        #expect(clampedHistorySelection(1, count: 3) == 1)
    }

    @Test func пустойСписокДаётНулевоеВыделение() {
        #expect(clampedHistorySelection(4, count: 0) == 0)
    }

    /// Без заворота: на первой записи ↑ оставляет на первой. Заворот в короткой
    /// истории читается как «прыгнуло куда-то само».
    @Test func сдвигНеЗаворачивается() {
        #expect(movedHistorySelection(from: 0, by: -1, count: 3) == 0)
        #expect(movedHistorySelection(from: 2, by: 1, count: 3) == 2)
        #expect(movedHistorySelection(from: 0, by: 1, count: 3) == 1)
    }

    /// Фильтр поиска сузил список под руками — выделение прижимается, а не
    /// указывает в пустоту.
    @Test func сужениеСпискаПрижимаетВыделение() {
        #expect(movedHistorySelection(from: 9, by: 0, count: 2) == 1)
    }
}

// MARK: - Показ строки

@Suite("Строка списка истории")
struct DictationHistoryPreviewTests {

    @Test func длинныйТекстОбрезается() {
        let long = String(repeating: "я", count: 500)
        let preview = dictationHistoryPreview(long, limit: 20)
        #expect(preview.count == 21)
        #expect(preview.hasSuffix("…"))
    }

    @Test func короткийТекстНеТрогается() {
        #expect(dictationHistoryPreview("коротко", limit: 20) == "коротко")
    }

    /// Многострочная надиктовка должна остаться ОДНОЙ строкой списка.
    @Test func переводыСтрокСплющиваются() {
        #expect(dictationHistoryPreview("первая\nвторая\r\nтретья") == "первая вторая  третья")
    }

    @Test func обрезкаНеРежетСимволПополам() {
        // 10 символов кириллицы — 20 байт в UTF-8. Обрезка по символам.
        let preview = dictationHistoryPreview(String(repeating: "ё", count: 30), limit: 10)
        #expect(preview == String(repeating: "ё", count: 10) + "…")
    }

    /// Метка времени: разобралась — показываем по-русски, не разобралась —
    /// показываем имя папки как есть. Соврать про время записи нельзя.
    @Test func меткаВремениРазбираетОбаФорматаИмён() {
        #expect(dictationHistoryDate("2026-08-04_22-32-50") != nil)
        #expect(dictationHistoryDate("2026-08-04T22:32:50Z") != nil)
        // Суффикс дубля одной секунды разбору не мешает.
        #expect(dictationHistoryDate("2026-08-04_22-32-50-2") != nil)
        #expect(dictationHistoryDate("непонятная-папка") == nil)
        #expect(dictationHistoryTimeLabel("непонятная-папка") == "непонятная-папка")
    }
}

// MARK: - Журнал владельца не для тестов

@Suite("Журнал: тесты пишут не в файл владельца")
struct LoggerRedirectTests {
    /// Замерено живьём: один полный `swift test` дописывал в
    /// `~/Library/Logs/smltlk-dictate.log` четыре строки от сюиты про зависшее
    /// распознавание — она поднимает настоящий `DictationController`, а тот зовёт
    /// живой `log()`. В этом файле лежит диагностика рабочего дня владельца, и запрет
    /// «тесты не пишут в журнал владельца» иначе противоречил бы требованию
    /// «прогони весь swift test».
    @Test func подТестамиЖурналВладельцаНеТрогается() {
        let ownerLog = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/smltlk-dictate.log")
            .standardizedFileURL

        let chosen = Logger().fileURL.standardizedFileURL

        #expect(chosen != ownerLog,
                "логгер под тестами выбрал журнал владельца: \(chosen.path)")
        #expect(chosen.path.hasPrefix(NSTemporaryDirectory()) || chosen.path.contains("/T/"),
                "ожидался временный файл, выбран \(chosen.path)")
    }

    /// Признак продукта — идентификатор бандла, а не путь и не переменные харнесса:
    /// под `swift test` XCTest-переменные не выставлены, а хост-процесс это раннер
    /// `xctest` из Xcode, у которого в пути нет `.build`. Оба способа молча
    /// не срабатывали — этот тест держит, чтобы к ним не вернулись.
    @Test func признакПродуктаЭтоИдентификаторБандлаАНеПуть() {
        #expect(Bundle.main.bundleIdentifier != "ru.smltlk.app",
                "тестовый процесс не должен выглядеть как бандл продукта")
    }
}
