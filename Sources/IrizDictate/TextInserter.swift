// Основано на SuperDictate (MIT, © 2026 Richard Courtman), коммит 83dd7e4.
// Вставка текста в фокусное поле.
//
// Default path: write to general pasteboard, post Cmd+V. If that setup
// fails, fall back to direct Unicode events so a pasteboard problem
// does not automatically lose the transcript. After a successful paste
// event, restore the previous clipboard if it is still at our temporary
// write, so dictation doesn't replace what the user had copied before
// speaking.
import AppKit
import CoreGraphics
import Foundation

enum TextInsertionStrategy: String {
    case clipboardPaste
    case directUnicode

    var displayName: String {
        switch self {
        case .clipboardPaste: return "Clipboard paste"
        case .directUnicode: return "Direct Unicode typing"
        }
    }
}

func textInsertionStrategyChain(primary: TextInsertionStrategy) -> [TextInsertionStrategy] {
    switch primary {
    case .clipboardPaste:
        return [.clipboardPaste, .directUnicode]
    case .directUnicode:
        return [.directUnicode]
    }
}

func unicodeInsertionChunks(for text: String, maxUTF16UnitsPerEvent maxUnits: Int) -> [[UInt16]] {
    guard maxUnits > 0 else { return [] }
    var chunks: [[UInt16]] = []
    var current: [UInt16] = []

    for character in text {
        let units = Array(String(character).utf16)
        if units.count > maxUnits {
            if !current.isEmpty {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }
            chunks.append(units)
            continue
        }
        if !current.isEmpty, current.count + units.count > maxUnits {
            chunks.append(current)
            current.removeAll(keepingCapacity: true)
        }
        current.append(contentsOf: units)
    }

    if !current.isEmpty {
        chunks.append(current)
    }
    return chunks
}

struct KeyboardEventStep: Equatable {
    let virtualKey: CGKeyCode
    let keyDown: Bool
    let flags: CGEventFlags
}

func clipboardPasteKeyboardEventSteps(commandKey: CGKeyCode,
                                      pasteKey: CGKeyCode) -> [KeyboardEventStep] {
    [
        KeyboardEventStep(virtualKey: commandKey, keyDown: true, flags: .maskCommand),
        KeyboardEventStep(virtualKey: pasteKey, keyDown: true, flags: .maskCommand),
        KeyboardEventStep(virtualKey: pasteKey, keyDown: false, flags: .maskCommand),
        KeyboardEventStep(virtualKey: commandKey, keyDown: false, flags: []),
    ]
}

func postKeyboardEventSteps(_ steps: [KeyboardEventStep], targetPID: pid_t? = nil) -> Bool {
    let source = CGEventSource(stateID: .hidSystemState)
    let events = steps.compactMap { step -> CGEvent? in
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: step.virtualKey,
                                  keyDown: step.keyDown) else {
            return nil
        }
        event.flags = step.flags
        return event
    }
    guard events.count == steps.count else { return false }

    for event in events {
        if let targetPID {
            event.postToPid(targetPID)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
    return true
}

@MainActor
enum KeyboardShortcutPoster {
    @discardableResult
    static func postReturn() -> Bool {
        postKeyboardEventSteps([
            KeyboardEventStep(virtualKey: RETURN_KEYCODE, keyDown: true, flags: []),
            KeyboardEventStep(virtualKey: RETURN_KEYCODE, keyDown: false, flags: []),
        ])
    }
}

/// Наблюдатель факта доставки: ленивый провайдер буфера обмена узнаёт, что
/// цель ЗАПРОСИЛА текст. Это и есть доставка — в отличие от «мы отправили ⌘V».
@MainActor
final class TextInsertionDelivery {
    private(set) var targetRequestedText = false

    fileprivate func noteTargetRequestedText() {
        targetRequestedText = true
    }
}

/// Итог запуска вставки. `strategy` == nil — не запустилась ни одна стратегия.
/// «Запустилась» ещё не значит «доставлено»: вердикт даёт confirmDelivery.
@MainActor
struct TextInsertionAttempt {
    let strategy: TextInsertionStrategy?
    let delivery: TextInsertionDelivery
}

@MainActor
enum TextInserter {
    nonisolated static let defaultStrategy = TextInsertionStrategy.clipboardPaste

    static func insert(_ text: String,
                       strategy: TextInsertionStrategy = defaultStrategy,
                       targetPID: pid_t? = nil) -> TextInsertionAttempt {
        let delivery = TextInsertionDelivery()
        guard targetAllowsPosting(targetPID) else {
            return TextInsertionAttempt(strategy: nil, delivery: delivery)
        }
        for candidate in textInsertionStrategyChain(primary: strategy) {
            if insert(text, using: candidate, delivery: delivery, targetPID: targetPID) {
                if candidate != strategy {
                    log("text insertion fallback succeeded: \(candidate.displayName)")
                }
                return TextInsertionAttempt(strategy: candidate, delivery: delivery)
            }
            log("text insertion attempt failed: \(candidate.displayName)")
        }
        return TextInsertionAttempt(strategy: nil, delivery: delivery)
    }

    /// Ждёт подтверждения доставки не дольше окна и возвращает вердикт.
    /// Ожидание через сон уступает главный актор — иначе колбэк провайдера
    /// буфера обмена, который и есть подтверждение, не смог бы приехать.
    static func confirmDelivery(_ attempt: TextInsertionAttempt,
                                window: TimeInterval = INSERTION_DELIVERY_WINDOW_SECONDS,
                                pollInterval: TimeInterval = 0.02) async -> TextInsertionVerdict {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let step = UInt64(max(0.005, pollInterval) * 1_000_000_000)
        while true {
            let verdict = textInsertionVerdict(
                startedStrategy: attempt.strategy,
                targetRequestedText: attempt.delivery.targetRequestedText,
                elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
                window: window
            )
            guard case .waiting = verdict else { return verdict }
            // Отмена задачи не должна крутить пустой цикл: сон на отменённой
            // задаче возвращается мгновенно.
            if Task.isCancelled { return .notDelivered(.targetNeverRequestedText) }
            try? await Task.sleep(nanoseconds: step)
        }
    }

    private static func insert(_ text: String,
                               using strategy: TextInsertionStrategy,
                               delivery: TextInsertionDelivery,
                               targetPID: pid_t?) -> Bool {
        switch strategy {
        case .clipboardPaste:
            return ClipboardPasteInserter.insert(text, delivery: delivery, targetPID: targetPID)
        case .directUnicode:
            return DirectUnicodeInserter.insert(text, targetPID: targetPID)
        }
    }

    fileprivate static func targetAllowsPosting(_ expectedTargetPID: pid_t?) -> Bool {
        textInsertionTargetAllowsPosting(
            expectedTargetPID: expectedTargetPID,
            currentTargetPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
    }
}

@MainActor
private enum ClipboardPasteInserter {
    private static let virtualKeyCommand: CGKeyCode = 0x37  // left Command
    private static let virtualKeyV: CGKeyCode = 0x09  // ANSI 'v'
    private static let restoreDelayAfterRead: TimeInterval = 0.12
    private static let restoreTimeout: TimeInterval = 10
    private static var pendingTransaction: ClipboardPasteTransaction?

    static func insert(_ text: String,
                       delivery: TextInsertionDelivery,
                       targetPID: pid_t?) -> Bool {
        let pasteboard = NSPasteboard.general
        pendingTransaction?.restoreNowIfCurrent(reason: "superseded by another dictation")
        // Гасим и НЕЗАКРЫТУЮ транзакцию окна истории — здесь, а не только в самом окне.
        // В общий буфер пишут ДВА участка: окно истории (⌘C) и эта вставка. Если гасить
        // только в окне, остаётся второй путь: владелец скопировал запись в истории,
        // потом продиктовал обычным способом — снимок ниже захватил бы расшифровку
        // клиента, а в конце вернул бы её же в общий буфер и оставил там навсегда
        // (с Universal Clipboard — и на других устройствах).
        // Одна точка гашения на всех писателей, иначе следующий писатель повторит ошибку.
        DictationHistoryClipboard.quench(reason: "dictation insert takes over the pasteboard")
        let previous = PasteboardSnapshot.capture(from: pasteboard)
        let transaction = ClipboardPasteTransaction(
            text: text,
            pasteboard: pasteboard,
            previousSnapshot: previous,
            restoreDelay: restoreDelayAfterRead,
            restoreTimeout: restoreTimeout,
            delivery: delivery
        )
        transaction.onFinished = { [weak transaction] in
            guard let transaction, pendingTransaction === transaction else { return }
            pendingTransaction = nil
        }
        pendingTransaction = transaction
        guard transaction.install() else {
            pendingTransaction = nil
            log("pasteboard write failed")
            return false
        }

        guard TextInserter.targetAllowsPosting(targetPID) else {
            transaction.restoreNowIfCurrent(reason: "target application changed before paste")
            return false
        }

        let steps = clipboardPasteKeyboardEventSteps(commandKey: virtualKeyCommand,
                                                     pasteKey: virtualKeyV)
        guard post(steps, targetPID: targetPID) else {
            log("paste event creation failed")
            transaction.restoreNowIfCurrent(reason: "paste event creation failed")
            return false
        }
        return true
    }

    private static func post(_ steps: [KeyboardEventStep], targetPID: pid_t?) -> Bool {
        // Post Command as real key events instead of only tagging the V
        // events with .maskCommand. Sleep/wake can leave session modifier
        // state unreliable for flag-only synthetic shortcuts.
        return postKeyboardEventSteps(steps, targetPID: targetPID)
    }
}

@MainActor
private struct PasteboardSnapshot {
    private struct Item {
        let values: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { item -> NSPasteboardItem in
            let restored = NSPasteboardItem()
            for value in item.values {
                restored.setData(value.data, forType: value.type)
            }
            return restored
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

@MainActor
private final class ClipboardPasteTransaction: NSObject, NSPasteboardItemDataProvider {
    nonisolated let text: String
    let pasteboard: NSPasteboard
    let previousSnapshot: PasteboardSnapshot
    let restoreDelay: TimeInterval
    let restoreTimeout: TimeInterval
    /// Наблюдатель доставки: сюда уходит факт «цель забрала текст».
    let delivery: TextInsertionDelivery
    var onFinished: (() -> Void)?

    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var transientChangeCount: Int?
    private var restoreWorkItem: DispatchWorkItem?
    private var didProvideText = false
    private var isFinished = false

    init(text: String,
         pasteboard: NSPasteboard,
         previousSnapshot: PasteboardSnapshot,
         restoreDelay: TimeInterval,
         restoreTimeout: TimeInterval,
         delivery: TextInsertionDelivery,
         onFinished: (() -> Void)? = nil) {
        self.text = text
        self.pasteboard = pasteboard
        self.previousSnapshot = previousSnapshot
        self.restoreDelay = restoreDelay
        self.restoreTimeout = restoreTimeout
        self.delivery = delivery
        self.onFinished = onFinished
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
        scheduleRestore(after: restoreTimeout, reason: "target did not request dictation text")
        return true
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?,
                               item: NSPasteboardItem,
                               provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .string else { return }
        item.setString(text, forType: type)
        Task { @MainActor [weak self] in
            self?.textWasProvided()
        }
    }

    private func textWasProvided() {
        guard !isFinished, !didProvideText else { return }
        didProvideText = true
        // Единственный честный факт доставки — цель сама запросила данные.
        // Отсюда он и уходит наружу, к вердикту и звуку.
        delivery.noteTargetRequestedText()
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        log("pasteboard target requested dictation text after \(millisecondsLabel(elapsed))")
        scheduleRestore(after: restoreDelay, reason: "target consumed dictation text")
    }

    func restoreNowIfCurrent(reason: String) {
        restore(reason: reason)
    }

    private func scheduleRestore(after delay: TimeInterval, reason: String) {
        restoreWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.restore(reason: reason)
        }
        restoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private func restore(reason: String) {
        guard !isFinished else { return }
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        // Решение одно на обе точки записи в буфер (вставка надиктовки и ⌘C в
        // окне истории) — см. pasteboardRestoreDecision в
        // DictationHistoryClipboard.swift. Живой NSPasteboard в тесте не
        // наблюдается, а решение — наблюдается.
        switch pasteboardRestoreDecision(transientChangeCount: transientChangeCount,
                                        currentChangeCount: pasteboard.changeCount) {
        case .restore:
            previousSnapshot.restore(to: pasteboard)
            log("pasteboard restored after \(reason)")
        case .skip(let why):
            log("pasteboard restore skipped after \(reason): \(why)")
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

@MainActor
private enum DirectUnicodeInserter {
    private static let maxUTF16UnitsPerEvent = 20

    static func insert(_ text: String, targetPID: pid_t?) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        var didPostAll = true

        for chunk in unicodeInsertionChunks(for: text, maxUTF16UnitsPerEvent: maxUTF16UnitsPerEvent) {
            guard TextInserter.targetAllowsPosting(targetPID) else { return false }
            didPostAll = post(chunk, source: source, targetPID: targetPID) && didPostAll
        }
        return didPostAll
    }

    private static func post(_ units: [UInt16], source: CGEventSource?, targetPID: pid_t?) -> Bool {
        // Each chunk posts a keyDown AND a matching keyUp carrying the
        // same unicode payload — standard CGEvent unicode-typing
        // practice. A keyDown-only stream leaves apps that track key
        // state believing a key is still held.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }
        down.flags = []
        up.flags = []
        for event in [down, up] {
            units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
        }
        if let targetPID {
            down.postToPid(targetPID)
            up.postToPid(targetPID)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }
}
