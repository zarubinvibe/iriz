// Кнопки на плашке.
//
// Владелец 06.09.2026: «Там должна быть анимация, которая переходит по выбору
// кнопок. Она анимацией перестраивается из просто закрытой плашки в открытую,
// где идет запись текста».
//
// Прежде плашка была немой: щелчок по ней не значил ничего, а язык, история и
// настройки жили в меню правой кнопки. Это было записано решением - HUD_SPEC §8,
// строка «Действия по щелчку»: «Владелец этого не просил». Теперь просил, и та
// строка отменена тем же ходом, что и запрет постоянной плашки.
//
// ПОЧЕМУ КНОПКИ ЖИВУТ ТОЛЬКО В РАСКРЫТОЙ ФОРМЕ. Закрытая плашка висит поверх
// чужого окна весь день, и каждый её пункт - это пункт, где щелчок не доходит
// до приложения под ней. Пять кнопок на закрытой плашке означали бы пять
// поводов промахнуться. В раскрытой форме владелец уже смотрит на плашку и
// ждёт от неё действия.
import AppKit

/// Что кнопка делает. Идентификатор, а не замыкание: набор кнопок собирается
/// чистой функцией и проверяется пробой без окна и без мыши.
public enum DictationHUDActionID: String, Sendable, CaseIterable {
    /// Начать или закончить запись. Первая слева - ради неё плашку и открывают.
    case record
    /// Записать для промпта: речь уйдёт агенту и вернётся готовым заданием.
    case modePrompt
    /// Записать для перевода: скажу по-русски, получу по-английски.
    case modeTranslation
    /// Язык распознавания по кругу: определять самому → русский → английский.
    case language
    /// История надиктовок.
    case history
    /// Настройки.
    case settings
    /// Свернуть плашку обратно в покой.
    case collapse
}

/// Кнопка: знак, подпись голосовому доступу и признак «горит».
public struct DictationHUDAction: Equatable, Sendable {
    public let id: DictationHUDActionID
    /// Имя символа SF. Строкой, а не картинкой: модель не тащит за собой AppKit.
    public let symbol: String
    public let title: String
    /// Подпись вместо знака. Нужна ровно языку: «RU» читается быстрее любого
    /// глобуса, а глобус не говорит, какой язык стоит СЕЙЧАС.
    public let label: String?
    /// Горит - значит действие сейчас идёт. Только у записи: остальные кнопки
    /// мгновенные, и гореть им нечем.
    public let active: Bool

    public init(id: DictationHUDActionID,
                symbol: String,
                title: String,
                active: Bool = false,
                label: String? = nil) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.active = active
        self.label = label
    }
}

/// Короткая подпись языка для кнопки. Два знака: кнопка размером с монету, и
/// «Определять самому» на ней не поместится ни при каком кегле.
public func dictationHUDLanguageBadge(_ language: DictationLanguage) -> String {
    switch language {
    case .auto: return "АВ"
    case .russian: return "RU"
    case .english: return "EN"
    default: return String(language.rawValue.prefix(2)).uppercased()
    }
}

/// Полоска управления, которая раскрывается ПОД МЫШЬЮ.
///
/// Слова владельца 06.09.2026: «при наведении ничего не происходит, там просто
/// написано, что нажми эту кнопку… а при этом он должен раскрыться немножко для
/// того, чтобы можно было сменить язык, выбрать режим, например, polish или
/// prompt. То есть то, как было реализовано у Whisper Flow».
///
/// Отсюда состав: сначала три способа начать запись (обычная, для промпта, для
/// перевода), потом язык, потом два перехода. Подсказка словами, которая стояла
/// тут раньше, отменена: она называла клавишу, а не давала выбрать режим.
public func dictationHUDStripActions(isRecording: Bool,
                                     language: DictationLanguage) -> [DictationHUDAction] {
    [
        DictationHUDAction(id: .record,
                           symbol: isRecording ? "stop.fill" : "mic.fill",
                           title: isRecording ? "Закончить запись" : "Начать запись",
                           active: isRecording),
        DictationHUDAction(id: .modePrompt, symbol: "wand.and.stars",
                           title: "Записать для промпта"),
        DictationHUDAction(id: .modeTranslation, symbol: "character.bubble",
                           title: "Записать для перевода"),
        DictationHUDAction(id: .language, symbol: "globe",
                           title: "Язык распознавания: \(dictationLanguageMenuTitle(language))",
                           label: dictationHUDLanguageBadge(language)),
        DictationHUDAction(id: .history, symbol: "clock.arrow.circlepath", title: "История"),
        DictationHUDAction(id: .settings, symbol: "gearshape", title: "Настройки"),
    ]
}

/// Набор кнопок РАСКРЫТОЙ панели: та же полоска плюс «свернуть». Панель
/// открывают щелчком, и закрыть её должно быть чем.
public func dictationHUDActions(isRecording: Bool,
                                language: DictationLanguage = .auto) -> [DictationHUDAction] {
    dictationHUDStripActions(isRecording: isRecording, language: language)
        + [DictationHUDAction(id: .collapse, symbol: "chevron.down", title: "Свернуть плашку")]
}

/// Следующий язык по кругу. Круг короткий и тот же, что в меню плашки: длинный
/// список под курсором - это не выбор, а поиск.
public func dictationHUDNextLanguage(after current: DictationLanguage) -> DictationLanguage {
    let circle = dictationHUDMenuLanguages
    guard let index = circle.firstIndex(of: current) else { return circle[0] }
    return circle[(index + 1) % circle.count]
}

/// Круглая кнопка со знаком. Своими руками по той же причине, что и пилюля
/// «Скопировать»: системный безель на полупрозрачной панели читается голым
/// значком без кнопки.
final class DictationHUDActionButton: NSView {
    var action: DictationHUDAction {
        didSet { if action != oldValue { needsDisplay = true } }
    }
    var onPress: ((DictationHUDActionID) -> Void)?
    /// Кого звать, когда мышь пришла на кнопку или ушла с неё. Владелец
    /// 06.09.2026: «наводя на значок, он должен как-то анимироваться тоже, что
    /// именно я его выбираю. И там должно быть понимание, что это такое. То
    /// есть просто так по значкам непонятно».
    var onHover: ((DictationHUDAction?) -> Void)?

    private var pressed = false
    private var hovered = false {
        didSet {
            guard hovered != oldValue else { return }
            applyHoverLift()
            needsDisplay = true
        }
    }

    /// Кнопка под мышью ПОДРАСТАЕТ. Не мгновенно: скачок размера читается
    /// дёрганьем, а не выбором. Слой, а не перерисовка: масштаб на слое ведёт
    /// рендер-сервер, и такт кадров плашки для этого поднимать не нужно.
    private func applyHoverLift() {
        wantsLayer = true
        guard let layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        let scale: CGFloat = hovered ? 1.18 : 1
        let lift = CABasicAnimation(keyPath: "transform.scale")
        lift.fromValue = layer.value(forKeyPath: "transform.scale") ?? 1
        lift.toValue = scale
        lift.duration = 0.14
        lift.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(lift, forKey: "irizHoverLift")
        layer.setValue(scale, forKeyPath: "transform.scale")
    }

    override func layout() {
        super.layout()
        // Слой держит середину кнопки: без этого рост под мышью уводил бы её
        // в угол ряда.
        guard let layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
    }
    private var tracking: NSTrackingArea?

    init(action: DictationHUDAction) {
        self.action = action
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(action.title)
        toolTip = action.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override var isFlipped: Bool { true }

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

    /// Включить вид «под мышью» без мыши: прибор съёмки её не двигает.
    func forceHover(_ on: Bool) { hovered = on }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        onHover?(action)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?(action.id)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Цвета системные, а не палитра семьи: панель стоит поверх ЧУЖОГО окна,
        // и какого оно тона, заранее не знает никто. Та же причина, по которой
        // системные цвета взяты у крестика с кольцом.
        let ink = NSColor.labelColor
        // Бумага - цвет, противоположный чернилам В ЭТОЙ теме. Считать её белой
        // нельзя: на тёмной плашке чернила белые, и белый знак на светлящемся
        // круге пропадает. Поймано владельцем живьём 06.09.2026: «когда на
        // тёмной плашке происходит выделение, там не видно значков».
        let paper = NSColor.textBackgroundColor
        let disk = bounds.insetBy(dx: 1, dy: 1)
        let selected = hovered || pressed
        if action.active {
            NSColor.systemRed.withAlphaComponent(pressed ? 0.95 : 0.85).setFill()
        } else if selected {
            // Выбор читается ИНВЕРСИЕЙ, а не подсветкой: круг заливается
            // чернилами целиком, знак становится бумагой. Так он виден в любой
            // теме и на любом фоне под плашкой.
            ink.withAlphaComponent(pressed ? 0.95 : 0.86).setFill()
        } else {
            ink.withAlphaComponent(0.10).setFill()
        }
        NSBezierPath(ovalIn: disk).fill()

        let ink2 = (action.active || selected) ? paper : ink.withAlphaComponent(0.85)
        if let label = action.label {
            let font = NSFont.systemFont(ofSize: max(8, disk.width * 0.40), weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink2]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2,
                                                 y: bounds.midY - size.height / 2),
                                     withAttributes: attributes)
            return
        }

        let side = disk.width * 0.52
        // Цвет знака задаётся ПАЛИТРОЙ символа, а не заливкой поверх. Заливка
        // `.sourceAtop` красит весь прямоугольник рисунка, а не только сам
        // знак: на тёмной теме белый круг под мышью получал тёмный квадрат
        // вместо значка. Поймано кадром прибора съёмки.
        let config = NSImage.SymbolConfiguration(pointSize: side, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink2]))
        guard let image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        let rect = CGRect(x: bounds.midX - size.width / 2,
                          y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }
}
