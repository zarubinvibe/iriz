// Размер плашки: выбор владельца, а не наследство.
//
// Прежнее 124,2 x 36,8 pt (248 x 74 физических пикселя на ретине) ничем не
// обосновано: это 108 x 32 донора SuperDictate, умноженные на его же
// `visualScale = 1.15`. Число досталось вместе с кодом и дальше просто
// тянулось. Решение владельца 03.09.2026: размеров три, и он выбирает.
//
// Правило приговора при этом НЕ ослабляется. Оно никогда не держалось на
// числе 248 x 74 - оно держится на «кадр в натуральную величину», а
// натуральная величина у каждого размера своя. Ворота считают её из
// выбранного размера, а не сверяют с константой.
import CoreGraphics
import Foundation

public enum DictationHUDSizeChoice: String, CaseIterable, Sendable {
    case small, medium, large

    public var title: String {
        switch self {
        case .small: return "Малый"
        case .medium: return "Средний"
        case .large: return "Большой"
        }
    }

    /// Множитель к среднему. Средний оставлен единицей намеренно: на нём стоят
    /// все прежние кадры и вся геометрия спеки, и менять его заодно с вводом
    /// выбора значило бы поменять две вещи сразу и не понять, какая подействовала.
    public var scale: CGFloat {
        switch self {
        case .small: return 0.80
        case .medium: return 1.00
        case .large: return 1.30
        }
    }
}

/// Заводской размер.
public let DICTATION_HUD_DEFAULT_SIZE = DictationHUDSizeChoice.medium

/// Базовый размер плашки в пунктах - он же «средний».
public let DICTATION_HUD_BASE_SIZE = CGSize(width: 124.2, height: 36.8)

/// Размер плашки в пунктах для выбранного варианта.
public func dictationHUDCollapsedSize(_ choice: DictationHUDSizeChoice) -> CGSize {
    let s = choice.scale
    return CGSize(width: (DICTATION_HUD_BASE_SIZE.width * s).rounded(),
                  height: (DICTATION_HUD_BASE_SIZE.height * s).rounded())
}

/// Доли рабочего размера, которые занимает плашка в ПОКОЕ.
///
/// Покой обязан быть заметно меньше работы по двум причинам сразу. Первая -
/// смысл: пока владелец не заговорил, плашка не имеет права занимать столько
/// же места, сколько идущая запись. Вторая - цена: постоянное окно ловит мышь
/// всей рамкой (`ignoresMouseEvents = false`), и каждый пункт его площади это
/// пункт, где щелчок не доходит до приложения под ним. Событийная плашка жила
/// секундами и такую цену не брала; постоянная берёт её весь день.
/// Слова владельца 06.09.2026: «как будто бы капелька стекла такая вытянутая
/// с тонкой полоской… эта плашка должна быть уже и по высоте тоже меньше,
/// чтобы она раскрывалась, когда мы наводим на нее мышку». Отсюда и доли:
/// капля вытянутая - ширина падает меньше, чем высота.
let DICTATION_HUD_REST_WIDTH_SHARE: CGFloat = 0.34
let DICTATION_HUD_REST_HEIGHT_SHARE: CGFloat = 0.40

/// Размер плашки в покое для выбранного размера.
public func dictationHUDRestingSize(_ choice: DictationHUDSizeChoice) -> CGSize {
    dictationHUDRestingSize(dictationHUDCollapsedSize(choice))
}

/// То же от готового рабочего размера: морф считает обе стороны от одного числа.
public func dictationHUDRestingSize(_ working: CGSize) -> CGSize {
    CGSize(width: (working.width * DICTATION_HUD_REST_WIDTH_SHARE).rounded(),
           height: (working.height * DICTATION_HUD_REST_HEIGHT_SHARE).rounded())
}

/// Кадр приговора в ФИЗИЧЕСКИХ пикселях для выбранного размера на ретине 2x.
/// Ровно это число и обязаны требовать ворота - своё для каждого размера.
public func dictationHUDVerdictPixelSize(_ choice: DictationHUDSizeChoice,
                                         scale: CGFloat = 2) -> CGSize {
    let points = dictationHUDCollapsedSize(choice)
    return CGSize(width: (points.width * scale).rounded(),
                  height: (points.height * scale).rounded())
}

/// Столбиков в волне для размера. Шаг столбика не растягивается вместе с
/// плашкой: растянутый столбик читается жирной палкой, а не звуком. Растёт
/// ЧИСЛО столбиков - у большой плашки волна подробнее, и это честно: места
/// больше, значит и показать можно больше.
public func dictationHUDBarCount(_ choice: DictationHUDSizeChoice) -> Int {
    let width = dictationHUDCollapsedSize(choice).width
    // Тем же полем, что резервирует РИСОВАНИЕ (drawBars), а не полем стекла.
    // Расхождение было живым дефектом: вместимость считалась по полю 2 pt, а
    // волна рисовалась с полем 9 pt, поэтому два последних столбика из 28
    // получали нулевую прозрачность через edgeFade и волна стояла левее центра.
    let usable = width - (DICTATION_HUD_WAVE_SIDE_INSET * 2)
    let step = DICTATION_HUD_BAR_WIDTH + DICTATION_HUD_BAR_GAP
    return max(8, Int(((usable + DICTATION_HUD_BAR_GAP) / step).rounded(.down)))
}

/// Геометрия плашки: кадр окна и его середина, которая живёт ОТДЕЛЬНО.
///
/// Кадр округляется - окно обязано вставать по пикселю. Середина при этом не
/// имеет права считаться из округлённого кадра: при нечётной стороне половина
/// размера даёт ровно 0,5, округление уносит кадр на пункт, и каждый морф
/// прибавляет этот пункт к прошлому. Владелец увидел накопление живьём
/// 06.09.2026: «после раскрытия плашки и закрытия обратно, она опять съезжает
/// куда-то вправо».
///
/// Отсюда устройство: середина - наземная правда, кадр - её округлённое
/// изображение. Морф двигает только размер, середина остаётся той же цифрой,
/// и десять циклов подряд возвращают ТОТ ЖЕ кадр.
public struct DictationHUDPlateGeometry: Equatable, Sendable {
    /// Кадр, которым живёт окно.
    public private(set) var frame: CGRect
    /// Середина, от которой считается любой морф. Не округляется никогда.
    public private(set) var center: CGPoint

    public init(frame: CGRect = CGRect(origin: .zero, size: DICTATION_HUD_BASE_SIZE)) {
        self.frame = frame
        self.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Кадр задан снаружи: перетаскивание, притяжение к месту, поправка экрана.
    /// Середина переезжает вместе с ним - это новое место, а не морф.
    public mutating func setFrame(_ frame: CGRect) {
        self.frame = frame
        self.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Поменять размер, НЕ сдвигая середину.
    public mutating func setSize(_ size: CGSize) {
        frame = CGRect(x: (center.x - size.width / 2).rounded(),
                       y: (center.y - size.height / 2).rounded(),
                       width: size.width,
                       height: size.height)
    }
}
