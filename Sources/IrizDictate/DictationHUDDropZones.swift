// Матовое стекло на весь экран с вырезанными местами посадки.
//
// Владелец 06.09.2026: «чтобы при переносе весь экран становился мутным, кроме
// той зоны, куда будет переноситься плашка… эта мутная часть, она может быть
// как стекло как раз на весь экран, матовое стекло, которое все закрывает… а
// зоны, куда будет вставать плашка, они должны быть просто как будто вырезаны».
//
// Стекло здесь - НЕ Liquid Glass плашки, а полноэкранный матовый слой
// (NSVisualEffectView, режим behindWindow). Для плашки этот материал запрещён и
// останется запрещённым: он не сэмплирует фон как стекло. Но полотно во весь
// экран - другая задача: тут нужно ровно размытие всего, что позади, и родной
// материал делает это дешевле и честнее, чем чёрная заливка.
//
// Дыры вырезаются маской (`maskImage`): непрозрачное в маске - там стекло есть,
// прозрачное - там его нет вовсе, и сквозь дыру видно рабочий стол как он есть.
import AppKit

/// Полотно с дырами. Само стекло рисует NSVisualEffectView под этим видом,
/// здесь остаются только кромки и подсветка выбранного места.
final class DictationHUDDropZoneView: NSView {
    /// Куда плашка может встать. В координатах вида.
    var zones: [CGRect] = [] {
        didSet {
            guard zones != oldValue else { return }
            applyMask()
            marks.zones = zones
        }
    }

    /// То, куда она встанет, если отпустить сейчас.
    var highlighted: CGRect? {
        didSet {
            guard highlighted != oldValue else { return }
            marks.highlighted = highlighted
        }
    }

    private let blur = NSVisualEffectView()
    /// Кромки и подсветка рисуются ОТДЕЛЬНЫМ видом поверх стекла. Своим
    /// `draw` их не нарисовать: `draw` надвида идёт ПОД его подвидами, и обводки
    /// тонули под матовым слоем - поймано кадром, где выбранного места не было
    /// видно вовсе.
    private let marks = DictationHUDDropMarksView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        addSubview(blur, positioned: .below, relativeTo: nil)
        marks.frame = bounds
        marks.autoresizingMask = [.width, .height]
        addSubview(marks, positioned: .above, relativeTo: blur)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override var isFlipped: Bool { false }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        applyMask()
    }

    /// Маска: стекло везде, кроме мест посадки.
    private func applyMask() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let image = NSImage(size: bounds.size, flipped: false) { [zones] rect in
            NSColor.black.setFill()
            rect.fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            for zone in zones {
                let radius = min(zone.width, zone.height) / 2
                NSBezierPath(roundedRect: zone, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        // Растягивать маску нельзя: дыры уедут. Размер задан ровно по виду.
        image.resizingMode = .stretch
        blur.maskImage = image
    }

}

/// Кромки дыр и подсветка выбранного места. Отдельным видом - см. `marks`.
private final class DictationHUDDropMarksView: NSView {
    var zones: [CGRect] = [] { didSet { needsDisplay = true } }
    var highlighted: CGRect? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Кромка каждой дыры: без неё вырез на однотонном фоне не читается
        // местом - он выглядит просто пятном, где стекло не легло.
        for zone in zones {
            let radius = min(zone.width, zone.height) / 2
            let path = NSBezierPath(roundedRect: zone, xRadius: radius, yRadius: radius)
            NSColor.white.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        guard let highlighted else { return }
        let radius = min(highlighted.width, highlighted.height) / 2
        // Выбранное место обведено ярче и с полем: владелец обязан видеть,
        // куда именно плашка сядет, не гадая между соседними дырами.
        let ring = NSBezierPath(roundedRect: highlighted.insetBy(dx: -9, dy: -9),
                                xRadius: radius + 9, yRadius: radius + 9)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        ring.lineWidth = 2.5
        ring.stroke()
        NSColor.white.withAlphaComponent(0.16).setFill()
        ring.fill()
    }

}

/// Окно затемнения на весь экран.
@MainActor
func makeDictationHUDDropZoneWindow(screen: NSScreen) -> NSWindow {
    let window = NSWindow(contentRect: screen.frame,
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.animationBehavior = .none
    // Под плашкой, но над всем остальным: плашку надо видеть на всём пути, а
    // чужие окна - нет.
    window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    let view = DictationHUDDropZoneView(frame: CGRect(origin: .zero, size: screen.frame.size))
    window.contentView = view
    return window
}
