// Стеклянный слой плашки: настоящий Liquid Glass, а не имитация.
//
// `NSGlassEffectContainerView` сливает соседние стёкла, когда они ближе
// `spacing`, и разводит, когда дальше. Это и есть механизм, которым «баблы
// плавно перетекают из одного в другое»: мы двигаем два стекла, слияние делает
// система. Имитировать это блюром бессмысленно - блюр не преломляет и не
// сливается, а Liquid Glass делает и то и другое.
//
// Доступно с macOS 26. Порог сборки проекта - macOS 14, поэтому весь слой
// живёт под проверкой доступности, а на младших системах работает прежний
// путь. Тот же приём уже применён для Metal и Core Graphics.
import AppKit

/// Ореол по кромке стекла: мягкое голубое свечение, которое мерцает.
///
/// Метка «здесь работает ИИ». Голубой не случайный - это `#B8D6EA` канона
/// Пантеона, цвет потока семьи, и здесь он значит ровно то же самое.
///
/// Живёт ОТДЕЛЬНЫМ видом поверх стекла, а не внутри его содержимого: содержимое
/// обрезано по стеклу, и нарисованный там ореол светит только внутрь - на кадре
/// это читается кольцом, а не свечением. Поймано кадром.
@MainActor
final class DictationHUDHaloView: NSView {
    /// Кадр стекла, вокруг которого светит ореол, в координатах этого вида.
    var target: CGRect = .zero { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var phase: CGFloat = 0
    var reduceMotion = false
    /// Цвет свечения. Голубой Пантеона по умолчанию; у обрыва - красный,
    /// и тогда это не метка режима, а вспышка «не получилось».
    var color: NSColor = DICTATION_HUD_HALO_COLOR { didSet { needsDisplay = true } }
    /// Сила свечения 0…1. У вспышки её ведёт один короткий всплеск, а не
    /// мерцание: мерцающий красный читался бы аварийной сигнализацией.
    var strength: CGFloat = 1 { didSet { needsDisplay = true } }
    /// Мерцать или гореть ровно.
    var shimmers = true

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard target.width > 4, target.height > 4, strength > 0.004 else { return }
        // Мерцание вокруг единицы, а не от нуля: ореол не гаснет совсем,
        // иначе метка режима пропадала бы на половине кадров.
        let base: CGFloat = (reduceMotion || !shimmers)
            ? 0.86
            : 0.72 + (0.28 * ((sin(phase * 1.1) + 1) / 2))
        let shimmer = base * strength
        for layer in DICTATION_HUD_HALO_LAYERS {
            // Слой шире - и рисуется НАРУЖУ: путь раздувается на половину
            // толщины, поэтому свет уходит от кромки, а не внутрь стекла.
            let grow = layer.width / 2
            let rect = target.insetBy(dx: -grow, dy: -grow)
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: cornerRadius + grow,
                                    yRadius: cornerRadius + grow)
            path.lineWidth = layer.width
            color.withAlphaComponent(layer.alpha * shimmer).setStroke()
            path.stroke()
        }
    }
}

@available(macOS 26.0, *)
@MainActor
final class DictationHUDGlassStack: NSView {
    private let container = NSGlassEffectContainerView()
    private let body = NSGlassEffectView()
    private let host = NSView()

    /// Вид, который живёт ВНУТРИ тела: лента рисуется в стекле, а не под ним.
    /// Стекло тогда преломляет её вместе с чужим окном позади, и это ровно то,
    /// чего не даёт никакая накладка поверх.
    var bodyContent: NSView? {
        didSet {
            bodyContent?.wantsLayer = true
            bodyContent?.layer?.masksToBounds = true
            // Вид узнаёт, что живёт внутри стекла, ЗДЕСЬ - в единственном
            // месте, где этот факт становится правдой. Флаг существовал, но
            // не присваивался нигде: живой веткой всегда была та, что рисует
            // собственную квадратную плиту исхода внутри круглого стекла.
            (bodyContent as? DictationHUDCapsuleView)?.hostedInGlass = true
            body.contentView = bodyContent
            needsLayout = true
        }
    }

    private let halo = DictationHUDHaloView()
    /// Мерцающий ореол вокруг тела: метка промпт-режима.
    var showsHalo = false {
        didSet { halo.isHidden = !showsHalo; needsLayout = true }
    }
    var haloPhase: CGFloat = 0 {
        didSet { halo.phase = haloPhase; if showsHalo { halo.needsDisplay = true } }
    }
    /// Постоянное свечение по контуру - метка режима. Слова владельца
    /// 04.09.2026 про золото: «недостаточно волшебства... может быть, ещё
    /// золотое свечение по контуру». Ореол для этого и был написан, но до сих
    /// пор его зажигала только вспышка исхода, и режим по контуру не светил
    /// вовсе.
    private var modeColor: NSColor = DICTATION_HUD_HALO_COLOR
    private var modeStrength: CGFloat = 0
    /// Вспышка за плашкой. Слова владельца: «за самой плашкой тоже красная,
    /// моргание одно, что не получилось». Одно, а не мигалка.
    private var flashColor: NSColor = DICTATION_HUD_HALO_COLOR
    private var flashStrength: CGFloat = 0

    func modeGlow(_ color: NSColor, strength: CGFloat) {
        modeColor = color
        modeStrength = max(0, strength)
        applyHalo()
    }

    func flash(_ color: NSColor, strength: CGFloat) {
        flashColor = color
        flashStrength = max(0, strength)
        applyHalo()
    }

    /// Вспышка старше метки режима: когда что-то случилось, владельцу важно
    /// ЭТО, а не то, в каком режиме случилось. Погаснув, вспышка возвращает
    /// контур режиму, а не гасит его совсем.
    private func applyHalo() {
        let flashing = flashStrength > 0.004
        halo.color = flashing ? flashColor : modeColor
        halo.strength = flashing ? flashStrength : modeStrength
        halo.shimmers = !flashing
        showsHalo = halo.strength > 0.004
    }

    private var shape: DictationHUDGlassShape

    override init(frame frameRect: NSRect) {
        shape = dictationHUDGlassShape(form: .listening, in: frameRect.size)
        super.init(frame: frameRect)
        wantsLayer = true

        body.style = .regular
        host.addSubview(body)
        container.contentView = host
        addSubview(container)
        halo.isHidden = true
        addSubview(halo)
        apply(shape, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override var isFlipped: Bool { false }
    /// Стекло не участвует в попадании мыши: жесты ловит контейнер панели,
    /// и разделение обязано остаться прежним - иначе перетаскивание сломается.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        halo.frame = bounds
        container.frame = bounds
        host.frame = bounds
        apply(shape, animated: false)
    }

    /// Ставит форму. `animated` ведёт перетекание пружиной; выключенное
    /// движение («Уменьшение движения») даёт мгновенный снап - ровно так же
    /// поступает Wispr Flow в боковых доках, и это правильное поведение:
    /// уменьшенная анимация значит меньше движения, а не другой интерфейс.
    func apply(_ next: DictationHUDGlassShape, animated: Bool) {
        shape = next
        let place = {
            self.body.frame = next.body
            self.body.cornerRadius = next.bodyRadius
            // Содержимое обязано жить ВНУТРИ своего стекла и обрезаться по
            // нему: иначе волна вылезает за тело и заезжает на соседнюю каплю.
            // Поймано первым же живым кадром исхода «не доехало».
            self.bodyContent?.frame = CGRect(origin: .zero, size: next.body.size)
            self.halo.target = next.body
            self.halo.cornerRadius = next.bodyRadius
        }
        guard animated else { place(); return }
        NSAnimationContext.runAnimationGroup { context in
            // Пружина Apple: короткая и с малым отскоком. Больше отскока -
            // и плашка начинает выглядеть игрушкой, а она сообщает о работе.
            context.duration = DICTATION_HUD_GLASS_MORPH_SECONDS
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            context.allowsImplicitAnimation = true
            place()
        }
    }

    func tint(_ color: NSColor?) {
        body.tintColor = color
    }
}

/// Длительность перетекания. Держится под потолком в 300 мс для интерфейсной
/// анимации: 420 мс тут читались бы вялыми, а плашка появляется по нажатию
/// клавиши и обязана отвечать сразу.
let DICTATION_HUD_GLASS_MORPH_SECONDS: TimeInterval = 0.26

/// Скорость укладывания волны в линию и обратно, доли в секунду.
/// Подъём быстрее спада: голос обязан подхватываться сразу.
let DICTATION_HUD_COLLAPSE_RISE_RATE: CGFloat = 9.0

let DICTATION_HUD_COLLAPSE_FALL_RATE: CGFloat = 3.2

/// Сколько живёт вспышка исхода.
let DICTATION_HUD_FLASH_SECONDS: TimeInterval = 0.62
