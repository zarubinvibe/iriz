// Панель расшифровки: текст, который не доехал, напечатан и его можно забрать.
//
// Слова владельца: «эта плашка трансформируется в зону, где текст напечатан, и
// я его могу копировать». Ключевое здесь - ТРАНСФОРМИРУЕТСЯ. Это продолжение
// того же движения, которым плашка собирается в кружок, а не чужой диалог
// поверх. Прежде спасение жило отдельным окном истории: оно открывалось само
// по себе, и связь с только что не доехавшей надиктовкой держалась в голове.
//
// Текст лежит на СВОЕЙ непрозрачной подложке, а не прямо на стекле. Стекло
// показывает то, что за окном: буквы поверх чужого текста читаются как
// поломка, и владелец увидел ровно это - «полная херня, как будто сломан».
// Стеклянной остаётся рамка, зона с текстом - плотная.
//
// Почему текст здесь можно, хотя в капсуле его нельзя. Запрет на текстовые
// примитивы стоит воротами на DictationHUDCapsule.swift и защищает ПЛАШКУ:
// у неё нет подписей, она говорит цветом и формой. Панель - другое: её работа
// и есть показать текст.
import AppKit

/// Сколько строк займёт текст на самом деле.
///
/// Тем же шрифтом и в той же ширине, что и панель. Чистая оценка по числу
/// знаков (`dictationHUDTranscriptLineCount`) остаётся для проб без окна, но
/// решение о высоте панели принимается ЗАМЕРОМ: на кириллице оценка врёт вниз,
/// и хвост фразы уезжает за край.
func dictationHUDMeasuredTranscriptLines(text: String, width: CGFloat) -> Int {
    let usable = max(40, width
                     - DICTATION_HUD_TRANSCRIPT_PADDING * 2
                     - DICTATION_HUD_TRANSCRIPT_CARD_INSET * 2)
    let font = NSFont.systemFont(ofSize: DICTATION_HUD_TRANSCRIPT_FONT_SIZE)
    let box = (text as NSString).boundingRect(
        with: CGSize(width: usable, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font]
    )
    let line = max(1, font.ascender - font.descender + font.leading)
    return max(1, Int(ceil(box.height / line)))
}

final class DictationHUDTranscriptView: NSView {
    /// Текст, который не доехал.
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            textView.string = text
            // Живой текст растёт вниз, и смотреть надо в его хвост: закрепиться
            // на начале значит показывать то, что владелец сказал минуту назад.
            textView.scrollToEndOfDocument(nil)
            needsDisplay = true
        }
    }

    /// Раскрытие панели 0…1. Содержимое проявляется ПОСЛЕ стекла, а не вместе
    /// с ним: буквы, едущие вместе с растущей рамкой, читаются рывком.
    var revealProgress: CGFloat = 0 {
        didSet {
            guard revealProgress != oldValue else { return }
            let visible = max(0, (revealProgress - 0.45) / 0.55)
            card.alphaValue = visible
            copyButton.alphaValue = visible
            closeButton.alphaValue = visible
            for button in actionButtons { button.alphaValue = visible }
            // Подложка не только проявляется, но и подрастает: так раскрытие
            // читается одним движением, а не появлением второго предмета.
            let scale = 0.94 + 0.06 * visible
            card.layer?.transform = CATransform3DMakeScale(scale, scale, 1)
        }
    }

    /// Текст забрали. Панель после этого закрывается: она держала на экране
    /// ровно одно дело, и дело сделано. Владелец сказал прямо - копирую, а она
    /// висит и убрать её нечем.
    var onCopied: (() -> Void)?

    /// Сколько жизни панели осталось, 1…0. Ведет ее общий такт движения окна,
    /// а не свой таймер внутри вида: два независимых отсчета разъезжаются, и
    /// кольцо начинает врать про то, когда панель уйдет.
    var lifeRemaining: CGFloat = 1 {
        didSet {
            guard abs(lifeRemaining - oldValue) > 0.001 else { return }
            closeButton.remaining = lifeRemaining
        }
    }

    /// Кнопки раскрытой формы. Живут в подвале слева, где у панели пусто:
    /// справа стоит «Скопировать», и спорить с ней за место нельзя.
    var actions: [DictationHUDAction] = [] {
        didSet {
            guard actions != oldValue else { return }
            rebuildActionButtons()
        }
    }
    var onAction: ((DictationHUDActionID) -> Void)?

    /// Показывать ли кнопку «Скопировать». В раскрытой по щелчку плашке текста
    /// может не быть вовсе.
    var showsCopy: Bool = true {
        didSet {
            guard showsCopy != oldValue else { return }
            copyButton.isHidden = !showsCopy
        }
    }

    private var actionButtons: [DictationHUDActionButton] = []

    private let card = NSView()
    private let closeButton = DictationHUDCloseRing()
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let copyButton = DictationHUDCopyPill()
    private var copied = false
    private var resetWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        card.wantsLayer = true
        card.layer?.cornerRadius = DICTATION_HUD_TRANSCRIPT_CARD_RADIUS
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        addSubview(card)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: DICTATION_HUD_TRANSCRIPT_FONT_SIZE)
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        card.addSubview(scroll)

        copyButton.title = DICTATION_HUD_TRANSCRIPT_COPY_TITLE
        copyButton.onPress = { [weak self] in self?.copyPressed() }
        addSubview(copyButton)

        // Закрыть руками, не дожидаясь конца отсчета. Панель живет двадцать
        // секунд, и это долго, когда текст уже не нужен. Путь наверх тот же,
        // что у копирования: дело панели кончилось, и разница только в том,
        // попал текст в буфер или нет.
        closeButton.onPress = { [weak self] in
            guard let self else { return }
            // Панель поднял недоехавший текст - крестик значит «дело сделано».
            // Панель раскрыл владелец - крестик значит «сверни обратно».
            if actions.isEmpty { onCopied?() } else { onAction?(.collapse) }
        }
        addSubview(closeButton)

        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Цвета берутся у системы и перечитываются при смене темы: подложка
    /// обязана оставаться плотной и в светлой, и в тёмной.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            card.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    private func rebuildActionButtons() {
        for button in actionButtons { button.removeFromSuperview() }
        actionButtons = actions.map { action in
            let button = DictationHUDActionButton(action: action)
            button.onPress = { [weak self] id in self?.onAction?(id) }
            button.alphaValue = copyButton.alphaValue
            addSubview(button)
            return button
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let padding = DICTATION_HUD_TRANSCRIPT_PADDING
        let header = DICTATION_HUD_TRANSCRIPT_HEADER_HEIGHT
        let ring = DICTATION_HUD_TRANSCRIPT_CLOSE_SIZE
        closeButton.frame = CGRect(x: bounds.width - padding - ring,
                                   y: padding - 2,
                                   width: ring, height: ring)
        let footer = DICTATION_HUD_TRANSCRIPT_FOOTER_HEIGHT
        let gap = DICTATION_HUD_TRANSCRIPT_FOOTER_GAP
        let cardHeight = max(0, bounds.height - padding * 2 - header - gap - footer)
        card.frame = CGRect(x: padding, y: padding + header,
                            width: max(0, bounds.width - padding * 2),
                            height: cardHeight)
        let inset = DICTATION_HUD_TRANSCRIPT_CARD_INSET
        scroll.frame = CGRect(x: inset, y: inset,
                              width: max(0, card.bounds.width - inset * 2),
                              height: max(0, card.bounds.height - inset * 2))
        textView.textContainer?.containerSize = CGSize(width: scroll.contentSize.width,
                                                       height: .greatestFiniteMagnitude)
        let buttonWidth = max(104, copyButton.fittingWidth)
        // «Скопировать» уехала в шапку, к крестику. В подвале она наезжала на
        // ряд кнопок: кнопок стало семь, и правый край ряда пришёл ей прямо
        // под низ. Поймано владельцем на живой плашке 06.09.2026.
        copyButton.frame = CGRect(x: max(padding, bounds.width - padding - ring - 8 - buttonWidth),
                                  y: padding - 2,
                                  width: buttonWidth,
                                  height: max(footer, ring))
        // Кнопки - в подвале слева, ряд с ровным шагом. Размер берётся от
        // высоты подвала: подвал меняется вместе с размером плашки, и
        // отдельная константа тут разъехалась бы с ним.
        if !actionButtons.isEmpty {
            let count = CGFloat(actionButtons.count)
            let room = max(0, bounds.width - padding * 2)
            // Шаг ужимается под ширину панели, а не наоборот: панель считается
            // от текста, и ряд обязан поместиться в неё, а не раздвинуть её.
            let side = min(min(footer, DICTATION_HUD_TRANSCRIPT_FOOTER_HEIGHT),
                           max(14, (room - (count - 1) * 6) / count))
            let step = side + 6
            let total = count * side + (count - 1) * 6
            var x = padding + max(0, (room - total) / 2)
            for button in actionButtons {
                button.frame = CGRect(x: x,
                                      y: bounds.height - padding - footer + (footer - side) / 2,
                                      width: side, height: side)
                x += step
            }
        }

        // Слой подложки растёт от середины: иначе рост при раскрытии уводил бы
        // её в угол.
        card.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        card.layer?.position = CGPoint(x: card.frame.midX, y: card.frame.midY)
    }

    /// Забрать текст целиком. Владелец не обязан его выделять: он и так знает,
    /// что диктовал, и пришёл сюда за одним - забрать сказанное.
    @discardableResult
    func copyAll() -> Bool {
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func copyPressed() {
        guard copyAll() else { return }
        showCopied()
    }

    private func showCopied() {
        copied = true
        copyButton.title = DICTATION_HUD_TRANSCRIPT_COPIED_TITLE
        needsLayout = true
        resetWork?.cancel()
        // Подтверждение видно мгновение, потом панель уходит. Закрыть её сразу
        // значит не сказать, что копирование состоялось; оставить висеть -
        // заставить искать, чем её убрать.
        let work = DispatchWorkItem { [weak self] in self?.onCopied?() }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DICTATION_HUD_TRANSCRIPT_COPIED_SECONDS,
                                      execute: work)
    }

    override func mouseDown(with event: NSEvent) {
        // Клик по панели забирает текст. Выделение мышью при этом остаётся:
        // NSTextView получает событие первым, а сюда доходит только клик мимо
        // текста - по полю панели.
        //
        // Но не тогда, когда панель раскрыта владельцем: там текста может не
        // быть вовсе, а щелчок мимо кнопок обязан сворачивать плашку обратно,
        // а не молча ничего не делать.
        // Копировать нечего - и копировать нельзя: в раскрытой по щелчку плашке
        // стоит ЗАГЛУШКА, и она уезжала владельцу в буфер обмена вместо текста.
        // Тот же признак, что прячет кнопку «Скопировать», решает и здесь -
        // иначе кнопки нет, а копирование есть.
        if showsCopy, copyAll() { showCopied(); return }
        guard !actions.isEmpty else { return }
        onAction?(.collapse)
    }
}


/// Кнопка «Скопировать», нарисованная своими руками.
///
/// Системная кнопка на этой панели не годится: панель безрамочная и
/// полупрозрачная, и системный безель на ней читался голым текстом - владелец
/// увидел подпись без кнопки. Здесь пилюля рисуется сама и выглядит одинаково
/// на любом фоне.
final class DictationHUDCopyPill: NSView {
    var title: String = "" {
        didSet { if title != oldValue { needsDisplay = true } }
    }
    var onPress: (() -> Void)?

    private var pressed = false

    override var isFlipped: Bool { true }

    var fittingWidth: CGFloat {
        (title as NSString).size(withAttributes: [.font: Self.font]).width + 26
    }

    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        // Кремовая, а не системная синяя. Синяя кнопка на стеклянной плашке
        // читается чужой деталью macOS, попавшей внутрь продукта; теплый камень
        // - цвет семьи, и панель выглядит своей.
        DICTATION_HUD_TRANSCRIPT_BUTTON_FILL.withAlphaComponent(pressed ? 0.82 : 1).setFill()
        path.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: DICTATION_HUD_TRANSCRIPT_BUTTON_INK,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                                             y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }
}


/// Крестик с кольцом обратного отсчета.
///
/// Кольцо показывает то, что и так происходит: панель уходит сама через
/// двадцать секунд. Без кольца это выглядит внезапным исчезновением, и человек
/// не понимает, успеет он дочитать или нет. С кольцом ожидание становится
/// видимым, а крестик дает выйти раньше.
final class DictationHUDCloseRing: NSView {
    /// Сколько осталось, 1…0.
    var remaining: CGFloat = 1 {
        didSet { needsDisplay = true }
    }
    var onPress: (() -> Void)?

    private var pressed = false

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 3
        let disk = bounds.insetBy(dx: inset, dy: inset)

        // Цвета берутся у системы, а не из палитры семьи. Кремовое кольцо на
        // светлом фоне не видно вовсе, а панель стоит поверх ЧУЖОГО окна: какого
        // оно тона, заранее не знает никто. Ярлык системы читается всегда.
        let ink = NSColor.labelColor
        ink.withAlphaComponent(pressed ? 0.22 : 0.12).setFill()
        NSBezierPath(ovalIn: disk).fill()

        // Кольцо отсчета идет по кромке и убывает по часовой стрелке от верха.
        if remaining > 0 {
            let ring = NSBezierPath()
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = disk.width / 2 + 1.5
            ring.appendArc(withCenter: center, radius: radius,
                           startAngle: 90,
                           endAngle: 90 - 360 * max(0, min(1, remaining)),
                           clockwise: true)
            ring.lineWidth = 1.6
            ring.lineCapStyle = .round
            ink.withAlphaComponent(0.65).setStroke()
            ring.stroke()
        }

        // Сам крест: две черты, а не символ шрифта. Глиф пришлось бы центровать
        // по метрикам чужого шрифта, и на разных системах он бы гулял.
        let arm = disk.width * 0.26
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: center.x - arm, y: center.y - arm))
        cross.line(to: CGPoint(x: center.x + arm, y: center.y + arm))
        cross.move(to: CGPoint(x: center.x + arm, y: center.y - arm))
        cross.line(to: CGPoint(x: center.x - arm, y: center.y + arm))
        cross.lineWidth = 1.6
        cross.lineCapStyle = .round
        ink.withAlphaComponent(0.85).setStroke()
        cross.stroke()
    }
}
