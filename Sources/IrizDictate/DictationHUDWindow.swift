// Части адаптированы из SuperDictate (форк Parakey), © 2026 Richard Courtman, лицензия MIT.
// Полный текст: THIRD-PARTY/SuperDictate-LICENSE

import AppKit
import Foundation
import QuartzCore

private final class DictationHUDNotificationObserver: @unchecked Sendable {
    let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

private final class DictationHUDDisplayLinkStorage: @unchecked Sendable {
    var value: CADisplayLink?
    deinit { value?.invalidate() }
}

func dictationHUDReduceMotionEnabled() -> Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

/// Сколько заняла дорога от «попросили показать плашку» до первого кадра
/// с пилюлей в буфере окна. Ради этого числа всё и делалось, поэтому оно
/// не в чьей-то памяти, а в логе — один раз за процесс.
struct DictationHUDFirstShowMetric: Equatable {
    /// Прогрев успел до первого показа. `false` — жалоба владельца
    /// воспроизводится: панель, шейдер и первый кадр платятся при нём.
    let prewarmed: Bool
    /// До `orderFront` — панель уже поднята, но при включённой анимации
    /// на ней ещё пусто.
    let orderedSeconds: TimeInterval
    /// До первого кадра, на котором есть что показывать.
    let paintedSeconds: TimeInterval

    var logLine: String {
        String(format: "HUD first show: %.0f ms до первого кадра, %.0f ms до подъёма панели, прогрев %@",
               paintedSeconds * 1000,
               orderedSeconds * 1000,
               prewarmed ? "был" : "не успел")
    }
}

@MainActor
private protocol DictationHUDContainerDelegate: AnyObject {
    func hudMouseEntered()
    func hudMouseExited()
    func hudMouseDown(at screenPoint: CGPoint)
    func hudMouseDragged(to screenPoint: CGPoint)
    func hudMouseUp(at screenPoint: CGPoint)
    func hudRightMouseDown(with event: NSEvent, in view: NSView)
}

@MainActor
private final class DictationHUDContainerView: NSView {
    weak var delegate: DictationHUDContainerDelegate?
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Плашка целиком принимает мышь сама: по ней тащат, на неё наводят.
    /// Исключение - панель расшифровки: в ней есть кнопка и выделяемый текст,
    /// и забрать у них клик значит сделать их мёртвыми. Ровно это и вышло:
    /// кнопка «Скопировать» рисовалась и не работала.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        // `hitTest` получает точку в системе НАДвида, а раздаёт детям в своей.
        // Направление перевода тут решает, дойдёт ли клик до кнопки вообще.
        for view in subviews where view is DictationHUDTranscriptView {
            if let hit = view.hitTest(convert(point, from: superview)) { return hit }
        }
        return self
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { delegate?.hudMouseEntered() }
    override func mouseExited(with event: NSEvent) { delegate?.hudMouseExited() }
    override func mouseDown(with event: NSEvent) { delegate?.hudMouseDown(at: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { delegate?.hudMouseDragged(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { delegate?.hudMouseUp(at: NSEvent.mouseLocation) }
    // Правая кнопка, а не левая: левая занята перетаскиванием плашки, и
    // отбирать её у жеста, которым владелец двигает плашку каждый день, нельзя.
    override func rightMouseDown(with event: NSEvent) {
        delegate?.hudRightMouseDown(with: event, in: self)
    }
}

@MainActor
private final class DictationHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DictationHUDDisplayLinkProxy: NSObject {
    weak var owner: DictationHUDPanelSurface?

    @objc func fired(_ link: CADisplayLink) { owner?.displayLinkFired(link) }
}

@MainActor
final class DictationHUDPanelSurface: NSObject, DictationHUDSurface, DictationHUDContainerDelegate {
    /// Что плашка умеет попросить у приложения. Пусто до подключения: плашка
    /// показывается и без управления, просто без меню.
    var controls: DictationHUDControls?

    private struct ScalarAnimation {
        let from: CGFloat
        let to: CGFloat
        let startedAt: TimeInterval
        let duration: TimeInterval
        let completion: (() -> Void)?
    }

    private let settings: DictationSettings
    private let reduceMotionEnabled: () -> Bool

    private var panel: DictationHUDPanel?
    private var container: DictationHUDContainerView?
    private var capsule: DictationHUDCapsuleView?
    /// Стеклянная плашка. Есть только на macOS 26 и старше; на младших
    /// системах работает прежний путь через `capsule`.
    private var glassStack: AnyObject?
    private var waveBars: DictationHUDWaveBarsView?
    /// История уровней для звуковой волны: она показывает ФРАЗУ, а не одно
    /// число, размноженное по ширине.
    private var levelTrail = DictationHUDLevelTrail()
    /// Режим текущей плашки. Ставится на записи и живёт до её конца.
    private var lastPurpose: DictationRecordingPurpose = .dictation
    /// Текущее и целевое схлопывание волны в линию. Между ними едет пружина:
    /// мгновенная подмена читалась бы как «картинку заменили», а не как
    /// «волна улеглась».
    private var waveCollapse: CGFloat = 0
    private var waveCollapseTarget: CGFloat = 0
    /// Вспышка исхода: сначала разгорается, потом гаснет. Одно движение,
    /// а не постоянное свечение - оно сообщает МОМЕНТ, что работа кончилась.
    private var flashAge: TimeInterval?
    private var flashColor: NSColor = DICTATION_HUD_WAVE_GREEN
    private var flashPeak: CGFloat = 0
    /// Переход формы: из какой в какую и насколько он прошёл. Форму ведём
    /// САМИ, а не неявной анимацией слоя: у стекла она не срабатывает, и
    /// плашка скачком меняла размер - «замирает картинка и потом резко
    /// маленькая становится».
    private var glassFrom: DictationHUDGlassShape?
    private var glassTo: DictationHUDGlassShape?
    private var glassProgress: CGFloat = 1
    private var hint: DictationHUDHintView?
    /// Панель с не доехавшим текстом. Заводится лениво: у подавляющего
    /// большинства надиктовок текст доезжает, и держать ради них NSTextView
    /// в памяти незачем.
    private var transcript: DictationHUDTranscriptView?
    /// Раскрытие панели расшифровки: 0 - плашка, 1 - панель целиком.
    /// Плашка ОБЯЗАНА доехать до панели движением, а не подменой кадра:
    /// мгновенная замена маленького кружка большим прямоугольником читается
    /// поломкой, и владелец увидел ровно это.
    private var transcriptCopiedHandler: (() -> Void)?
    private var transcriptProgress: CGFloat = 0
    private var transcriptTarget: CGFloat = 0
    /// Сколько панель уже висит и сколько ей отмерено. Кольцо отсчета на
    /// крестике показывает ЭТО, а не свой отдельный таймер: два независимых
    /// отсчета разъезжаются, и кольцо начинает врать про то, когда панель уйдет.
    private var transcriptAge: TimeInterval = 0
    private var transcriptLifetime: TimeInterval = 0
    private var transcriptPlateSize: CGSize = .zero
    private var transcriptPanelSize: CGSize = .zero
    private var currentContent: DictationHUDContent?
    private var pendingContent: DictationHUDContent?
    private var pendingHintLines: [String]?
    private var pendingContentWork: DispatchWorkItem?
    private var hintLines: [String] = []
    private var nextHintLines: [String] = []

    private var capsuleScreenFrame = CGRect(origin: .zero, size: DICTATION_HUD_BASE_SIZE)
    private var showVisibleFrame: CGRect?
    private var showDisplayID: UInt32?
    private var hintOpensBelow = false

    private var hoverEnterWork: DispatchWorkItem?
    private var hoverExitWork: DispatchWorkItem?
    private var hoverProgress: CGFloat = 0
    private var hoverAnimation: ScalarAnimation?
    private var isPointerInside = false
    private var countedDragHintForCurrentHover = false

    private var revealProgress: CGFloat = 1
    private var revealAnimation: ScalarAnimation?
    private var animationToken: UInt64 = 0

    private let displayLinkStorage = DictationHUDDisplayLinkStorage()
    private lazy var displayLinkProxy: DictationHUDDisplayLinkProxy = {
        let proxy = DictationHUDDisplayLinkProxy()
        proxy.owner = self
        return proxy
    }()
    private var displayLink: CADisplayLink? {
        get { displayLinkStorage.value }
        set { displayLinkStorage.value = newValue }
    }
    private var lastMotionAt: TimeInterval?
    private var phase: CGFloat = 0
    private var loggedKeyRegression = false

    private var mouseDownPoint: CGPoint?
    private var dragStartOrigin: CGPoint?
    private var dragStarted = false

    private var screenObserver: DictationHUDNotificationObserver?

    private var prewarmed = false
    /// Замер первого показа: от «попросили показать» до «первый кадр с пикселями
    /// лёг в буфер окна». Пишется один раз за процесс — это ответ на «она как
    /// будто тормозит в самом начале», и он должен быть виден в логе, а не
    /// в чьей-то памяти.
    private var firstShowRequestedAt: TimeInterval?
    private var firstShowOrderedAt: TimeInterval?
    private(set) var firstShowMetric: DictationHUDFirstShowMetric?
    /// Единственный потребитель — технический замер (`--measure-hud-first-show`):
    /// одного числа «до первого кадра» мало, заминка видна в разрывах между
    /// кадрами раскрытия. В продукте всегда `nil`, цена — одна проверка на тик.
    var frameObserver: ((_ gap: TimeInterval, _ work: TimeInterval) -> Void)?

    init(settings: DictationSettings = .shared,
         reduceMotion: @escaping () -> Bool = { dictationHUDReduceMotionEnabled() }) {
        self.settings = settings
        self.reduceMotionEnabled = reduceMotion
        super.init()
        screenObserver = DictationHUDNotificationObserver(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        })
    }

    func updateHintLines(_ lines: [String]) {
        nextHintLines = Array(lines.prefix(2))
    }

    /// Собрать всё дорогое заранее — со старта приложения, а не с первого
    /// нажатия. Модель ASR греется фоном ровно по этой причине; плашка платила
    /// свою цену на глазах у владельца.
    ///
    /// Что здесь греется и почему это дорого в первый раз:
    /// панель и её слои (создание окна с буфером — единственное окно
    /// у приложения из строки меню, и вместе с ним поднимается половина
    /// AppKit), конвейер Metal, текстура на РЕАЛЬНОМ масштабе экрана,
    /// первый проход `draw` со всеми ленивыми кешами Core Graphics, шрифты
    /// подсказки, механика CADisplayLink.
    ///
    /// Панель при этом НЕ показывается: `orderFront` здесь нет, кадр рисуется
    /// в отдельный битмап тем же приёмом, что раскадровка `--export-hud-animation`.
    /// Мигнувшая при входе в систему плашка была бы хуже заминки, которую
    /// это чинит.
    func prewarm() {
        guard !prewarmed else { return }
        prewarmed = true
        let startedAt = ProcessInfo.processInfo.systemUptime
        _ = ensurePanel()
        warmFirstFrame()
        hint?.warmTextMetrics()
        warmDisplayLink()
        // В лог, а не в чью-то память: если прогрев вдруг подорожает, это
        // должно быть видно, а не выясняться жалобой на подвисший старт.
        log(String(format: "HUD prewarm: %.0f ms",
                   (ProcessInfo.processInfo.systemUptime - startedAt) * 1000))
    }

    /// Первый кадр рисуется в битмап: он поднимает конвейер Metal, текстуру
    /// нужного размера и весь путь `drawCapsule`. Масштаб — с главного экрана,
    /// иначе живой показ переаллоцирует текстуру ровно в тот момент, ради
    /// которого всё затевалось.
    private func warmFirstFrame() {
        guard let capsule else { return }
        let size = capsule.bounds.size
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard size.width > 0, size.height > 0 else { return }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int((size.width * scale).rounded()),
                                            pixelsHigh: Int((size.height * scale).rounded()),
                                            bitsPerSample: 8,
                                            samplesPerPixel: 4,
                                            hasAlpha: true,
                                            isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0,
                                            bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        bitmap.size = size
        capsule.palette = settings.dictationHUDWavePalette
        capsule.content = dictationHUDContent(stage: .listening(.dictation),
                                              level: 0.5,
                                              reduceMotion: false,
                                              historyHint: "")
        capsule.level = 0.5
        // Середина раскрытия: на ней рисуется всё сразу — плита, кант, ореол
        // и лента. На нуле не рисуется ничего, на единице нет перелёта.
        capsule.revealProgress = 0.5
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        capsule.displayIgnoringOpacity(capsule.bounds, in: context)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        // Вернуть чистое состояние: первый показ обязан выглядеть как первый.
        // `content = nil` важнее прочего — иначе следующее присваивание сочтёт
        // прогретый кадр «предыдущим цветом» и перекраска на распознавании
        // поедет от него.
        capsule.content = nil
        capsule.level = 0
        capsule.revealProgress = 1
    }

    /// CADisplayLink на первом заведении договаривается с CoreAnimation про
    /// дисплей. Делаем это заранее и сразу гасим: до показа ему нечего вести.
    private func warmDisplayLink() {
        guard let container else { return }
        let link = container.displayLink(target: displayLinkProxy,
                                         selector: #selector(DictationHUDDisplayLinkProxy.fired(_:)))
        link.invalidate()
    }

    func present(_ content: DictationHUDContent) {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let panel = ensurePanel()

        if shouldHoldProcessingBeforePresenting(content) {
            pendingContent = content
            pendingHintLines = nextHintLines
            schedulePendingContent()
            return
        }
        applyHintLines(nextHintLines)
        applyContent(content)

        if !panel.isVisible {
            if firstShowMetric == nil { firstShowRequestedAt = requestedAt }
            prepareInitialFrame()
            loggedKeyRegression = false
            hoverProgress = 0
            hint?.appearanceProgress = 0
            let reduceMotion = reduceMotionEnabled()
            revealAnimation = nil
            revealProgress = reduceMotion ? 1 : 0
            capsule?.revealProgress = revealProgress
            layoutPanel(display: true)
            displayNow()
            panel.orderFrontRegardless()
            firstShowOrderedAt = ProcessInfo.processInfo.systemUptime
            // На выключенной анимации пилюля уже нарисована целиком — замер
            // закрывается здесь же, а не на первом тике, которого не будет.
            noteFirstPaint()
            checkFocusInvariant()
            DispatchQueue.main.async { [weak self] in self?.checkFocusInvariant() }
            if !reduceMotion {
                startRevealAnimation(to: 1,
                                     duration: DICTATION_HUD_REVEAL_IN_DURATION) { [weak self] in
                    self?.reconcilePointerAfterReveal()
                }
            }
        } else {
            if revealProgress < 1 {
                startRevealAnimation(to: 1,
                                     duration: DICTATION_HUD_REVEAL_IN_DURATION) { [weak self] in
                    self?.reconcilePointerAfterReveal()
                }
            }
            startMotionIfNeeded()
            displayNow()
        }
    }

    func setTranscriptCopiedHandler(_ handler: @escaping () -> Void) {
        transcriptCopiedHandler = handler
    }

    func dismiss() {
        cancelHoverWork()
        pendingContentWork?.cancel()
        pendingContentWork = nil
        pendingContent = nil
        pendingHintLines = nil
        hoverAnimation = nil
        hoverProgress = 0
        hint?.appearanceProgress = 0
        layoutPanel(display: false)

        guard let panel, panel.isVisible else {
            resetAfterDismiss()
            return
        }
        animationToken &+= 1
        let token = animationToken
        if reduceMotionEnabled() {
            revealAnimation = nil
            revealProgress = 0
            capsule?.revealProgress = 0
            panel.orderOut(nil)
            resetAfterDismiss()
            return
        }
        // Уход - тоже переход, а не исчезновение: плашка собирается в точку и
        // только потом гаснет. Слова владельца: «она потом может сама плашка
        // собраться в маленький кружочек и исчезнуть вообще».
        beginGlassVanish()
        startRevealAnimation(to: 0,
                             duration: DICTATION_HUD_REVEAL_OUT_DURATION) { [weak self] in
            guard let self, self.animationToken == token else { return }
            self.panel?.orderOut(nil)
            self.resetAfterDismiss()
        }
        startMotionIfNeeded()
    }

    /// Заводит схлопывание плашки в точку.
    private func beginGlassVanish() {
        guard !reduceMotionEnabled() else { return }
        if #available(macOS 26.0, *) {
            guard let stack = glassStack as? DictationHUDGlassStack else { return }
            let target = dictationHUDGlassShape(form: .vanishing, in: stack.bounds.size)
            guard glassTo != target else { return }
            let current = (glassFrom.flatMap { from in
                glassTo.map { dictationHUDGlassShape(from: from, to: $0,
                                                     progress: 1 - pow(1 - glassProgress, 3)) }
            }) ?? glassTo ?? target
            glassFrom = current
            glassTo = target
            glassProgress = 0
        }
    }

    // MARK: - Hover

    func hudMouseEntered() {
        isPointerInside = true
        hoverExitWork?.cancel()
        hoverExitWork = nil
        scheduleHintOpenIfReady()
    }

    private func scheduleHintOpenIfReady(additionalDelay: TimeInterval = 0) {
        guard isPointerInside,
              panel?.isVisible == true,
              revealProgress >= 0.999,
              !dragStarted else { return }
        hoverEnterWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.openHint() }
        }
        hoverEnterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()
                                      + DICTATION_HUD_HOVER_ENTER_DELAY
                                      + additionalDelay,
                                      execute: work)
    }

    func hudMouseExited() {
        isPointerInside = false
        hoverEnterWork?.cancel()
        hoverEnterWork = nil
        hoverExitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.closeHint() }
        }
        hoverExitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DICTATION_HUD_HOVER_EXIT_DELAY,
                                      execute: work)
    }

    private func openHint() {
        hoverEnterWork = nil
        guard isPointerInside,
              panel?.isVisible == true,
              revealProgress >= 0.999,
              !dragStarted,
              !hintLines.isEmpty else { return }
        if !countedDragHintForCurrentHover {
            countedDragHintForCurrentHover = true
            if dictationHUDShowsDragHint(shownCount: settings.dictationHUDHintShownCount) {
                settings.incrementDictationHUDHintShownCount()
            } else {
                hintLines.removeAll { $0 == "мышью — переставить" }
            }
        }
        hint?.lines = hintLines
        updateHintDirection()
        startHoverAnimation(to: 1, duration: DICTATION_HUD_HOVER_ENTER_DURATION)
    }

    private func closeHint() {
        hoverExitWork = nil
        countedDragHintForCurrentHover = false
        startHoverAnimation(to: 0, duration: DICTATION_HUD_HOVER_EXIT_DURATION)
    }

    private func cancelHoverWork() {
        hoverEnterWork?.cancel()
        hoverExitWork?.cancel()
        hoverEnterWork = nil
        hoverExitWork = nil
    }

    // MARK: - Drag

    /// Управление плашкой: язык, история, настройки.
    ///
    /// Меню собирается на каждый щелчок заново, а не хранится: галочка языка
    /// обязана показывать то, что стоит СЕЙЧАС, а язык меняется и из настроек.
    func hudRightMouseDown(with event: NSEvent, in view: NSView) {
        guard let controls else { return }
        NSMenu.popUpContextMenu(makeDictationHUDMenu(controls: controls), with: event, for: view)
    }

    func hudMouseDown(at screenPoint: CGPoint) {
        checkFocusInvariant()
        mouseDownPoint = screenPoint
        dragStartOrigin = capsuleScreenFrame.origin
        dragStarted = false
    }

    func hudMouseDragged(to screenPoint: CGPoint) {
        guard let mouseDownPoint, let dragStartOrigin else { return }
        let delta = CGPoint(x: screenPoint.x - mouseDownPoint.x,
                            y: screenPoint.y - mouseDownPoint.y)
        if !dragStarted {
            guard hypot(delta.x, delta.y) >= DICTATION_HUD_DRAG_THRESHOLD else { return }
            dragStarted = true
            cancelHoverWork()
            startHoverAnimation(to: 0, duration: DICTATION_HUD_HOVER_EXIT_DURATION)
        }

        let proposed = CGRect(origin: CGPoint(x: dragStartOrigin.x + delta.x,
                                              y: dragStartOrigin.y + delta.y),
                              size: DICTATION_HUD_BASE_SIZE)
        let screen = screenFor(point: screenPoint)
        capsuleScreenFrame = dictationHUDSnappedFrame(proposed, in: screen.visibleFrame)
        showVisibleFrame = screen.visibleFrame
        showDisplayID = displayID(for: screen)
        updateHintDirection()
        layoutPanel(display: true)
    }

    func hudMouseUp(at screenPoint: CGPoint) {
        let didDrag = dragStarted
        mouseDownPoint = nil
        dragStartOrigin = nil
        dragStarted = false
        guard didDrag else { return }
        let screen = screenFor(point: CGPoint(x: capsuleScreenFrame.midX,
                                              y: capsuleScreenFrame.midY))
        capsuleScreenFrame = dictationHUDClampedFrame(capsuleScreenFrame, in: screen.visibleFrame)
        showVisibleFrame = screen.visibleFrame
        showDisplayID = displayID(for: screen)
        persistPosition(in: screen)
        layoutPanel(display: true)
        isPointerInside = capsuleScreenFrame.contains(screenPoint)
        if !isPointerInside { countedDragHintForCurrentHover = false }
        scheduleHintOpenIfReady(additionalDelay: DICTATION_HUD_HOVER_EXIT_DURATION)
    }

    // MARK: - Motion

    private func startRevealAnimation(to: CGFloat,
                                      duration: TimeInterval,
                                      completion: (() -> Void)? = nil) {
        revealAnimation = scalarAnimation(from: revealProgress,
                                          to: to,
                                          duration: duration,
                                          completion: completion)
        startMotionIfNeeded()
    }

    private func startHoverAnimation(to: CGFloat, duration: TimeInterval) {
        if reduceMotionEnabled() {
            hoverAnimation = nil
            hoverProgress = to
            hint?.appearanceProgress = to
            layoutPanel(display: true)
            displayNow()
            return
        }
        hoverAnimation = scalarAnimation(from: hoverProgress,
                                         to: to,
                                         duration: duration,
                                         completion: nil)
        startMotionIfNeeded()
    }

    private func scalarAnimation(from: CGFloat,
                                 to: CGFloat,
                                 duration: TimeInterval,
                                 completion: (() -> Void)?) -> ScalarAnimation {
        let from = max(0, min(1, from))
        let to = max(0, min(1, to))
        return ScalarAnimation(from: from,
                               to: to,
                               startedAt: ProcessInfo.processInfo.systemUptime,
                               duration: dictationHUDAnimationDuration(base: duration,
                                                                      from: from,
                                                                      to: to),
                               completion: completion)
    }

    private func startMotionIfNeeded() {
        // Переход плашки поднимает линк наравне с волной: на терминальной
        // стадии скорость фазы ноль, и по одному этому условию линк не
        // стартовал бы вовсе - а переход как раз туда и ведёт.
        let needed = dictationHUDNeedsDisplayLink(stage: currentContent?.stage,
                                                  revealAnimating: revealAnimation != nil,
                                                  hoverAnimating: hoverAnimation != nil,
                                                  reduceMotion: reduceMotionEnabled())
            || glassTransitionInFlight
        guard displayLink == nil, needed, let container else { return }
        lastMotionAt = ProcessInfo.processInfo.systemUptime
        let link = container.displayLink(target: displayLinkProxy,
                                         selector: #selector(DictationHUDDisplayLinkProxy.fired(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60,
                                                        maximum: 120,
                                                        preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopMotion() {
        displayLink?.invalidate()
        displayLink = nil
        lastMotionAt = nil
    }

    fileprivate func displayLinkFired(_ link: CADisplayLink) {
        guard let panel else {
            stopMotion()
            return
        }
        checkFocusInvariant()

        let now = ProcessInfo.processInfo.systemUptime
        let previous = lastMotionAt ?? now
        let gap = now - previous
        let dt = max(0.001, min(0.05, gap))
        lastMotionAt = now
        advanceAnimations(at: now)

        if let content = currentContent {
            let speed = dictationHUDPhaseSpeed(stage: content.stage, level: content.level)
            phase += CGFloat(dt * speed)
            capsule?.phase = phase
        }
        advanceGlass(dt: dt)
        advanceTranscript(dt: dt)
        advanceWorkingWave()
        layoutPanel(display: false)
        displayNow()
        noteFirstPaint()
        frameObserver?(gap, ProcessInfo.processInfo.systemUptime - now)

        // Переход плашки - тоже движение. Прежде на терминальных стадиях
        // скорость фазы ноль, линк останавливался, и аниматор перехода просто
        // не тикал: картинка замирала, а форма потом менялась скачком.
        let hasMotion = dictationHUDNeedsDisplayLink(
            stage: currentContent?.stage,
            revealAnimating: revealAnimation != nil,
            hoverAnimating: hoverAnimation != nil,
            reduceMotion: reduceMotionEnabled()
        ) || glassTransitionInFlight || (transcript != nil && transcriptProgress != transcriptTarget)
            // Кольцо отсчета - тоже движение: без него линк останавливался, и
            // кольцо стояло на месте, пока панель молча доживала свои секунды.
            || (transcript != nil && transcriptLifetime > 0 && transcriptAge < transcriptLifetime)
        if !panel.isVisible || !hasMotion { stopMotion() }
    }

    private func advanceAnimations(at now: TimeInterval) {
        if let animation = revealAnimation {
            let progress = min(1, max(0, (now - animation.startedAt) / animation.duration))
            revealProgress = animation.from
                + ((animation.to - animation.from) * CGFloat(progress))
            capsule?.revealProgress = revealProgress
            if progress >= 1 {
                revealAnimation = nil
                animation.completion?()
            }
        }
        if let animation = hoverAnimation {
            let progress = min(1, max(0, (now - animation.startedAt) / animation.duration))
            hoverProgress = animation.from
                + ((animation.to - animation.from) * CGFloat(progress))
            hint?.appearanceProgress = hoverProgress
            if progress >= 1 { hoverAnimation = nil }
        }
    }

    /// Засчитать первый кадр, на котором в буфере окна ДЕЙСТВИТЕЛЬНО есть
    /// пилюля. При `revealProgress == 0` рисовать нечего (`drawCapsule`
    /// выходит сразу), и считать такой кадр показом — врать себе в замере.
    ///
    /// Дальше окна замер не идёт: композитор показывает буфер уже за пределами
    /// процесса, и изнутри этот кусок не виден.
    private func noteFirstPaint() {
        guard firstShowMetric == nil,
              let requestedAt = firstShowRequestedAt,
              revealProgress > 0.001 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let metric = DictationHUDFirstShowMetric(prewarmed: prewarmed,
                                                 orderedSeconds: (firstShowOrderedAt ?? now) - requestedAt,
                                                 paintedSeconds: now - requestedAt)
        firstShowMetric = metric
        firstShowRequestedAt = nil
        log(metric.logLine)
    }

    private func checkFocusInvariant() {
        guard panel?.isKeyWindow == true, !loggedKeyRegression else { return }
        loggedKeyRegression = true
        log("HUD panel became key")
    }

    private func reconcilePointerAfterReveal() {
        scheduleHintOpenIfReady()
    }

    // MARK: - Panel layout

    private func ensurePanel() -> DictationHUDPanel {
        if let panel { return panel }
        let panel = DictationHUDPanel(contentRect: CGRect(origin: .zero,
                                                          size: DICTATION_HUD_BASE_SIZE),
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered,
                                       defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let container = DictationHUDContainerView(frame: CGRect(origin: .zero,
                                                                size: DICTATION_HUD_BASE_SIZE))
        container.delegate = self
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        let capsule = DictationHUDCapsuleView(frame: CGRect(origin: .zero,
                                                            size: DICTATION_HUD_BASE_SIZE))
        let hint = DictationHUDHintView(frame: .zero)
        container.addSubview(hint)

        if #available(macOS 26.0, *) {
            // Стеклянная плашка: тело и спутник в контейнере Liquid Glass,
            // внутри тела - звуковая волна. Капсула при этом не добавляется
            // в дерево вовсе: два объекта в одном кадре читались бы стеклом
            // поверх старого чипа, и это уже ловилось кадром.
            let stack = DictationHUDGlassStack(frame: CGRect(origin: .zero,
                                                             size: DICTATION_HUD_BASE_SIZE))
            let bars = DictationHUDWaveBarsView(frame: .zero)
            stack.bodyContent = bars
            container.addSubview(stack)
            self.glassStack = stack
            self.waveBars = bars
        } else {
            container.addSubview(capsule)
        }
        panel.contentView = container

        self.panel = panel
        self.container = container
        self.capsule = capsule
        self.hint = hint
        return panel
    }

    /// Плашка разворачивается в панель с текстом - или сворачивается обратно.
    ///
    /// Слова владельца: «эта плашка трансформируется в зону, где текст
    /// напечатан, и я его могу копировать». Здесь только размер окна и
    /// содержимое; само движение делает стекло, которому меняют форму, - то же
    /// самое, которым плашка собирается в кружок.
    private func applyTranscript(_ content: DictationHUDContent) {
        guard let text = content.transcript, !text.isEmpty else {
            // Панель не исчезает, а СХЛОПЫВАЕТСЯ обратно в плашку: уход тем же
            // движением, что и приход. Вид снимается в `advanceTranscript`,
            // когда движение доехало до нуля.
            if transcript != nil { transcriptTarget = 0 }
            return
        }
        let view: DictationHUDTranscriptView
        if let existing = transcript {
            view = existing
        } else {
            view = DictationHUDTranscriptView(frame: .zero)
            view.onCopied = { [weak self] in self?.transcriptCopiedHandler?() }
            container?.addSubview(view)
            transcript = view
            transcriptAge = 0
            transcriptLifetime = dictationHUDDismissDelay(for: content.stage) ?? 0
            view.lifeRemaining = 1
        }
        view.text = text

        let plate = dictationHUDCollapsedSize(settings.dictationHUDSize)
        let screenWidth = screenFor(point: CGPoint(x: capsuleScreenFrame.midX,
                                                   y: capsuleScreenFrame.midY)).visibleFrame.width
        let probe = dictationHUDTranscriptSize(lineCount: 1, plateSize: plate, screenWidth: screenWidth)
        let lines = dictationHUDTranscriptLineCount(text: text, width: probe.width)
        transcriptPlateSize = plate
        transcriptPanelSize = dictationHUDTranscriptSize(lineCount: lines,
                                                         plateSize: plate,
                                                         screenWidth: screenWidth)
        transcriptTarget = 1
        if reduceMotionEnabled() {
            transcriptProgress = 1
            applyTranscriptProgress()
        }
    }

    /// Разложить текущее раскрытие по окну и виду. Одна точка на весь морф:
    /// размер окна, размер вида и проявление содержимого обязаны считаться от
    /// одного числа, иначе они разъедутся.
    private func applyTranscriptProgress() {
        guard transcriptPanelSize != .zero else { return }
        // Сильный ease-out: движение начинается сразу и мягко оседает.
        let eased = 1 - pow(1 - transcriptProgress, 3)
        let from = transcriptPlateSize
        let to = transcriptPanelSize
        capsuleScreenFrame.size = CGSize(
            width: (from.width + (to.width - from.width) * eased).rounded(),
            height: (from.height + (to.height - from.height) * eased).rounded()
        )
        transcript?.revealProgress = eased
        // Волна уступает место тексту: два содержимых в одном стекле спорят,
        // и читаются оба хуже, чем каждое поодиночке. Уходит она раньше, чем
        // приходит текст, - иначе они наложатся на середине движения.
        waveBars?.alphaValue = max(0, 1 - eased * 2.2)
    }

    /// Довести раскрытие до цели. Идёт в общем такте движения, как и морф
    /// стекла.
    private func advanceTranscript(dt: TimeInterval) {
        guard transcript != nil else { return }
        if transcriptLifetime > 0, transcriptTarget > 0 {
            transcriptAge += dt
            transcript?.lifeRemaining = CGFloat(max(0, 1 - transcriptAge / transcriptLifetime))
        }
        let step = CGFloat(dt / DICTATION_HUD_TRANSCRIPT_MORPH_SECONDS)
        let delta = transcriptTarget - transcriptProgress
        if abs(delta) <= step {
            transcriptProgress = transcriptTarget
        } else {
            transcriptProgress += delta > 0 ? step : -step
        }
        applyTranscriptProgress()
        guard transcriptProgress <= 0.001, transcriptTarget == 0 else { return }
        transcript?.removeFromSuperview()
        transcript = nil
        transcriptPanelSize = .zero
        waveBars?.alphaValue = 1
        capsuleScreenFrame.size = dictationHUDCollapsedSize(settings.dictationHUDSize)
    }

    private func applyContent(_ content: DictationHUDContent) {
        pendingContentWork?.cancel()
        pendingContentWork = nil
        pendingContent = nil
        pendingHintLines = nil
        let previousStage = currentContent?.stage
        currentContent = content
        panel?.contentView?.setAccessibilityLabel(content.accessibilityLabel)
        // Палитра ленты перечитывается на каждом показе: выбор в настройках
        // вступает в силу со следующей плашки, а не посреди идущей записи.
        capsule?.palette = settings.dictationHUDWavePalette
        capsule?.content = content
        capsule?.level = content.level
        applyTranscript(content)
        applyGlass(content, stageChanged: previousStage != content.stage)
        if content.stage == .recognizing, previousStage != .recognizing {
            processingBeganAt = ProcessInfo.processInfo.systemUptime
        } else if content.stage != .recognizing {
            processingBeganAt = nil
        }
        if reduceMotionEnabled() {
            stopMotion()
            revealAnimation = nil
            revealProgress = 1
            capsule?.revealProgress = 1
        } else {
            startMotionIfNeeded()
        }
    }



    /// Двигает переходы плашки на каждом кадре.
    ///
    /// Переход - это не подмена картинки: волна УКЛАДЫВАЕТСЯ в линию, вспышка
    /// разгорается и гаснет, стекло едет в новую форму. Владелец назвал это
    /// прямо: «нет красивой анимации перехода после того, как я нажал
    /// завершить». Мгновенная смена и была её отсутствием.
    private func advanceGlass(dt: TimeInterval) {
        guard #available(macOS 26.0, *), let bars = waveBars else { return }

        // Волна укладывается быстрее, чем поднимается: голос обязан
        // подхватываться сразу, а тишина может улечься мягко.
        let rate: CGFloat = waveCollapseTarget > waveCollapse
            ? DICTATION_HUD_COLLAPSE_FALL_RATE
            : DICTATION_HUD_COLLAPSE_RISE_RATE
        let delta = waveCollapseTarget - waveCollapse
        let stepSize = rate * CGFloat(dt)
        waveCollapse += abs(delta) <= stepSize ? delta : (delta > 0 ? stepSize : -stepSize)
        bars.collapse = waveCollapse

        if glassProgress < 1, let from = glassFrom, let to = glassTo,
           let stack = glassStack as? DictationHUDGlassStack {
            glassProgress = min(1, glassProgress + CGFloat(dt / DICTATION_HUD_GLASS_MORPH_SECONDS))
            // Сильный ease-out: движение начинается сразу и мягко оседает.
            // ease-in здесь читался бы задержкой ровно в тот момент, когда
            // владелец смотрит внимательнее всего.
            let eased = 1 - pow(1 - glassProgress, 3)
            stack.apply(dictationHUDGlassShape(from: from, to: to, progress: eased),
                        animated: false)
            if glassProgress >= 1 { glassFrom = nil }
        }

        guard let started = flashAge, let stack = glassStack as? DictationHUDGlassStack else { return }
        let age = started + dt
        flashAge = age
        let t = CGFloat(age / DICTATION_HUD_FLASH_SECONDS)
        guard t < 1 else {
            flashAge = nil
            stack.flash(flashColor, strength: 0)
            return
        }
        // Разгорается за первую пятую, гаснет за остальное: так это читается
        // ударом, а не пульсацией.
        let bloom: CGFloat = t < 0.2 ? (t / 0.2) : pow(1 - ((t - 0.2) / 0.8), 1.6)
        stack.flash(flashColor, strength: flashPeak * bloom)
    }

    /// Ведёт стеклянную плашку: форму, цвет волны, сборку в линию и вспышку.
    @available(macOS 26.0, *)
    private func applyGlassStack(_ content: DictationHUDContent, stageChanged: Bool) {
        guard let stack = glassStack as? DictationHUDGlassStack,
              let bars = waveBars else { return }
        // Режим лежит в самой стадии: `listening(purpose)`. У остальных стадий
        // его нет, и брать его живым опросом контроллера нельзя - к моменту
        // показа исхода `recordingPurpose` уже обнулён. Поэтому режим
        // запоминается на записи и держится до конца этой плашки.
        if case .listening(let purpose) = content.stage { lastPurpose = purpose }
        let tone = dictationHUDWaveTone(stage: content.stage, purpose: lastPurpose)
        let color = dictationHUDWaveColor(tone)

        // Новая запись начинает волну с чистого листа: чужая фраза в начале
        // следующей читалась бы как своя.
        if stageChanged, case .listening = content.stage { levelTrail.reset() }
        // Пока идёт запись, каждый пришедший уровень уезжает в хвост волны.
        // На остальных стадиях хвост замирает: показывать нечего, а бегущая
        // волна после конца записи врала бы, что владелец ещё говорит.
        if case .listening = content.stage { levelTrail.append(content.level) }

        bars.tint = color
        // Золото держит собственный тон в ядре, остальные тона - как было.
        bars.coreWhiteScale = tone == .prompt ? DICTATION_HUD_GOLD_CORE_WHITE : 1
        bars.reduceMotion = reduceMotionEnabled()
        // На работе волна идёт СВОИМ ходом: голоса уже нет, а показать, что
        // работа не встала, обязано что-то. Кадры для неё считает
        // `dictationHUDWorkingLevels`, а не микрофон.
        switch content.stage {
        case .recognizing, .buildingPrompt:
            bars.heights = dictationHUDWaveBarHeights(
                levels: dictationHUDWorkingLevels(phase: phase, count: bars.heights.count == 0
                                                  ? DICTATION_HUD_BAR_COUNT : bars.heights.count),
                count: bars.heights.count == 0 ? DICTATION_HUD_BAR_COUNT : bars.heights.count)
        default:
            bars.heights = levelTrail.heights
        }
        // Свечение по контуру - метка режима, а не украшение: пока работает
        // золотая диктовка, стекло обведено золотом семьи. У обычной диктовки
        // контур не горит вовсе, иначе метка перестаёт что-либо значить.
        if let stack = glassStack as? DictationHUDGlassStack {
            let glowing = tone == .prompt && dictationHUDWaveGlyph(
                for: content.stage, purpose: lastPurpose) == .wave
            stack.modeGlow(color, strength: glowing ? DICTATION_HUD_MODE_GLOW_STRENGTH : 0)
        }
        // Успех показывает знак, а не огрызок волны в кружке.
        bars.glyph = dictationHUDWaveGlyph(for: content.stage, purpose: lastPurpose)
        // Покой тише отказа: тишина - это не отказ, и гореть одинаково они
        // не имеют права.
        bars.lineIntensity = tone == .failure ? 1.0 : 0.55
        // Цель, а не значение: до неё едет пружина в `advanceGlass`.
        waveCollapseTarget = max(dictationHUDWaveCollapse(stage: content.stage),
                                 dictationHUDSilenceCollapse(levels: levelTrail.levels))
        if reduceMotionEnabled() {
            waveCollapse = waveCollapseTarget
            bars.collapse = waveCollapse
        }
        // Волна уступает место тексту: два содержимых в одном стекле спорят,
        // и читаются оба хуже, чем каждое поодиночке.
        // Волна не прячется скачком: её гасит `applyTranscriptProgress` по
        // ходу раскрытия. Скачок посреди движения виден как обрыв.
        bars.needsDisplay = true

        // Вспышка заводится один раз на смену стадии, а не держится постоянно.
        let peak = dictationHUDWaveFlashStrength(stage: content.stage)
        if stageChanged, peak > 0 {
            flashColor = color
            flashPeak = peak
            flashAge = 0
            if reduceMotionEnabled() {
                stack.flash(color, strength: peak * 0.6)
                flashAge = nil
            }
        } else if peak == 0, flashAge == nil {
            stack.flash(color, strength: 0)
        }
        let size = stack.bounds.size
        // Панель с текстом старше формы стадии: пока владелец не забрал то,
        // что не доехало, плашка стоит развёрнутой, а не собирается в кружок.
        let form = content.transcript?.isEmpty == false
            ? DictationHUDGlassForm.transcript
            : dictationHUDGlassForm(for: content.stage)
        let target = dictationHUDGlassShape(form: form, in: size)
        if reduceMotionEnabled() {
            glassFrom = nil
            glassTo = target
            glassProgress = 1
            stack.apply(target, animated: false)
        } else if glassTo != target {
            // Пойдём ОТ ТЕКУЩЕЙ формы, даже если прошлый переход не доехал:
            // иначе новый переход дёрнет плашку назад к началу прошлого.
            let current = (glassFrom.flatMap { from in
                glassTo.map { dictationHUDGlassShape(from: from, to: $0,
                                                     progress: 1 - pow(1 - glassProgress, 3)) }
            }) ?? glassTo ?? target
            glassFrom = current
            glassTo = target
            glassProgress = 0
        }
    }

    private func applyGlass(_ content: DictationHUDContent, stageChanged: Bool) {
        if #available(macOS 26.0, *) {
            applyGlassStack(content, stageChanged: stageChanged)
        }
    }

    /// Гонит собственную волну работы, пока идёт распознавание или сборка.
    private func advanceWorkingWave() {
        guard #available(macOS 26.0, *), let bars = waveBars,
              let stage = currentContent?.stage else { return }
        switch stage {
        case .recognizing, .buildingPrompt:
            let count = max(8, bars.heights.count)
            bars.heights = dictationHUDWaveBarHeights(
                levels: dictationHUDWorkingLevels(phase: phase, count: count), count: count)
        default:
            break
        }
    }

    /// Идёт ли сейчас переход плашки: форма, укладка волны или вспышка.
    private var glassTransitionInFlight: Bool {
        if reduceMotionEnabled() { return false }
        if glassProgress < 1 { return true }
        if abs(waveCollapse - waveCollapseTarget) > 0.004 { return true }
        return flashAge != nil
    }

    private var processingBeganAt: TimeInterval?

    private func shouldHoldProcessingBeforePresenting(_ content: DictationHUDContent) -> Bool {
        guard currentContent?.stage == .recognizing,
              content.stage != .recognizing,
              let processingBeganAt else { return false }
        return ProcessInfo.processInfo.systemUptime - processingBeganAt
            < DICTATION_HUD_MINIMUM_PROCESSING_VISIBILITY
    }

    private func schedulePendingContent() {
        pendingContentWork?.cancel()
        guard let processingBeganAt else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - processingBeganAt
        let delay = max(0, DICTATION_HUD_MINIMUM_PROCESSING_VISIBILITY - elapsed)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let content = self.pendingContent else { return }
                self.applyHintLines(self.pendingHintLines ?? self.nextHintLines)
                self.applyContent(content)
                self.displayNow()
            }
        }
        pendingContentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func applyHintLines(_ lines: [String]) {
        hintLines = Array(lines.prefix(2))
        hint?.lines = hintLines
        updateHintDirection()
        if hoverProgress > 0 { layoutPanel(display: true) }
    }

    private func prepareInitialFrame() {
        let screen = restoredScreen()
        showVisibleFrame = screen.visibleFrame
        showDisplayID = displayID(for: screen)
        if let fraction = settings.dictationHUDPositionFraction {
            let restored = dictationHUDRestoredFrame(size: DICTATION_HUD_BASE_SIZE,
                                                     fraction: fraction,
                                                     in: screen.visibleFrame)
            capsuleScreenFrame = dictationHUDClampedFrame(restored, in: screen.visibleFrame)
            let corrected = dictationHUDPositionFraction(frame: capsuleScreenFrame,
                                                         in: screen.visibleFrame)
            if corrected != fraction { persistPosition(in: screen) }
        } else {
            capsuleScreenFrame = dictationHUDFrame(size: DICTATION_HUD_BASE_SIZE,
                                                   in: screen.visibleFrame)
        }
        updateHintDirection()
    }

    private func updateHintDirection() {
        guard let visible = showVisibleFrame else { return }
        let hintHeight = hint?.fittingHintSize.height ?? 0
        hintOpensBelow = capsuleScreenFrame.maxY + DICTATION_HUD_HINT_GAP + hintHeight
            > visible.maxY - 8
    }

    /// Что определяет геометрию панели. Раскрытия здесь нет НАМЕРЕННО: пилюля
    /// растёт внутри своего слоя, а панель всё это время стоит на месте и
    /// того же размера. Поэтому 0,32 с раскрытия — это по кадру дисплея на
    /// перекладку окна (19 на 60 Гц, 38 на 120), и каждая ставила `setFrame`
    /// тем же самым прямоугольником. Замер: без этой проверки худший кадр
    /// раскрытия стоил 3,1 мс вместо 1,1 и пропуски кадров были видны
    /// в разрывах (до 23,9 мс при кадре дисплея 16,7).
    private struct PanelLayout: Equatable {
        let capsuleFrame: CGRect
        let hoverProgress: CGFloat
        let hintSize: CGSize
        let hintLineCount: Int
        let opensBelow: Bool
    }

    private var appliedLayout: PanelLayout?

    private func layoutPanel(display: Bool) {
        guard let panel, let container, let capsule, let hint else { return }
        hint.lines = hintLines
        let hintSize = hint.fittingHintSize
        let request = PanelLayout(capsuleFrame: capsuleScreenFrame,
                                  hoverProgress: hoverProgress,
                                  hintSize: hintSize,
                                  hintLineCount: hintLines.count,
                                  opensBelow: hintOpensBelow)
        // Ничего не поменялось — значит и перекладывать нечего. Отрисовку это
        // не отменяет: её делает `displayNow`, и делает по грязным слоям.
        if request == appliedLayout, !display { return }
        appliedLayout = request
        let hover = dictationHUDHoverLayers(progress: hoverProgress)
        let collapsedSize = capsuleScreenFrame.size
        let expandedWidth = max(collapsedSize.width, hintSize.width)
        let extraHeight = hintLines.isEmpty ? 0 : DICTATION_HUD_HINT_GAP + hintSize.height
        let width = collapsedSize.width
            + (expandedWidth - collapsedSize.width) * hover.windowProgress
        let height = collapsedSize.height + extraHeight * hover.windowProgress
        let originX = capsuleScreenFrame.midX - width / 2
        let originY = hintOpensBelow
            ? capsuleScreenFrame.maxY - height
            : capsuleScreenFrame.minY
        let frame = CGRect(x: originX, y: originY, width: width, height: height)
        panel.setFrame(frame, display: display)
        container.frame = CGRect(origin: .zero, size: frame.size)

        let capsuleY = hintOpensBelow ? height - collapsedSize.height : 0
        capsule.frame = CGRect(x: (width - collapsedSize.width) / 2,
                               y: capsuleY,
                               width: collapsedSize.width,
                               height: collapsedSize.height)
        // Панель расшифровки занимает то же место, что и плашка: она И ЕСТЬ
        // плашка, только раскрытая. Кладём её здесь, а не при создании, -
        // размер меняется каждый кадр, пока идёт раскрытие.
        transcript?.frame = capsule.frame
        // Стекло обязано вырасти вместе с панелью. Форма считается от размера
        // стеклянного вида, и пока вид оставался базового размера, панель с
        // текстом торчала мимо стекла - белая подложка сверху, стеклянный
        // огрызок под ней.
        if #available(macOS 26.0, *), let stack = glassStack as? DictationHUDGlassStack {
            let wanted = transcript == nil
                ? CGRect(origin: .zero, size: DICTATION_HUD_BASE_SIZE)
                : capsule.frame
            if stack.frame != wanted {
                stack.frame = wanted
                stack.layoutSubtreeIfNeeded()
            }
            if transcript != nil {
                let shape = dictationHUDGlassShape(form: .transcript, in: stack.bounds.size)
                glassFrom = nil
                glassTo = shape
                glassProgress = 1
                stack.apply(shape, animated: false)
            }
        }

        let slide = 6 - hover.plateOffset
        let hintY = hintOpensBelow
            ? slide
            : collapsedSize.height + DICTATION_HUD_HINT_GAP - slide
        hint.frame = CGRect(x: (width - hintSize.width) / 2,
                            y: hintY,
                            width: hintSize.width,
                            height: hintSize.height)
        hint.isHidden = hintLines.isEmpty || hoverProgress <= 0.001
    }

    private func displayNow() {
        capsule?.displayIfNeeded()
        hint?.displayIfNeeded()
        container?.displayIfNeeded()
        panel?.displayIfNeeded()
    }

    private func resetAfterDismiss() {
        stopMotion()
        revealAnimation = nil
        hoverAnimation = nil
        isPointerInside = false
        countedDragHintForCurrentHover = false
        revealProgress = 1
        hoverProgress = 0
        capsule?.revealProgress = 1
        capsule?.phase = 0
        phase = 0
        currentContent = nil
        processingBeganAt = nil
        showVisibleFrame = nil
        showDisplayID = nil
        loggedKeyRegression = false
    }

    // MARK: - Screens and persistence

    private func restoredScreen() -> NSScreen {
        let cursorScreen = screenFor(point: NSEvent.mouseLocation)
        guard let cursorID = displayID(for: cursorScreen) else { return cursorScreen }
        let resolvedID = dictationHUDRestoredDisplayID(
            savedPosition: settings.dictationHUDPositionFraction,
            savedDisplayID: settings.dictationHUDPositionDisplayID,
            availableDisplayIDs: NSScreen.screens.compactMap(displayID(for:)),
            cursorDisplayID: cursorID
        )
        return NSScreen.screens.first(where: { displayID(for: $0) == resolvedID }) ?? cursorScreen
    }

    private func screenFor(point: CGPoint) -> NSScreen {
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            return screen
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first { return screen }
        preconditionFailure("NSScreen.screens unexpectedly empty")
    }

    private func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func persistPosition(in screen: NSScreen) {
        guard let id = displayID(for: screen) else { return }
        settings.saveDictationHUDPosition(fraction: dictationHUDPositionFraction(
            frame: capsuleScreenFrame,
            in: screen.visibleFrame
        ), displayID: id)
    }

    private func screenParametersChanged() {
        guard panel?.isVisible == true else { return }
        let center = CGPoint(x: capsuleScreenFrame.midX, y: capsuleScreenFrame.midY)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) })
            ?? restoredScreen()
        let corrected = dictationHUDClampedFrame(capsuleScreenFrame, in: screen.visibleFrame)
        let changed = corrected != capsuleScreenFrame || displayID(for: screen) != showDisplayID
        capsuleScreenFrame = corrected
        showVisibleFrame = screen.visibleFrame
        showDisplayID = displayID(for: screen)
        updateHintDirection()
        layoutPanel(display: true)
        if changed { persistPosition(in: screen) }
    }

}
