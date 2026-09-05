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
