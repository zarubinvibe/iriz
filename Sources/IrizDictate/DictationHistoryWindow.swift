// Плавающее окно истории надиктовок.
//
// Основано на SuperDictate (MIT, © 2026 Richard Courtman), коммит 83dd7e4:
// центрирование панели по видимой области экрана под курсором — строки
// 11780–11792 (`screenForRecordingHUD`/`screenFor`) и 12602–12614
// (`historyOverlayFrame`), перехват Escape в подклассе NSPanel — строки
// 9203–9216. Интерфейс свой.
//
// Локатор каретки донора (`FocusedInsertionTargetLocator`, строки 6185–6723,
// 539 строк обхода Accessibility) СОЗНАТЕЛЬНО не взят: донорское окно истории
// его тоже не зовёт, а непрочитанные 539 строк чужого AX-кода в продукте
// пользователя — риск без измеренной пользы.
//
// Здесь только рисование, клавиши и порядок операций. Все решения — в
// DictationHistory.swift, они под тестом.
import IrizCore
import AppKit
import Foundation
import SwiftUI

/// Сколько ждать, пока фокус вернётся предыдущему приложению, прежде чем
/// вставлять. Пока в фокусе наше окно, вставлять некуда — ⌘V уйдёт в наше поле
/// поиска.
let HISTORY_REFOCUS_TIMEOUT_SECONDS: TimeInterval = 0.7
private let HISTORY_REFOCUS_POLL_SECONDS: TimeInterval = 0.02

@MainActor
final class DictationHistoryPresenter {
    private var panel: DictationHistoryPanel?
    private var model: DictationHistoryModel?
    private var keyMonitor: Any?
    /// Приложение, из которого позвали окно: туда возвращается фокус и туда
    /// уходит вставка.
    private var callerApplication: NSRunningApplication?
    /// Поднят лист подтверждения «очистить всё». Пока он висит, клавиши окна
    /// не работают: Escape обязан закрывать вопрос, а не всё окно под ним.
    private var isConfirming = false
    private var presentationGeneration = 0
    private let dictationsRoot: () throws -> URL

    init(dictationsRoot: @escaping () throws -> URL = { try DictationStore.dictationsDirectory() }) {
        self.dictationsRoot = dictationsRoot
    }

    var isPresented: Bool { panel?.isVisible == true }

    func toggle() {
        isPresented ? close(returningFocus: true) : present(rescue: nil)
    }

    /// Вторая точка входа в ТО ЖЕ окно: показать текст, который не доехал до
    /// поля. Второго оконного слоя здесь нет намеренно — панель, монитор клавиш
    /// и порядок «закрыть → вернуть фокус → дождаться → вставить» уже написаны
    /// и уже правильные; отдельное окно повторило бы их заново и разошлось бы с
    /// ними на первой же правке.
    func presentRescue(_ rescue: DictationRescue) {
        present(rescue: rescue)
    }

    // MARK: - Показ

    private func present(rescue: DictationRescue?) {
        presentationGeneration += 1
        let entries: [DictationHistoryEntry]
        if rescue == nil {
            // Список читается ПОСЛЕ показа окна, в фоне. Владелец: «открываю
            // историю, и он как будто зависает». Замер подтвердил: 2047 записей
            // на диске - это 2047 каталогов и по три файла в каждом, шесть
            // тысяч чтений, 1386 мс НА ГЛАВНОМ ПОТОКЕ. Всё это время окно не
            // рисуется вовсе, потому что рисовать его некому.
            entries = []
        } else {
            // В режиме спасения список не показывается, и читать каталог незачем.
            // Важнее другое: недоступный каталог НЕ имеет права отменить показ.
            // Спасаемый текст на диске не лежит вовсе (inserted.txt пишется
            // только по подтверждённой доставке) — окно и есть его единственная
            // копия, и падать здесь значит потерять надиктовку целиком.
            entries = []
        }

        // Себя вызывающим не запоминаем. Иначе если хоткей нажат при открытом
        // окне настроек, Enter «вернул бы фокус» нам же и вставил расшифровку
        // клиента в наше собственное поле.
        //
        // ЗАБЫВАЕМ прошлого вызывающего в этом же случае, а не оставляем как
        // было. Прежний код только присваивал: открыл историю из Safari, закрыл,
        // позвал её снова из НАШЕГО окна настроек — и Enter отправлял бы текст в
        // Safari, куда владелец уже полчаса как не смотрит. Комментарий выше
        // ровно это и обещал («оставляет caller пустым»), но код обещание не
        // исполнял. Для окна спасения цена ошибки выше вдвойне: там расшифровка
        // речи клиента уехала бы в чужое приложение по одному нажатию ⏎.
        let front = NSWorkspace.shared.frontmostApplication
        callerApplication = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil
            : front

        let model = self.model ?? DictationHistoryModel()
        model.load(entries)
        model.showRescue(rescue)
        self.model = model
        model.onInsert = { [weak self] entry in self?.insert(text: entry.displayText) }
        model.onCopy = { [weak self] entry in self?.copy(text: entry.displayText) }
        model.onDelete = { [weak self] entry in self?.delete(entry) }
        model.onClearAll = { [weak self] in self?.clearAll() }
        model.onCloseWindow = { [weak self] in self?.close(returningFocus: true) }
        model.onInsertRescue = { [weak self] in self?.insertRescue() }
        model.onCopyRescue = { [weak self] in self?.copyRescue() }

        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        panel.setFrame(historyPanelFrame(), display: false)
        // LSUIElement-приложение иконки в Dock не имеет — поднимать нечего.
        // Активация нужна только чтобы панель получала клавиши; фокус уходит
        // назад явным вызовом в close().
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Поля поиска в режиме спасения нет — фокусировать нечего.
        model.focusSearchField = rescue == nil
        installKeyMonitor()
        if rescue == nil {
            model.reload(from: dictationsRoot)
        }
        if let rescue {
            // Ни имени приложения, ни самого текста в логе: лог живёт на диске
            // постоянно, а это речь клиента. Длины и класса провала для отладки
            // хватает.
            log("rescue: window shown (\(rescue.text.count) chars, \(rescue.failure.rawValue))")
        } else {
            log("history: window shown (\(entries.count) entries)")
        }
    }

    private func makePanel(model: DictationHistoryModel) -> DictationHistoryPanel {
        let panel = DictationHistoryPanel(
            contentRect: historyPanelFrame(),
            // .nonactivatingPanel — окно принимает клавиши, не делая нас
            // «настоящим» активным приложением. .titled даёт скругление, тень
            // и кнопку закрытия системой, а не нашим рисованием.
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // Крестик СИСТЕМНЫЙ, свёрнуть и развернуть спрятаны.
        //
        // Решение владельца 07.09.2026: «нет нормальной клавиши закрыть, оно
        // должно быть такое системное, как в macOS, а не как там сейчас».
        // Отменяет решение 06.09.2026, которым светофор был снят целиком: тогда
        // мешали три чужие кнопки, а не сама возможность закрыть окно мышью.
        // Красный кружок macOS человек находит не глядя - своя иконка в шапке
        // этого не даёт, сколько её ни рисуй.
        //
        // Свёрнуть и развернуть остаются спрятанными: у панели истории нет
        // ни осмысленного свёрнутого состояния, ни второго размера.
        panel.standardWindowButton(.closeButton)?.isHidden = false
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        // Прозрачный корпус, как у окна настроек. Без него стекло внутри
        // сэмплирует собственную серую плиту окна, а не то, что за ним, и
        // окно истории остаётся единственной непрозрачной панелью продукта.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.onClose = { [weak self] in self?.close(returningFocus: true) }
        panel.contentView = NSHostingView(rootView: DictationHistoryView(model: model))
        return panel
    }

    /// По центру видимой области того экрана, где сейчас курсор.
    private func historyPanelFrame() -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(680, max(360, visible.width - 96))
        let height = min(560, max(280, visible.height - 160))
        return NSRect(x: visible.midX - width / 2,
                      y: visible.midY - height / 2,
                      width: width,
                      height: height)
    }

    // MARK: - Закрытие и возврат фокуса

    private func close(returningFocus: Bool) {
        presentationGeneration += 1
        removeKeyMonitor()
        model?.cancelLoading()
        model?.isClearing = false
        model?.focusSearchField = false
        // Спасённый текст живёт ровно столько, сколько висит окно. Иначе
        // следующее открытие истории по хоткею подняло бы чужую позавчерашнюю
        // неудачу вместо списка.
        model?.showRescue(nil)
        panel?.orderOut(nil)
        guard returningFocus else { return }
        returnFocusToCaller()
    }

    private func returnFocusToCaller() {
        guard let caller = callerApplication, !caller.isTerminated else { return }
        caller.activate()
    }

    // MARK: - Действия

    /// Спасённый текст идёт ТЕМ ЖЕ путём, что запись истории: порядок «закрыть →
    /// вернуть фокус → дождаться → вставить» здесь несущий, и второй его копии
    /// в проекте быть не должно.
    private func insertRescue() {
        guard let rescue = model?.rescue else { return }
        insert(text: rescue.text, retrying: rescue)
    }

    private func copyRescue() {
        guard let text = model?.rescue?.text else { return }
        copy(text: text)
    }

    /// Порядок обязателен: скрыть окно → вернуть фокус → дождаться фокуса →
    /// вставить. Пока наше окно в фокусе, вставлять некуда.
    ///
    /// `retrying` не nil — вставка идёт из окна спасения. Тогда неудача обязана
    /// ВЕРНУТЬ окно: спасаемого текста на диске нет вовсе, и закрытое окно на
    /// провале — это потерянная надиктовка, а не «попробуйте ещё раз».
    private func insert(text: String, retrying: DictationRescue? = nil) {
        guard !text.isEmpty else {
            // Отклик обязателен, как у двух соседних отказов ниже: молча закрывшееся
            // окно владелец прочтёт как «вставилось», и это ровно та ложь, из-за
            // которой переписывался весь этап вставки.
            log("history: entry is empty — nothing to insert")
            failureFeedback()
            close(returningFocus: true)
            return
        }
        // Не знаем КУДА — не вставляем. Хоткей истории, нажатый при открытом
        // окне настроек, оставляет caller пустым (себя вызывающим не
        // запоминаем), и ⌘V ушёл бы в наше же поле словаря замен — расшифровка
        // речи клиента уехала бы в настройки. «Никуда» лучше, чем «в себя».
        guard let caller = callerApplication else {
            log("history: caller app unknown — NOT inserting")
            failureFeedback()
            guard let retrying else {
                close(returningFocus: true)
                return
            }
            // Окно не трогаем вовсе: оно уже на экране и держит единственную
            // копию текста. Владельцу — строка, почему повтор не сработал.
            model?.showRescueNotice(dictationRescueRetryNotice(.unknownTarget))
            return
        }
        close(returningFocus: true)

        Task { @MainActor in
            // Ждём именно ВОЗВРАТА фокуса вызывающему. Раньше здесь стояло
            // «inserting anyway»: если фокус не вернулся, ⌘V летел в текущий
            // фронтмост — то есть в наше же окно. Промах в чужое приложение
            // тоже недопустим: это текст клиента.
            guard await Self.waitForFocus(of: caller) else {
                log("history: focus did not return to caller in \(HISTORY_REFOCUS_TIMEOUT_SECONDS) s — NOT inserting")
                failureFeedback()
                restoreRescue(retrying, notice: .focusDidNotReturn)
                return
            }
            // Гасим незакрытое ⌘C ДО того, как TextInserter снимет снимок
            // буфера. Иначе: владелец скопировал запись, передумал, переоткрыл
            // историю и нажал Enter — TextInserter снял бы снимок буфера, на
            // котором лежит запись клиента, и в конце вернул бы ЕЁ же. Текст
            // клиента остался бы в общем буфере навсегда и уехал бы с Universal
            // Clipboard на другие устройства.
            DictationHistoryClipboard.quench(reason: "вставка из окна истории")
            let attempt = TextInserter.insert(text)
            let verdict = await TextInserter.confirmDelivery(attempt)
            switch verdict {
            case .delivered:
                // Имени приложения-получателя здесь быть НЕ ДОЛЖНО. Лог
                // штампуется временем и живёт на диске постоянно — с именем
                // получателя вышел бы durable-журнал «в 14:32 вставил 812
                // символов в Telegram», то есть метаданные о том, с кем и когда
                // владелец работает, которых до этого на диске не было. Длины и вердикта
                // для отладки достаточно.
                log("history: entry inserted (\(text.count) chars)")
            case .waiting:
                log("history: insertion verdict unresolved — counted as failure")
            case .notDelivered(let failure):
                log("history: entry NOT inserted — \(failure.rawValue)")
            }
            // Повтор провалился — окно возвращается с тем же текстом. Решение
            // «возвращать или молчать» берётся ТОЙ ЖЕ функцией, что решала
            // первый провал: двух политик на один вопрос быть не должно, иначе
            // они разойдутся. В частности, прямой ввод юникодом окно не вернёт —
            // там текст, скорее всего, уже в поле.
            if retrying != nil {
                switch dictationRecoveryPresentation(
                    verdict: verdict,
                    rescueEnabled: DictationSettings.shared.rescueWindowEnabled,
                    hasText: !text.isEmpty
                ) {
                case .stayQuiet:
                    break
                case .rescueWindow(let failure):
                    restoreRescue(DictationRescue(text: text, failure: failure),
                                  notice: .notDelivered)
                }
            }
            if DictationSettings.shared.playFeedbackSounds {
                switch dictationFeedbackSound(for: verdict) {
                case .done: Sounds.playDone()
                case .error: Sounds.playError()
                }
            }
        }
    }

    /// Возвращает окно спасения на экран после неудачного повтора — с тем же
    /// текстом и строкой о том, что именно не вышло. `nil` — вставка шла из
    /// списка истории, возвращать нечего: та запись лежит на диске.
    private func restoreRescue(_ rescue: DictationRescue?,
                               notice: DictationRescueRetryOutcome) {
        guard let rescue else { return }
        presentRescue(rescue)
        // Строго ПОСЛЕ показа: present() поднимает окно заново и обнуляет строку.
        model?.showRescueNotice(dictationRescueRetryNotice(notice))
    }

    /// Отказ вставить — не молчаливый: владелец должен услышать, что текст
    /// никуда не поехал, иначе решит, что вставка удалась.
    private func failureFeedback() {
        if DictationSettings.shared.playFeedbackSounds { Sounds.playError() }
    }

    /// `true` — фронтмост стал именно вызывающим. Вставлять можно только по
    /// `true`: любой другой фронтмост (в том числе мы сами) — не адресат.
    private static func waitForFocus(of application: NSRunningApplication) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + HISTORY_REFOCUS_TIMEOUT_SECONDS
        while ProcessInfo.processInfo.systemUptime < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(HISTORY_REFOCUS_POLL_SECONDS * 1_000_000_000))
        }
        return false
    }

    private func copy(text: String) {
        guard DictationHistoryClipboard.copy(text) else {
            model?.showError(L("history.copyFailed", "Не удалось скопировать. Попробуй ещё раз."))
            if DictationSettings.shared.playFeedbackSounds { Sounds.playError() }
            return
        }
        close(returningFocus: true)
    }

    private func delete(_ entry: DictationHistoryEntry) {
        guard model?.isClearing != true else { return }
        do {
            try removeDictationHistoryEntry(entry)
            log("history: entry \(entry.label) moved to Trash with its directory")
            reload()
        } catch {
            log("history: cannot delete \(entry.label): \(error.localizedDescription)")
            model?.showError(L("history.deleteFailed", "Не удалось переместить запись в Корзину. Попробуй ещё раз."))
            if DictationSettings.shared.playFeedbackSounds { Sounds.playError() }
        }
    }

    private func clearAll() {
        guard let model, let panel, !model.entries.isEmpty, !isConfirming, !model.isClearing else { return }
        let generation = presentationGeneration
        model.isClearing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let root = try self.dictationsRoot()
                let doomed = try await Task.detached(priority: .userInitiated) {
                    try readDictationHistoryEntries(in: root)
                }.value
                guard self.presentationGeneration == generation, panel.isVisible else { return }
                guard !doomed.isEmpty else {
                    model.isClearing = false
                    self.reload()
                    return
                }
                self.confirmClearAll(doomed, model: model, panel: panel)
            } catch {
                guard self.presentationGeneration == generation else { return }
                model.isClearing = false
                model.showError(L("history.readFailed", "Не удалось прочитать историю. Попробуй открыть её снова."))
            }
        }
    }

    private func confirmClearAll(_ doomed: [DictationHistoryEntry],
                                 model: DictationHistoryModel,
                                 panel: DictationHistoryPanel) {
        // Число записей — ДО удаления и в самом вопросе: иначе владелец
        // подтверждает вслепую. Снимок включает весь архив, а не видимую сотню.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = dictationHistoryClearConfirmation(count: doomed.count)
        alert.informativeText = L("history.trashNote", "Папки надиктовок уедут в Корзину — оттуда их можно вернуть.")
        alert.addButton(withTitle: L("history.toTrash", "В Корзину"))
        alert.addButton(withTitle: L("history.cancel", "Отмена"))

        // Листом на панель, а не runModal(): панель на уровне .floating, и
        // отдельное модальное окно системного уровня ушло бы ПОД неё —
        // владелец увидел бы застывшее окно без вопроса.
        isConfirming = true
        alert.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isConfirming = false
                guard response == .alertFirstButtonReturn else {
                    model.isClearing = false
                    log("history: clear all cancelled (\(doomed.count) entries kept)")
                    return
                }
                Task { @MainActor in
                    let deleted = await Task.detached(priority: .userInitiated) {
                        var deleted = 0
                        for entry in doomed {
                            do {
                                try removeDictationHistoryEntry(entry)
                                deleted += 1
                            } catch {
                                log("history: cannot delete \(entry.label): \(error.localizedDescription)")
                            }
                        }
                        return deleted
                    }.value
                    model.isClearing = false
                    log("history: cleared \(deleted) of \(doomed.count) entries")
                    self.reload()
                    if deleted != doomed.count {
                        model.showError(Lf("history.clearFailed", "Не удалось переместить в Корзину: %d из %d. Остальные записи уже в Корзине.", doomed.count - deleted, doomed.count))
                    }
                }
            }
        }
    }

    private func reload() {
        guard let model else { return }
        model.reload(from: dictationsRoot)
    }

    // MARK: - Клавиши

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Монитор приходит уже на главную очередь; NSEvent не Sendable,
            // поэтому наружу из изолированного участка уезжает только Bool.
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, event.window === panel else { return false }
                return self.handle(event)
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// `true` — нажатие съедено окном, в поле поиска не уходит.
    private func handle(_ event: NSEvent) -> Bool {
        guard let model, !isConfirming else { return false }
        // Выделенный текст принадлежит редактору поиска/спасения: ⌘C должен
        // копировать именно выделение, не выбранную запись и не закрывать окно.
        let editor = panel?.firstResponder as? NSTextView
        let action = dictationHistoryKeyAction(
            keyCode: CGKeyCode(event.keyCode),
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            hasCommand: event.modifierFlags.contains(.command),
            hasTextSelection: (editor?.selectedRange().length ?? 0) > 0
        )
        // В режиме спасения списка на экране нет, и те же клавиши обязаны
        // относиться к спасённому тексту, а не к невидимой выделенной записи.
        if model.rescue != nil {
            switch dictationRescueKeyOutcome(action) {
            case .insertRescueText:
                insertRescue()
                return true
            case .copyRescueText:
                copyRescue()
                return true
            case .close:
                close(returningFocus: true)
                return true
            case .ignore:
                return false
            }
        }
        switch action {
        case .passThrough:
            return false
        case .close:
            close(returningFocus: true)
            return true
        case .moveSelection(let delta):
            model.moveSelection(by: delta)
            return true
        case .insertSelected:
            guard let entry = model.selectedEntry else { return true }
            insert(text: entry.displayText)
            return true
        case .copySelected:
            guard let entry = model.selectedEntry else { return true }
            copy(text: entry.displayText)
            return true
        }
    }
}

// MARK: - Панель

@MainActor
private final class DictationHistoryPanel: NSPanel {
    var onClose: (() -> Void)?

    /// Нужен ввод в поле поиска — панель обязана становиться key.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        onClose?()
    }
}

// MARK: - Модель списка

@MainActor
public final class DictationHistoryModel: ObservableObject {
    @Published public private(set) var entries: [DictationHistoryEntry] = []
    @Published public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            clampSelection()
            // Первый же символ запроса дочитывает всё хранимое: искать по
            // видимой сотне значит молча врать «ничего не нашлось».
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !didLoadAll, !isLoadingAll, let root {
                loadInBackground(from: root, all: true)
            }
        }
    }
    @Published private(set) var selection: Int = 0
    @Published var focusSearchField = false
    /// Список ещё читается с диска. Отдельный признак, а не пустой список:
    /// «пока ничего нет» и «ещё не прочитал» - разные вещи, и путать их значит
    /// врать владельцу, у которого две тысячи надиктовок.
    @Published public private(set) var isLoading = false
    @Published public var notice: String?
    @Published public var noticeIsError = false
    @Published var isClearing = false
    /// Дочитано ли всё хранимое. Показ начинается с сотни свежих; поиск
    /// дочитывает остальное один раз.
    private(set) var didLoadAll = false
    private var isLoadingAll = false
    private var loadGeneration = 0
    private var root: URL?
    private let isPreview: Bool

    public init(preview: Bool = false) {
        isPreview = preview
    }
    /// Не `nil` — окно показывает не список, а текст, который не доехал до поля.
    @Published private(set) var rescue: DictationRescue?
    /// Почему не сработал повтор вставки. Звука тут мало: владелец должен
    /// прочитать, что делать дальше, а не гадать по гудку.
    @Published private(set) var rescueNotice: String?

    var onInsert: ((DictationHistoryEntry) -> Void)?
    var onCopy: ((DictationHistoryEntry) -> Void)?
    var onDelete: ((DictationHistoryEntry) -> Void)?
    var onClearAll: (() -> Void)?
    /// Кого звать по крестику. Окно закрывается тремя путями - крестиком,
    /// Escape и уходом фокуса, - и все три ведут в одну точку презентера.
    var onCloseWindow: (() -> Void)?
    var onInsertRescue: (() -> Void)?
    var onCopyRescue: (() -> Void)?

    public var visible: [DictationHistoryEntry] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Array(entries.prefix(DICTATION_HISTORY_VISIBLE_LIMIT))
            : filteredDictationHistory(entries, query: query)
    }

    /// Превью проверяется ДО получения корня: даже путь к живому store не нужен.
    public func reload(from rootProvider: () throws -> URL) {
        cancelLoading()
        didLoadAll = false
        guard !isPreview else {
            load([])
            return
        }
        do {
            let root = try rootProvider()
            self.root = root
            loadInBackground(from: root,
                             all: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } catch {
            showError(L("history.readFailed", "Не удалось прочитать историю. Попробуй открыть её снова."))
        }
    }

    public func cancelLoading() {
        loadGeneration += 1
        isLoading = false
        isLoadingAll = false
        root = nil
    }

    func showError(_ message: String) {
        notice = message
        noticeIsError = true
    }

    private func loadInBackground(from root: URL, all: Bool) {
        let generation = beginLoading(all: all)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                // ponytail: весь архив читается лишь при поиске; индекс нужен,
                // если измеренное время чтения станет мешать поиску.
                try readDictationHistoryEntries(in: root,
                                               limit: all ? nil : DICTATION_HISTORY_VISIBLE_LIMIT)
            }
            await self?.completeLoading(result, generation: generation, all: all)
        }
    }

    /// Поколение общее для краткого списка, поиска и повторного открытия.
    func beginLoading(all: Bool) -> Int {
        loadGeneration += 1
        isLoading = true
        isLoadingAll = all
        notice = nil
        noticeIsError = false
        return loadGeneration
    }

    func completeLoading(_ result: Result<[DictationHistoryEntry], Error>,
                         generation: Int, all: Bool) {
        guard generation == loadGeneration else { return }
        isLoading = false
        isLoadingAll = false
        switch result {
        case .success(let found):
            load(found)
            didLoadAll = all
        case .failure:
            showError(L("history.readFailed", "Не удалось прочитать историю. Попробуй открыть её снова."))
        }
    }

    var selectedEntry: DictationHistoryEntry? {
        let list = visible
        guard !list.isEmpty else { return nil }
        return list[clampedHistorySelection(selection, count: list.count)]
    }

    func load(_ entries: [DictationHistoryEntry]) {
        self.entries = entries
        clampSelection()
    }

    func showRescue(_ rescue: DictationRescue?) {
        self.rescue = rescue
        rescueNotice = nil
    }

    func showRescueNotice(_ notice: String?) {
        rescueNotice = notice
    }

    func moveSelection(by delta: Int) {
        selection = movedHistorySelection(from: selection, by: delta, count: visible.count)
    }

    func select(_ entry: DictationHistoryEntry) {
        guard let index = visible.firstIndex(of: entry) else { return }
        selection = index
    }

    private func clampSelection() {
        selection = clampedHistorySelection(selection, count: visible.count)
    }
}

// MARK: - Вид

// `private` снят ради прибора раскадровки поверхностей: снимок обязан показывать
// ТОТ ЖЕ вид, что живёт в панели, а не его копию. Тип остаётся внутренним для модуля.
struct DictationHistoryView: View {
    @ObservedObject var model: DictationHistoryModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let rescue = model.rescue {
                rescueBody(rescue)
            } else {
                historyBody
            }
        }
        .frame(minWidth: 360, minHeight: 280)
        // Тот же фон, что у настроек: прозрачное стекло с преломлением.
        .background(IrizGlassBackdrop())
        .onChange(of: model.focusSearchField) { _, wanted in searchFocused = wanted }
        .onAppear { searchFocused = model.rescue == nil }
    }

    private var historyBody: some View {
        // Список и подвал - плавающие плиты канона, как в настройках: шапка со
        // строкой поиска на одной, список на второй, подвал на третьей.
        // Разделители при этом не нужны: границу держит сама плита.
        VStack(spacing: IrizGlassBackdrop.plateInset) {
            VStack(spacing: 0) {
                titleRow
                searchRow
            }
            .background(IrizFloatingPlate())

            Group {
                if model.visible.isEmpty {
                    if let notice = model.notice, model.noticeIsError {
                        Label(notice, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .padding(24)
                    } else {
                        emptyState
                    }
                } else {
                    list
                }
            }
            .frame(maxHeight: .infinity)
            .background(IrizFloatingPlate())

            if model.isLoading, !model.entries.isEmpty {
                ProgressView(L("history.loading", "Читаю надиктовки…"))
                    .controlSize(.small)
            }
            if let notice = model.notice, !model.entries.isEmpty {
                Label(notice, systemImage: model.noticeIsError ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(model.noticeIsError ? Color.red : Color.primary)
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
            }

            footer
                .background(IrizFloatingPlate())
        }
        .padding(IrizGlassBackdrop.plateInset)
    }

    // MARK: - Спасение

    /// Список здесь не показывается намеренно: пока на экране текст, который
    /// НЕ доехал, ⏎ обязан относиться к нему. Со списком под ним владелец не
    /// знал бы, что именно сейчас вставится, а цена ошибки — чужая расшифровка
    /// в документе.
    private func rescueBody(_ rescue: DictationRescue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(DICTATION_RESCUE_TITLE)
                        .font(.system(size: 15, weight: .semibold))
                    Text(dictationRescueExplanation(for: rescue.failure))
                        .font(.system(size: 12))
                        .foregroundStyle(IRIZ_SUBTLE)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(DICTATION_RESCUE_TITLE). \(dictationRescueExplanation(for: rescue.failure))")

            ScrollView {
                Text(rescue.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.quaternary)
            )
            .accessibilityLabel(L("history.rescueTitle", "Текст, который не вставился"))

            HStack(spacing: 10) {
                Button(L("history.insertAgain", "Вставить ещё раз")) { model.onInsertRescue?() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(L("history.insertAgainHint", "Вставить этот текст ещё раз"))
                Button(L("history.copy", "Скопировать")) { model.onCopyRescue?() }
                    .accessibilityLabel(L("history.copyHint", "Скопировать этот текст"))
                Spacer()
                Text("\(rescue.text.count) \(L("history.charsShort", "симв."))")
                    .font(.system(size: 11))
                    .foregroundStyle(IRIZ_SUBTLE)
            }

            if let notice = model.rescueNotice {
                Label(notice, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(notice)
            }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
            }

            HStack(spacing: 12) {
                hint("⏎", L("history.legendInsert", "вставить"))
                hint("⌘C", L("history.legendCopyTimed", "копировать · буфер очистится через 2 мин"))
                hint("esc", L("history.legendClose", "закрыть"))
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Заголовок окна. Прежде окно открывалось сразу списком, без имени:
    /// у поверхности, которую вызывают хоткеем, обязана быть подпись - иначе
    /// непонятно, чьё это окно, когда оно всплывает поверх чужого.
    private var titleRow: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: DICTATION_HUD_WAVE_GREEN))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text("\(IRIZ_NAME) · \(L("history.windowTitle", "надиктовки"))")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Text("\(model.entries.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IRIZ_SUBTLE)
                .monospacedDigit()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous).fill(Color.primary.opacity(0.08))
                )
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Lf("history.window.a11y", "%@, надиктовок %d", IRIZ_NAME, model.entries.count))
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(IRIZ_SUBTLE)
            TextField(L("history.searchPlaceholder", "Поиск по надиктовкам"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(IRIZ_SUBTLE)
                }
                .buttonStyle(.plain)
                .help(L("history.searchClear", "Очистить поиск"))
                .accessibilityLabel(L("history.searchClear", "Очистить поиск"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Поле поиска на своей плите канона - той же, что в окне настроек.
        // Голое поле на стекле не читалось полем вовсе.
        .background(IrizSearchFieldPlate())
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            // Три разных состояния, а не два: «читаю», «пусто» и «не нашлось».
            // Пока список ехал с диска, окно показывало «надиктовок пока нет» -
            // прямую ложь человеку, у которого их две тысячи.
            Text(model.isLoading
                 ? L("history.loading", "Читаю надиктовки…")
                 : (model.entries.isEmpty
                    ? L("history.emptyTitle", "Надиктовок пока нет")
                    : L("history.notFoundTitle", "Ничего не нашлось")))
                .font(.system(size: 14, weight: .medium))
            Text(model.isLoading
                 ? L("history.loadingBody", "Показываю последние сто. Остальные найдёт поиск.")
                 : (model.entries.isEmpty
                    ? L("history.emptyBody", "Продиктуйте что-нибудь — запись появится здесь.")
                    : L("history.notFoundBody", "Попробуйте другое слово.")))
                .font(.system(size: 12))
                .foregroundStyle(IRIZ_SUBTLE)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var list: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.visible.enumerated()), id: \.element.id) { index, entry in
                        Button { model.select(entry) } label: {
                            row(entry, isSelected: index == model.selection)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(index == model.selection ? .isSelected : [])
                        .accessibilityAction(named: Text(L("history.insert", "Вставить"))) { model.onInsert?(entry) }
                        .accessibilityAction(named: Text(L("history.copyButton", "Копировать"))) { model.onCopy?(entry) }
                        .id(entry.id)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
            }
            .onChange(of: model.selection) { _, _ in
                guard let id = model.selectedEntry?.id else { return }
                withAnimation(irizAnimation(.irizQuick)) { scroll.scrollTo(id) }
            }
        }
    }

    @Namespace private var historySelection

    private func row(_ entry: DictationHistoryEntry, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(dictationHistoryPreview(entry.displayText))
                .font(.system(size: 13))
                // Белый по сплошному акценту давал контраст 4,02 при пороге
                // 4,5. На тонированном стекле подложка просвечивает, и
                // системный цвет остаётся читаемым в обоих состояниях.
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(dictationHistoryTimeLabel(entry.label))
                Text("·")
                Text("\(entry.displayText.count) \(L("history.charsShort", "симв."))")
            }
            .font(.system(size: 11))
            // Тот же довод, что строкой выше у заголовка: подсветка теперь
            // тонированное стекло, а не сплошной акцент. Белый остался здесь
            // от прежней заливки и на светлой теме читался как пропавшая
            // строка - дата выделенной надиктовки была белым по светло-серому.
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Подсветка канона продукта: одна капсула стекла на весь список, она
        // ПЕРЕЕЗЖАЕТ между строками. Свой радиус 8 и своя сплошная заливка
        // были третьим способом подсветки в одном продукте.
        .irizSelected(isSelected, in: historySelection, group: "history")
        .contextMenu {
            Button(L("history.insert", "Вставить")) { model.onInsert?(entry) }
            Button(L("history.copyButton", "Копировать")) { model.onCopy?(entry) }
            Divider()
            Button(L("history.trashOne", "Переместить в Корзину"), role: .destructive) { model.onDelete?(entry) }
                .disabled(model.isClearing)
        }
    }

    /// Подвал: строка подсказок и под ней одно пояснение.
    ///
    /// Прежде пояснение про буфер жило ВНУТРИ подсказки «⌘C», и на ширине окна
    /// две подсказки из четырёх переносились на вторую строку - подвал шёл
    /// зубцами, а глаз читал это как небрежность. Подсказка называет клавишу
    /// и действие одной строкой; всё, что длиннее, - уже пояснение, и его
    /// место под строкой.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isClearing {
                ProgressView(L("history.clearing", "Подготовка и очистка истории…"))
                    .controlSize(.small)
            }
            HStack(spacing: 12) {
                hint("⏎", L("history.legendInsert", "вставить"))
                hint("⌘C", L("history.legendCopy", "копировать"))
                hint("esc", L("history.legendClose", "закрыть"))
                // Удаление НЕ на клавише: ⌘⌫ — системный шорткат поля поиска, и по
                // мышечной памяти он сносил бы расшифровку. Только правым щелчком.
                Text(L("history.legendDelete", "удалить — правым щелчком"))
                    .font(.system(size: 11))
                    .foregroundStyle(IRIZ_SUBTLE)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 12)
                clearAllButton
            }
            // Цена решения «по истечении окна удержания буфер чистится, а не
            // возвращается к прежнему»: через две минуты буфер владельца пуст.
            // Решение верное (подменённый старый текст в договоре не заметен,
            // а «⌘V ничего не вставил» заметен сразу), но молчать о нём нельзя.
            Text(L("history.clipboardNote", "Скопированное держится в буфере 2 минуты, потом буфер чистится."))
                .font(.system(size: 11))
                .foregroundStyle(IRIZ_SUBTLE)
                .accessibilityLabel(L("history.clipboardNoteVoice", "Скопированное держится в буфере две минуты, потом буфер чистится"))
            if model.query.isEmpty, model.entries.count >= DICTATION_HISTORY_VISIBLE_LIMIT {
                Text(L("history.loadingBody", "Показываю последние сто. Остальные найдёт поиск."))
                    .font(.system(size: 11))
                    .foregroundStyle(IRIZ_SUBTLE)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Кнопка «Очистить всё» стеклом канона, а не системным безелем: системная
    /// кнопка на стеклянной панели читается деталью macOS, попавшей внутрь
    /// продукта.
    @ViewBuilder
    private var clearAllButton: some View {
        let label = Text(L("history.clearAll", "Очистить всё")).font(.system(size: 12, weight: .medium))
        if #available(macOS 26.0, *) {
            Button(action: { model.onClearAll?() }) { label }
                .buttonStyle(.glass)
                .disabled(model.entries.isEmpty || model.isClearing)
                .help(L("history.clearAllHint", "Переместить все надиктовки в Корзину"))
        } else {
            Button(action: { model.onClearAll?() }) { label }
                .disabled(model.entries.isEmpty || model.isClearing)
                .help(L("history.clearAllHint", "Переместить все надиктовки в Корзину"))
        }
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
            Text(what).font(.system(size: 11)).foregroundStyle(IRIZ_SUBTLE)
        }
    }
}
