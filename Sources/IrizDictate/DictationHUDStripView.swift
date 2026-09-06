// Полоска управления, которая раскрывается под мышью.
//
// Владелец 06.09.2026: «при наведении ничего не происходит, там просто написано,
// что нажми эту кнопку… а при этом он должен раскрыться немножко для того, чтобы
// можно было сменить язык, выбрать режим, например, polish или prompt».
//
// Прежде наведение поднимало подсказку СЛОВАМИ - «правый ⌘ — закончить». Она
// называла клавишу тому, кто уже стоит мышью на плашке и хочет нажать, а не
// вспомнить. Полоска даёт то, чего подсказка дать не могла: начать запись в
// нужном режиме и сменить язык, не уходя в настройки.
import AppKit

/// Ряд круглых кнопок внутри плашки.
final class DictationHUDStripView: NSView {
    var actions: [DictationHUDAction] = [] {
        didSet {
            guard actions != oldValue else { return }
            rebuild()
        }
    }
    var onAction: ((DictationHUDActionID) -> Void)?
    /// Что сейчас под мышью. `nil` - ничего.
    /// Что под мышью и ГДЕ оно стоит. Кадр кнопки нужен подписи: без него она
    /// центрируется по всей плашке и у крайних кнопок читается съехавшей -
    /// поймано владельцем на кадре 06.09.2026 («тут тоже видно, как всё
    /// съехало, там, где шестерёнка»).
    var onHover: ((DictationHUDAction?, CGRect?) -> Void)?
    /// Плашка стоит боком - ряд идёт столбиком. Решение владельца: «если это
    /// сбоку примагничивание, значит должна быть раскладка боком».
    var vertical: Bool = false { didSet { needsLayout = true } }

    private var buttons: [DictationHUDActionButton] = []

    override var isFlipped: Bool { true }

    /// Мышь ловят кнопки, а не сама полоска: щелчок мимо кнопки обязан дойти до
    /// плашки под ней и раскрыть её, а не утонуть в пустом месте ряда.
    override func hitTest(_ point: NSPoint) -> NSView? {
        for button in buttons {
            if let hit = button.hitTest(convert(point, from: superview)) { return hit }
        }
        return nil
    }

    /// Подсветить кнопку по номеру - для приборов съёмки.
    func highlight(_ index: Int?) {
        for (i, button) in buttons.enumerated() { button.forceHover(i == index) }
    }

    private func rebuild() {
        for button in buttons { button.removeFromSuperview() }
        buttons = actions.map { action in
            let button = DictationHUDActionButton(action: action)
            button.onPress = { [weak self] id in self?.onAction?(id) }
            button.onHover = { [weak self, weak button] action in
                self?.onHover?(action, action == nil ? nil : button?.frame)
            }
            addSubview(button)
            return button
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !buttons.isEmpty else { return }
        let frames = dictationHUDStripLayout(width: bounds.width,
                                             height: bounds.height,
                                             buttons: buttons.count,
                                             vertical: vertical)
        for (button, frame) in zip(buttons, frames) { button.frame = frame }
    }
}

/// Просвет между кнопками полоски.
let DICTATION_HUD_STRIP_GAP: CGFloat = 6

/// Куда встают кнопки в полоске такой ширины.
///
/// Чистая функция и ЕДИНСТВЕННОЕ место, где считается место кнопок. Владелец
/// поймал живьём 06.09.2026: «когда плашка раскрывается при наведении, правая
/// часть, она вылезает за пределы плашки». Так и было: ряд считался от
/// желаемой стороны кнопки, а плашка в середине морфа ещё уже конечной, и ряд
/// торчал наружу. Здесь этого не может случиться по построению - сторона и
/// просвет ужимаются под ту ширину, что есть СЕЙЧАС.
///
/// Правило держится пробой, а не вниманием: невозможность вылезти проверяется
/// перебором ширин.
public func dictationHUDStripLayout(width: CGFloat,
                                    height: CGFloat,
                                    buttons: Int,
                                    vertical: Bool = false) -> [CGRect] {
    guard buttons > 0, width > 0, height > 0 else { return [] }
    // Столбик - тот же ряд, посчитанный в перевёрнутых мерах и разложенный
    // обратно. Второй копии арифметики не заводим: она разъехалась бы с первой
    // на первой же правке просвета.
    if vertical {
        return dictationHUDStripLayout(width: height, height: width, buttons: buttons)
            .map { CGRect(x: $0.minY, y: $0.minX, width: $0.height, height: $0.width) }
    }
    let count = CGFloat(buttons)
    let ideal = dictationHUDStripButtonSide(height: height)
    let pad = DICTATION_HUD_STRIP_EDGE
    // Сколько места есть на самом деле. Ужимается сначала просвет, потом
    // сторона: тесный ряд читается лучше обрезанного.
    let room = max(0, width - pad * 2)
    var gap = DICTATION_HUD_STRIP_GAP
    var side = min(ideal, (room - (count - 1) * gap) / count)
    if side < DICTATION_HUD_STRIP_MIN_SIDE {
        gap = 2
        side = min(ideal, (room - (count - 1) * gap) / count)
    }
    side = max(0, min(side, height))
    let total = count * side + (count - 1) * gap
    var x = (width - total) / 2
    let y = (height - side) / 2
    var frames: [CGRect] = []
    for _ in 0..<buttons {
        frames.append(CGRect(x: x, y: y, width: side, height: side))
        x += side + gap
    }
    return frames
}

/// Поле от кромки плашки до первой кнопки.
let DICTATION_HUD_STRIP_EDGE: CGFloat = 5
/// Меньше этого кнопка перестаёт быть кнопкой, и тогда ужимается просвет.
let DICTATION_HUD_STRIP_MIN_SIDE: CGFloat = 15

/// Сторона кнопки для плашки такой высоты. Доля, а не пункты: высота плашки
/// зависит от выбранного владельцем размера, и жёсткое число разъехалось бы с
/// ней на двух вариантах из трёх.
func dictationHUDStripButtonSide(height: CGFloat) -> CGFloat {
    max(16, (height * 0.62).rounded())
}

/// Размер плашки, раскрытой полоской. Считается от рабочего размера и числа
/// кнопок: ряд обязан помещаться целиком, иначе крайние кнопки срежет обрез.
public func dictationHUDStripSize(working: CGSize, buttons: Int) -> CGSize {
    guard buttons > 0 else { return working }
    let side = dictationHUDStripButtonSide(height: working.height)
    let inner = CGFloat(buttons) * side + CGFloat(buttons - 1) * DICTATION_HUD_STRIP_GAP
    // Поле по краям - половина кнопки с каждой стороны: ряд, упирающийся в
    // кромку стекла, читается обрезанным.
    let width = max(working.width, inner + side + DICTATION_HUD_STRIP_EDGE * 2)
    return CGSize(width: width.rounded(), height: working.height)
}
