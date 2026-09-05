// Свои значки, нарисованные вектором.
//
// Системные глифы SF - чужой набор: они узнаваемы как деталь macOS, а не как
// лицо продукта, и владелец сказал об этом прямо. Здесь двенадцать фигур на
// одной сетке 24 на 24, одной толщиной штриха и с одинаковым скруглением. Это
// и делает их набором, а не двенадцатью отдельными картинками.
//
// Штрих, а не заливка: заливка на 16 пунктах превращается в пятно, а штрих
// держит форму и на боковике, и на кнопке.
import SwiftUI

/// Толщина штриха. Одна на весь набор: разнобой толщин виден сразу, даже когда
/// сами фигуры хороши.
public let IRIZ_GLYPH_STROKE: CGFloat = 1.6

public enum IrizGlyph: String, CaseIterable, Sendable {
    case language, keys, layout, dictation, plate, dictionary
    case snippets, prompt, transfer, disk, files, meetings, history
}

/// Значок набора. Рисуется на сетке 24 на 24 и масштабируется под место.
public struct IrizGlyphView: View {
    public let glyph: IrizGlyph
    public var size: CGFloat = 17

    public init(_ glyph: IrizGlyph, size: CGFloat = 17) {
        self.glyph = glyph
        self.size = size
    }

    public var body: some View {
        IrizGlyphShape(glyph: glyph)
            .stroke(style: StrokeStyle(lineWidth: IRIZ_GLYPH_STROKE * (size / 24) * 1.4,
                                       lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Геометрия набора. Все фигуры живут в одном месте: значок, нарисованный в
/// своей вьюхе, через месяц отличается от остальных на пиксель.
public struct IrizGlyphShape: Shape {
    public let glyph: IrizGlyph

    public init(glyph: IrizGlyph) { self.glyph = glyph }

    public func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * k, y: rect.minY + y * k)
        }
        var path = Path()

        switch glyph {
        case .language:
            // Буква одного письма и знак другого. Стрелка убрана: на
            // шестнадцати пунктах она склеивала обе фигуры в одну кляксу, и
            // получался человечек. Двух разных знаков рядом достаточно.
            path.move(to: p(2, 16)); path.addLine(to: p(6.5, 5.5)); path.addLine(to: p(11, 16))
            path.move(to: p(3.6, 12.6)); path.addLine(to: p(9.4, 12.6))
            path.addRect(CGRect(x: rect.minX + 13.5 * k, y: rect.minY + 7 * k,
                                width: 8 * k, height: 8 * k))
            path.move(to: p(17.5, 4.5)); path.addLine(to: p(17.5, 18))
            path.move(to: p(13.5, 11)); path.addLine(to: p(21.5, 11))
        case .keys:
            // Каменный колпачок с бороздой и стрелка над ним: нажми эту.
            path.move(to: p(12, 2)); path.addLine(to: p(12, 6.5))
            path.move(to: p(9.5, 4.5)); path.addLine(to: p(12, 7)); path.addLine(to: p(14.5, 4.5))
            path.addRoundedRect(in: CGRect(x: rect.minX + 4 * k, y: rect.minY + 10 * k,
                                           width: 16 * k, height: 11 * k),
                                cornerSize: CGSize(width: 2.5 * k, height: 2.5 * k))
            path.move(to: p(7.5, 17.5)); path.addLine(to: p(16.5, 17.5))
        case .layout:
            // Две клавиши и двусторонняя стрелка: смена раскладки как обмен.
            path.addRoundedRect(in: CGRect(x: rect.minX + 2.5 * k, y: rect.minY + 6 * k,
                                           width: 8 * k, height: 8 * k),
                                cornerSize: CGSize(width: 2 * k, height: 2 * k))
            path.addRoundedRect(in: CGRect(x: rect.minX + 13.5 * k, y: rect.minY + 6 * k,
                                           width: 8 * k, height: 8 * k),
                                cornerSize: CGSize(width: 2 * k, height: 2 * k))
            path.move(to: p(4, 19)); path.addLine(to: p(20, 19))
            path.move(to: p(6, 17)); path.addLine(to: p(4, 19)); path.addLine(to: p(6, 21))
            path.move(to: p(18, 17)); path.addLine(to: p(20, 19)); path.addLine(to: p(18, 21))

        case .dictation:
            // Две крупные дуги голоса и две строки текста. Трех дуг на
            // шестнадцати пунктах не видно: они сливаются в скобку.
            path.move(to: p(4.5, 8)); path.addQuadCurve(to: p(4.5, 16), control: p(9, 12))
            path.move(to: p(8, 6)); path.addQuadCurve(to: p(8, 18), control: p(14, 12))
            path.move(to: p(14.5, 9.5)); path.addLine(to: p(21.5, 9.5))
            path.move(to: p(14.5, 14.5)); path.addLine(to: p(19, 14.5))
        case .plate:
            // Сама плашка продукта: скругленная табличка с лентой голоса
            // внутри и хвостиком вниз. Дуга НАД табличкой слипалась с ней в
            // ковш - проверено на листе значков дважды.
            path.addRoundedRect(in: CGRect(x: rect.minX + 2.5 * k, y: rect.minY + 6 * k,
                                           width: 19 * k, height: 10 * k),
                                cornerSize: CGSize(width: 3 * k, height: 3 * k))
            for (i, h) in [3.0, 6.0, 4.0].enumerated() {
                let x = 8.5 + CGFloat(i) * 3.5
                path.move(to: p(x, 11 - CGFloat(h) / 2))
                path.addLine(to: p(x, 11 + CGFloat(h) / 2))
            }
            path.move(to: p(9.5, 16)); path.addLine(to: p(12, 20)); path.addLine(to: p(14.5, 16))
        case .dictionary:
            // Две таблички одна под другой: верхняя перечеркнута, нижняя
            // чистая. Замена слова, а не «стрелка сквозь строки».
            path.addRoundedRect(in: CGRect(x: rect.minX + 3 * k, y: rect.minY + 3 * k,
                                           width: 18 * k, height: 7 * k),
                                cornerSize: CGSize(width: 2 * k, height: 2 * k))
            path.move(to: p(4, 10.5)); path.addLine(to: p(20, 2.5))
            path.addRoundedRect(in: CGRect(x: rect.minX + 3 * k, y: rect.minY + 14 * k,
                                           width: 18 * k, height: 7 * k),
                                cornerSize: CGSize(width: 2 * k, height: 2 * k))
            path.move(to: p(6.5, 17.5)); path.addLine(to: p(17.5, 17.5))
        case .history:
            // Циферблат со стрелкой назад: список прошлых надиктовок. Не
            // «список строк» - строки уже заняты словарём и заготовками, и
            // третий список из строк не отличить от них на 16 pt.
            path.addEllipse(in: CGRect(x: rect.minX + 3.5 * k, y: rect.minY + 3.5 * k,
                                       width: 17 * k, height: 17 * k))
            path.move(to: p(12, 7.5)); path.addLine(to: p(12, 12)); path.addLine(to: p(15.5, 14))
            // Хвостик стрелки против часовой: время идёт назад, а не вперёд.
            path.move(to: p(5.5, 8)); path.addLine(to: p(4, 4.5))
            path.move(to: p(5.5, 8)); path.addLine(to: p(9, 6.8))
        case .snippets:
            // Короткая табличка, стрелка и длинные строки: заготовка
            // разворачивается. Свиток тут читался буквой C.
            path.addRoundedRect(in: CGRect(x: rect.minX + 2 * k, y: rect.minY + 9 * k,
                                           width: 6 * k, height: 6 * k),
                                cornerSize: CGSize(width: 1.5 * k, height: 1.5 * k))
            path.move(to: p(9.5, 12)); path.addLine(to: p(13, 12))
            path.move(to: p(11.5, 10)); path.addLine(to: p(13.5, 12)); path.addLine(to: p(11.5, 14))
            path.move(to: p(15.5, 7.5)); path.addLine(to: p(21.5, 7.5))
            path.move(to: p(15.5, 12)); path.addLine(to: p(21.5, 12))
            path.move(to: p(15.5, 16.5)); path.addLine(to: p(19.5, 16.5))
        case .prompt:
            // Стрелка входит в табличку с двумя строками: сказанное вернулось
            // готовым заданием. Искра над табличкой читалась как крышка на
            // бутылке, поэтому она внутри и мелкая.
            path.move(to: p(1.5, 12)); path.addLine(to: p(6.5, 12))
            path.move(to: p(4.6, 9.9)); path.addLine(to: p(6.7, 12)); path.addLine(to: p(4.6, 14.1))
            path.addRoundedRect(in: CGRect(x: rect.minX + 9 * k, y: rect.minY + 4.5 * k,
                                           width: 12.5 * k, height: 15 * k),
                                cornerSize: CGSize(width: 2.5 * k, height: 2.5 * k))
            path.move(to: p(12, 12)); path.addLine(to: p(18.5, 12))
            path.move(to: p(12, 16)); path.addLine(to: p(16, 16))
            path.move(to: p(15.25, 6.5)); path.addLine(to: p(15.25, 9.5))
            path.move(to: p(13.75, 8)); path.addLine(to: p(16.75, 8))
        case .transfer:
            // Стрелка ложится на постамент: принесенное встает на место.
            path.move(to: p(12, 3)); path.addLine(to: p(12, 12.5))
            path.move(to: p(8.5, 9)); path.addLine(to: p(12, 12.5)); path.addLine(to: p(15.5, 9))
            path.move(to: p(5, 16)); path.addLine(to: p(19, 16))
            path.move(to: p(3, 20)); path.addLine(to: p(21, 20))
        case .disk:
            // Барабаны колонны стопкой, в нижнем - черта уровня: не «хранилище
            // вообще», а сколько занято.
            for (i, y) in [4.5, 10.0, 15.5].enumerated() {
                path.addRoundedRect(in: CGRect(x: rect.minX + (4 + CGFloat(i) * 0.6) * k,
                                               y: rect.minY + CGFloat(y) * k,
                                               width: (16 - CGFloat(i) * 1.2) * k,
                                               height: 4 * k),
                                    cornerSize: CGSize(width: 1.2 * k, height: 1.2 * k))
            }
            path.move(to: p(6.5, 17.5)); path.addLine(to: p(13, 17.5))
        case .files:
            // Лист с ТРЕМЯ крупными столбиками волны и строкой под ними.
            // Четыре тонких столбика на шестнадцати пунктах читались шумом.
            path.move(to: p(5.5, 3)); path.addLine(to: p(14, 3)); path.addLine(to: p(18.5, 7.5))
            path.addLine(to: p(18.5, 21)); path.addLine(to: p(5.5, 21)); path.closeSubpath()
            path.move(to: p(14, 3)); path.addLine(to: p(14, 7.5)); path.addLine(to: p(18.5, 7.5))
            for (i, h) in [3.5, 7.0, 4.5].enumerated() {
                let x = 9 + CGFloat(i) * 3
                path.move(to: p(x, 13 - CGFloat(h) / 2))
                path.addLine(to: p(x, 13 + CGFloat(h) / 2))
            }
            path.move(to: p(8.5, 18)); path.addLine(to: p(15.5, 18))
        case .meetings:
            // Стол и трое вокруг: встреча это несколько человек, а не микрофон.
            // Микрофон читается как «запись», и на листе значков он именно так
            // и прочитался.
            path.addEllipse(in: CGRect(x: rect.minX + 7 * k, y: rect.minY + 9.5 * k,
                                       width: 10 * k, height: 6 * k))
            path.addEllipse(in: CGRect(x: rect.minX + 10 * k, y: rect.minY + 2.5 * k,
                                       width: 4 * k, height: 4 * k))
            path.addEllipse(in: CGRect(x: rect.minX + 2.5 * k, y: rect.minY + 14 * k,
                                       width: 4 * k, height: 4 * k))
            path.addEllipse(in: CGRect(x: rect.minX + 17.5 * k, y: rect.minY + 14 * k,
                                       width: 4 * k, height: 4 * k))
        }
        return path
    }
}
