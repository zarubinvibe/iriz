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

final class DictationHUDTranscriptView: NSView {
    /// Текст, который не доехал.
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            textView.string = text
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

    private let card = NSView()
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

    override func layout() {
        super.layout()
        let padding = DICTATION_HUD_TRANSCRIPT_PADDING
        let footer = DICTATION_HUD_TRANSCRIPT_FOOTER_HEIGHT
        let gap = DICTATION_HUD_TRANSCRIPT_FOOTER_GAP
        let cardHeight = max(0, bounds.height - padding * 2 - gap - footer)
        card.frame = CGRect(x: padding, y: padding,
                            width: max(0, bounds.width - padding * 2),
                            height: cardHeight)
        let inset = DICTATION_HUD_TRANSCRIPT_CARD_INSET
        scroll.frame = CGRect(x: inset, y: inset,
                              width: max(0, card.bounds.width - inset * 2),
                              height: max(0, card.bounds.height - inset * 2))
        textView.textContainer?.containerSize = CGSize(width: scroll.contentSize.width,
                                                       height: .greatestFiniteMagnitude)
        let buttonWidth = max(104, copyButton.fittingWidth)
        copyButton.frame = CGRect(x: bounds.width - padding - buttonWidth,
                                  y: bounds.height - padding - footer,
                                  width: buttonWidth,
                                  height: footer)
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
        if copyAll() { showCopied() }
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
        // Нажатие видно: без отклика кнопка кажется неживой.
        NSColor.controlAccentColor.withAlphaComponent(pressed ? 0.75 : 1).setFill()
        path.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor.white,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                                             y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }
}
