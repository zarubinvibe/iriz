// Основано на SuperDictate (MIT, © 2025 shlgd), коммит 83dd7e4.
//
// Отметка поставлена 06.09.2026 по итогу сверки с донором: класс временного
// буфера обмена (transientChangeCount, restoreWorkItem, install,
// pasteboard(_:item:provideDataForType:), finish) взят у него дословно. Код
// выделен из работы над окном истории, и отметка за ним не поехала.
// ⌘C в окне истории: положить запись в буфер обмена, не оставив её там навсегда.
//
// Почему буфер ВРЕМЕННЫЙ, а не «положили и забыли»: в этих записях расшифровки
// речи, а среди них бывает чужой текст. Оставшийся в общем буфере на
// весь день (а с Universal Clipboard — ещё и на других устройствах), — утечка.
//
// Чего здесь СОЗНАТЕЛЬНО нет — откката «по факту чтения буфера». Провайдер зовёт
// ЛЮБОЙ читатель: менеджер буфера (Raycast, Paste, Maccy), Universal Clipboard,
// службы. Прогон на приватном NSPasteboard: одиночное чтение string(forType:)
// вызывает провайдер и НЕ меняет changeCount — значит «данные запросили»
// неотличимо от «владелец вставил». Откат через пару секунд после чтения
// подсовывал владельцу его прежний буфер вместо надиктовки: ⌘C в истории →
// менеджер буфера прочитал → владелец переключился в Pages → ⌘V через три
// секунды вставил старый текст. Молча, в чужой документ. Поэтому запись
// живёт до конца окна удержания, сколько бы раз её ни прочитали.
//
// По истечении окна удержания буфер ЧИСТИТСЯ, а не возвращается к прежнему
// содержимому. «⌘V ничего не вставил» владелец замечает сразу и копирует
// заново; подменённый старый текст в договоре — не замечает. Прежнее содержимое
// возвращается только там, где владелец сам перешёл к другому действию:
// следующее копирование или вставка из окна (`quench`).
import AppKit
import Foundation

/// Сколько держать запись в буфере. Вставке надиктовки хватает секунд (цель
/// забирает текст сразу), а здесь владелец сам идёт в другое приложение —
/// минуты. Дольше держать нельзя: это чужие персональные данные в общем буфере.
let HISTORY_CLIPBOARD_HOLD_SECONDS: TimeInterval = 120

/// Решение о том, вправе ли мы вообще трогать буфер. ЧТО именно записать —
/// прежнее содержимое или пустоту — решает вызывающий.
enum PasteboardRestoreDecision: Equatable {
    case restore
    /// Трогать буфер нельзя, и вот почему. Строка идёт в лог.
    case skip(String)
}

/// На буфере всё ещё НАША запись?
///
/// `transientChangeCount` — `changeCount` СРАЗУ ПОСЛЕ нашей записи. Совпадает с
/// текущим — на буфере по-прежнему наша запись, её можно заменить. Не совпадает —
/// между нашей записью и сейчас в буфер писал кто-то ещё, и затирать чужое мы
/// не имеем права.
func pasteboardRestoreDecision(transientChangeCount: Int?,
                               currentChangeCount: Int) -> PasteboardRestoreDecision {
    guard let transientChangeCount else {
        return .skip("наша запись в буфер не состоялась")
    }
    guard transientChangeCount == currentChangeCount else {
        return .skip("буфер изменён извне")
    }
    return .restore
}

@MainActor
enum DictationHistoryClipboard {
    private static var pending: HistoryClipboardTransaction?

    /// Кладёт текст в буфер. `false` — буфер отказал, вызывающий обязан сказать
    /// владельцу, что копирование не состоялось.
    ///
    /// `hold` и `logLine` — швы для теста: прогон не ждёт две минуты и не
    /// дописывает в живой лог владельца.
    @discardableResult
    static func copy(_ text: String,
                     pasteboard: NSPasteboard = .general,
                     hold: TimeInterval = HISTORY_CLIPBOARD_HOLD_SECONDS,
                     logLine: @escaping (String) -> Void = { log($0) }) -> Bool {
        quench(reason: "вытеснено следующим копированием")
        let transaction = HistoryClipboardTransaction(text: text,
                                                     pasteboard: pasteboard,
                                                     hold: hold,
                                                     logLine: logLine)
        transaction.onFinished = { [weak transaction] in
            guard let transaction, pending === transaction else { return }
            pending = nil
        }
        guard transaction.install() else {
            pending = nil
            logLine("history: pasteboard write failed — entry NOT copied")
            return false
        }
        pending = transaction
        logLine("history: entry copied to clipboard (\(text.count) chars, held \(Int(hold)) s)")
        return true
    }

    /// Гасит незакрытую транзакцию: возвращает прежний буфер владельца прямо
    /// сейчас, не дожидаясь окна удержания.
    ///
    /// Нужно перед вставкой из окна истории. Иначе TextInserter снял бы снимок
    /// буфера, на котором лежит запись клиента, и в конце вернул бы ЕЁ же —
    /// текст клиента остался бы в общем буфере навсегда, что и обещает не
    /// допускать шапка этого файла.
    static func quench(reason: String) {
        pending?.restoreNow(reason: reason)
        pending = nil
    }
}

@MainActor
private final class HistoryClipboardTransaction: NSObject, NSPasteboardItemDataProvider {
    nonisolated let text: String
    private let pasteboard: NSPasteboard
    private let previousSnapshot: HistoryPasteboardSnapshot
    private let hold: TimeInterval
    private let logLine: (String) -> Void
    var onFinished: (() -> Void)?

    private var transientChangeCount: Int?
    private var restoreWorkItem: DispatchWorkItem?
    private var isFinished = false

    init(text: String,
         pasteboard: NSPasteboard,
         hold: TimeInterval,
         logLine: @escaping (String) -> Void) {
        self.text = text
        self.pasteboard = pasteboard
        self.hold = hold
        self.logLine = logLine
        self.previousSnapshot = HistoryPasteboardSnapshot.capture(from: pasteboard)
    }

    func install() -> Bool {
        let item = NSPasteboardItem()
        guard item.setDataProvider(self, forTypes: [.string]) else {
            finish()
            return false
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            previousSnapshot.restore(to: pasteboard)
            finish()
            return false
        }
        transientChangeCount = pasteboard.changeCount
        scheduleExpiry()
        return true
    }

    /// Провайдер зовёт любой читатель буфера. Здесь только отдать текст:
    /// делать из чтения вывод «владелец вставил» нельзя (см. шапку файла).
    nonisolated func pasteboard(_ pasteboard: NSPasteboard?,
                                item: NSPasteboardItem,
                                provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .string else { return }
        item.setString(text, forType: type)
    }

    /// Владелец так и не вставил — чистим буфер, чтобы расшифровка не осталась
    /// в нём на весь день.
    private func scheduleExpiry() {
        restoreWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.expire()
        }
        restoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, hold), execute: work)
    }

    func restoreNow(reason: String) {
        guard !isFinished else { return }
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        act(reason: reason) { pasteboard, snapshot in
            snapshot.restore(to: pasteboard)
            return "restored"
        }
    }

    private func expire() {
        guard !isFinished else { return }
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        act(reason: "владелец так и не вставил запись") { pasteboard, _ in
            // Именно clear, а не прежнее содержимое: молча подсунуть владельцу
            // старый текст хуже, чем не вставить ничего.
            pasteboard.clearContents()
            return "cleared"
        }
    }

    private func act(reason: String,
                     _ body: (NSPasteboard, HistoryPasteboardSnapshot) -> String) {
        switch pasteboardRestoreDecision(transientChangeCount: transientChangeCount,
                                        currentChangeCount: pasteboard.changeCount) {
        case .restore:
            let what = body(pasteboard, previousSnapshot)
            logLine("history: pasteboard \(what) after \(reason)")
        case .skip(let why):
            logLine("history: pasteboard left alone after \(reason): \(why)")
        }
        finish()
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        let completion = onFinished
        onFinished = nil
        completion?()
    }
}

/// Снимок буфера обмена со всеми типами каждого элемента: владелец мог держать
/// в буфере не только строку, и вернуть надо ровно то, что было.
@MainActor
private struct HistoryPasteboardSnapshot {
    private struct Item {
        let values: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> HistoryPasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        }
        return HistoryPasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { item -> NSPasteboardItem in
            let out = NSPasteboardItem()
            for value in item.values {
                out.setData(value.data, forType: value.type)
            }
            return out
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}
