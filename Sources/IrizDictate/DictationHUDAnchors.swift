// Куда примагничивается плашка.
//
// Владелец 06.09.2026: «сделай примагничивание либо ровно в середине снизу…
// сверху то же самое, слева и справа… снизу в трех местах, ровно посередине
// снизу, в левой секции посередине, в правой секции посередине, по бокам то же
// самое в трех местах и сверху в трех местах. Соответственно, если это сбоку
// примагничивание, значит должна быть раскладка боком».
//
// ЗАЧЕМ. Прежде плашка вставала куда попало: перетащил - там и осталась, с
// точностью до пикселя. Владелец сказал прямо, что кнопка от этого работает
// плохо. Двенадцать мест вместо бесконечности решают сразу три беды: плашка
// всегда на краю, а не посреди работы; попасть в неё мышью легко, потому что
// место известно заранее; и она не уезжает за кромку экрана.
import CoreGraphics
import Foundation

/// Край экрана, к которому примагничена плашка.
public enum DictationHUDAnchorEdge: String, Sendable {
    case bottom, top, left, right
}

/// Двенадцать мест: три на каждом крае.
public enum DictationHUDAnchor: String, CaseIterable, Sendable {
    case bottomLeading, bottomCenter, bottomTrailing
    case topLeading, topCenter, topTrailing
    case leftBottom, leftCenter, leftTop
    case rightBottom, rightCenter, rightTop

    public var edge: DictationHUDAnchorEdge {
        switch self {
        case .bottomLeading, .bottomCenter, .bottomTrailing: return .bottom
        case .topLeading, .topCenter, .topTrailing: return .top
        case .leftBottom, .leftCenter, .leftTop: return .left
        case .rightBottom, .rightCenter, .rightTop: return .right
        }
    }

    /// Боком - значит плашка стоит вертикально: ряд кнопок идёт столбиком.
    /// Горизонтальная плашка у левого края съела бы треть ширины экрана.
    public var isVertical: Bool {
        edge == .left || edge == .right
    }

    /// Какая треть края: 0 - ближняя к началу, 2 - к концу.
    public var section: Int {
        switch self {
        case .bottomLeading, .topLeading, .leftBottom, .rightBottom: return 0
        case .bottomCenter, .topCenter, .leftCenter, .rightCenter: return 1
        case .bottomTrailing, .topTrailing, .leftTop, .rightTop: return 2
        }
    }
}

/// Умолчание: середина низа. Там плашка не спорит ни со строкой меню сверху,
/// ни с доком по бокам, и туда же смотрит взгляд, когда ждёшь ответа.
public let DICTATION_HUD_DEFAULT_ANCHOR: DictationHUDAnchor = .bottomCenter

/// Толщина полосы притяжения у края.
public let DICTATION_HUD_ANCHOR_BAND: CGFloat = 160

/// Отступ плашки от кромки экрана.
public let DICTATION_HUD_ANCHOR_MARGIN: CGFloat = 18

/// Зона, которая подсвечивается при переносе. Треть края шириной в полосу.
public func dictationHUDAnchorZone(_ anchor: DictationHUDAnchor,
                                   in visible: CGRect,
                                   band: CGFloat = DICTATION_HUD_ANCHOR_BAND) -> CGRect {
    let band = max(40, min(band, min(visible.width, visible.height) / 2))
    let index = CGFloat(anchor.section)
    switch anchor.edge {
    case .bottom, .top:
        let width = visible.width / 3
        let y = anchor.edge == .bottom ? visible.minY : visible.maxY - band
        return CGRect(x: visible.minX + width * index, y: y, width: width, height: band)
    case .left, .right:
        let height = visible.height / 3
        let x = anchor.edge == .left ? visible.minX : visible.maxX - band
        return CGRect(x: x, y: visible.minY + height * index, width: band, height: height)
    }
}

/// Размер плашки в этом месте: боком она встаёт вертикально.
public func dictationHUDAnchoredSize(_ anchor: DictationHUDAnchor, plate: CGSize) -> CGSize {
    anchor.isVertical ? CGSize(width: plate.height, height: plate.width) : plate
}

/// Куда встанет плашка, примагниченная сюда.
public func dictationHUDAnchoredFrame(_ anchor: DictationHUDAnchor,
                                      plate: CGSize,
                                      in visible: CGRect,
                                      margin: CGFloat = DICTATION_HUD_ANCHOR_MARGIN) -> CGRect {
    let size = dictationHUDAnchoredSize(anchor, plate: plate)
    let zone = dictationHUDAnchorZone(anchor, in: visible)
    let x: CGFloat
    let y: CGFloat
    switch anchor.edge {
    case .bottom:
        x = zone.midX - size.width / 2
        y = visible.minY + margin
    case .top:
        x = zone.midX - size.width / 2
        y = visible.maxY - margin - size.height
    case .left:
        x = visible.minX + margin
        y = zone.midY - size.height / 2
    case .right:
        x = visible.maxX - margin - size.width
        y = zone.midY - size.height / 2
    }
    // Внутрь экрана в любом случае: у узкого экрана зона трети может оказаться
    // уже самой плашки, и середина зоны увела бы её за кромку.
    let clampedX = min(max(x, visible.minX + 2), visible.maxX - size.width - 2)
    let clampedY = min(max(y, visible.minY + 2), visible.maxY - size.height - 2)
    return CGRect(x: clampedX.rounded(), y: clampedY.rounded(),
                  width: size.width, height: size.height)
}

/// Ближайшее место к точке. Считается по центрам зон: точка может лежать сразу
/// в двух зонах (углы перекрываются), и «первая подошедшая» дала бы разный
/// ответ на одну и ту же точку в зависимости от порядка перебора.
public func dictationHUDNearestAnchor(to point: CGPoint,
                                      in visible: CGRect) -> DictationHUDAnchor {
    var best = DICTATION_HUD_DEFAULT_ANCHOR
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for anchor in DictationHUDAnchor.allCases {
        let zone = dictationHUDAnchorZone(anchor, in: visible)
        // Расстояние до КРАЯ зоны, а не до её центра: у нижней середины центр
        // зоны отстоит от края на восемьдесят пунктов, и плашка, брошенная
        // ровно в углу, уезжала бы к середине.
        let anchorPoint = CGPoint(x: zone.midX, y: zone.midY)
        let d = hypot(point.x - anchorPoint.x, point.y - anchorPoint.y)
        if d < bestDistance {
            bestDistance = d
            best = anchor
        }
    }
    return best
}
