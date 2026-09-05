import AppKit

final class DictationHUDHintView: NSView {
    var lines: [String] = [] {
        didSet {
            // Те же строки — не новость: раскладка присваивает их на каждом
            // тике, и без этой проверки подсказка помечалась грязной 120 раз
            // в секунду ради ничего.
            guard lines != oldValue else { return }
            measuredSize = nil
            needsDisplay = true
        }
    }

    var appearanceProgress: CGFloat = 0 {
        didSet {
            guard appearanceProgress != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// Замер строк стоит обращения к CoreText, а раскладка спрашивает размер
    /// на каждом кадре анимации. Строки между кадрами не меняются — считаем
    /// один раз на смену строк.
    private var measuredSize: CGSize?

    var fittingHintSize: CGSize {
        if let measuredSize { return measuredSize }
        let size = measureHintSize()
        measuredSize = size
        return size
    }

    /// Прогреть CoreText: первый замер строки поднимает шрифт и его кеши, и
    /// платить за это в момент первого показа плашки незачем.
    func warmTextMetrics() {
        _ = (" " as NSString).size(withAttributes: attributes(for: 0))
        _ = (" " as NSString).size(withAttributes: attributes(for: 1))
    }

    private func measureHintSize() -> CGSize {
        guard !lines.isEmpty else { return .zero }
        let widths = lines.prefix(2).enumerated().map { index, line in
            ceil((line as NSString).size(withAttributes: attributes(for: index)).width)
        }
        let width = min(DICTATION_HUD_HINT_MAX_WIDTH,
                        max(DICTATION_HUD_HINT_MIN_WIDTH,
                            (widths.max() ?? 100) + 2 * DICTATION_HUD_HINT_HORIZONTAL_PADDING))
        let height = lines.count > 1
            ? 2 * DICTATION_HUD_HINT_VERTICAL_PADDING
                + 2 * DICTATION_HUD_HINT_LINE_HEIGHT
                + DICTATION_HUD_HINT_LINE_GAP
            : 2 * DICTATION_HUD_HINT_VERTICAL_PADDING + DICTATION_HUD_HINT_LINE_HEIGHT
        return CGSize(width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !lines.isEmpty else { return }
        let alpha = dictationHUDHoverLayers(progress: appearanceProgress).plateAlpha
        guard alpha > 0.001 else { return }

        let light = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        let fill = light
            ? NSColor(calibratedWhite: 1, alpha: 0.84 * alpha)
            : NSColor(calibratedWhite: 0, alpha: 0.96 * alpha)
        let stroke = light
            ? NSColor(calibratedWhite: 0, alpha: 0.14 * alpha)
            : NSColor(calibratedWhite: 0.22, alpha: 0.26 * alpha)
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: DICTATION_HUD_HINT_RADIUS,
                                 yRadius: DICTATION_HUD_HINT_RADIUS)
        fill.setFill()
        plate.fill()
        stroke.setStroke()
        plate.lineWidth = DICTATION_HUD_HINT_BORDER_WIDTH
        plate.stroke()

        for (index, line) in lines.prefix(2).enumerated() {
            let y = DICTATION_HUD_HINT_VERTICAL_PADDING
                + CGFloat(index) * (DICTATION_HUD_HINT_LINE_HEIGHT + DICTATION_HUD_HINT_LINE_GAP)
            let rect = NSRect(x: DICTATION_HUD_HINT_HORIZONTAL_PADDING,
                              y: y,
                              width: max(0, bounds.width - 2 * DICTATION_HUD_HINT_HORIZONTAL_PADDING),
                              height: DICTATION_HUD_HINT_LINE_HEIGHT)
            let attributed = NSAttributedString(string: line,
                                                attributes: attributes(for: index,
                                                                       alpha: alpha,
                                                                       light: light))
            attributed.draw(in: rect)
        }
    }

    private func attributes(for index: Int,
                            alpha: CGFloat = 1,
                            light: Bool = true) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let color: NSColor
        if index == 0 {
            color = light
                ? NSColor(calibratedWhite: 0, alpha: 0.85 * alpha)
                : NSColor(calibratedWhite: 1, alpha: 0.92 * alpha)
        } else {
            color = light
                ? NSColor(calibratedWhite: 0, alpha: 0.55 * alpha)
                : NSColor(calibratedWhite: 1, alpha: 0.55 * alpha)
        }
        return [
            .font: index == 0
                ? NSFont.systemFont(ofSize: 12, weight: .medium)
                : NSFont.systemFont(ofSize: 11),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }
}
