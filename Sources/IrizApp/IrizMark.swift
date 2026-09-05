// Знак iriz в строке меню: волна продукта, при записи - с точкой записи.
//
// История этого холста - история попыток навалить на 18 pt слишком много.
// Сначала он нёс каретку и букву раскладки; владелец снял букву: «рядом есть
// отображение системное». Потом гору семьи с волной над ней, потом гору с
// волной внутри - и владелец остановил: «наверное, с горой на плашке сверху мы
// перемудрили... как будто бы мы можем реально усложнять».
//
// Он прав. Глиф 18 pt обязан делать ДВЕ вещи: сказать «приложение здесь» и
// сказать «идёт запись». Гора - ландшафт: на этом размере она вырождается в
// треугольник и опознаётся хуже, чем волна, которая и так язык продукта - она
// на значке, она в плашке. Личность несёт значок приложения в доке, где у него
// 128 pt и мрамор; здесь хватает волны.
//
// Сетка 100×100, начало в левом верхнем углу, ось Y ВНИЗ.
import AppKit

/// Аварийное состояние: каретка заменяется «!», нагрузка гаснет до 40 %.
enum MarkAlarm: String, Hashable {
    case none
    case noPermission
}

/// Режим, отображаемый знаком. Список режимов меню совпадает с состояниями
/// знака один в один (VISUAL_SPEC §6.3). dictating в меню нет — он побеждает
/// любой режим, пока идёт речь (конфликт «диктовка + раскладка», §4).
enum MarkMode: String, Hashable {
    case fixing     // исправляет: буква 100 %, каретка 100 %
    case shadow     // только считает: буква 100 %, каретка 40 %
    case paused     // пауза: буква 40 %, каретка 40 %
    case dictating  // диктовка: волна 100 %, каретка 100 %
}

/// Полное состояние знака: нагрузка + альфа двух зон + авария (VISUAL_SPEC §4).
struct MarkState: Hashable {
    var mode: MarkMode
    var alarm: MarkAlarm
    /// Фаза волны диктовки в радианах (анимация §4 — сдвиг фазы геометрии).
    /// Не «состояние» в смысле §4, а кадр единственной анимации продукта;
    /// квантуется IrizMark.wavePhase(at:), чтобы кэш образов был конечным.
    /// При mode != .dictating всегда 0.
    var wavePhase: CGFloat = 0

    /// Волна. При аварии НЕ гаснет: ровная линия и есть сигнал «не звучит»,
    /// и гасить её до сорока процентов значит прятать сообщение. Прежде здесь
    /// гасла буква раскладки, а кричала каретка «!» - каретки больше нет.
    var payloadAlpha: CGFloat { mode == .paused ? 0.4 : 1.0 }
    var caretAlpha: CGFloat {
        if alarm == .noPermission { return 1.0 }   // «!» рисуется полной плотностью
        return (mode == .shadow || mode == .paused) ? 0.4 : 1.0
    }
}

enum IrizMark {
    /// Холст знака — 18×18 pt во ВСЕХ состояниях: ширина статус-элемента
    /// не меняется при переключении, соседи в строке меню не дёргаются (§2.8).
    static let canvasPoints: CGFloat = 18

    // Толщины штрихов в единицах сетки (§2.1). Единого веса нет: горизонталь
    // и кривые оптически тяжелее вертикали, поэтому тоньше.
    private static let wVertical: CGFloat = 9.0   // вертикали, диагонали, ширина каретки
    private static let wCrossbar: CGFloat = 8.2   // перекладина A (−9 %)
    private static let wCurve: CGFloat = 8.5      // чаша Ф, волна (−5,5 %)

    // MARK: - Анимация волны (§4: ровно одна на весь продукт)

    /// Период фазового сдвига волны — 1,2 с, линейно, бесконечно.
    static let wavePeriod: TimeInterval = 1.2
    /// Кадров сдвига за период: фаза квантуется, иначе кэш statusImage
    /// разрастался бы по образу на каждый тик таймера.
    static let waveFramesPerPeriod = 24

    /// Линейная фаза 0…2π от времени (секунды), квантованная по кадрам периода.
    /// Один и тот же кадр всегда даёт бит-в-бит то же значение — ключ кэша стабилен.
    static func wavePhase(at time: TimeInterval) -> CGFloat {
        let frame = (time / wavePeriod * Double(waveFramesPerPeriod)).rounded(.down)
            .truncatingRemainder(dividingBy: Double(waveFramesPerPeriod))
        return CGFloat(frame) / CGFloat(waveFramesPerPeriod) * 2 * .pi
    }

    /// «Уменьшение движения» включено → анимации нет, волна статична (§4):
    /// нагрузка и так другая, этого достаточно для отличия. API с macOS 14;
    /// на 13 предпочитаем честную статику не проверять, чем читать недокументированное.
    static var reduceMotionEnabled: Bool {
        if #available(macOS 14, *) {
            return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        return false
    }

    // MARK: - Геометрия

    /// Обе фигуры знака под ЗАЛИВКУ (уже расконтуренные и объединённые union —
    /// иначе пересечение стойки и чаши Ф при альфе 40 % дало бы тёмное пятно, §3.2).
    /// rect — в системе координат с осью Y вниз (flipped NSImage / SwiftUI).
    /// deviceScale — пикселей устройства на пункт (для пиксельной привязки каретки).
    /// phase — фаза волны диктовки (анимация сдвигом фазы, §4); для статики 0.
    static func paths(state: MarkState, phase: CGFloat = 0, in rect: CGRect,
                      deviceScale: CGFloat = 2) -> (payload: CGPath, caret: CGPath) {
        let u = rect.width / 100
        var t = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: u, y: u)
        _ = deviceScale
        let wave = wavePath(state: state, phase: phase, transform: t)
        return (wave, recordingDotPath(state: state, transform: &t))
    }

    /// Отрисовка состояния в контекст с осью Y вниз: волна и гора -
    /// раздельные заливки, каждая со своей альфой.
    static func draw(state: MarkState, phase: CGFloat = 0, in rect: CGRect,
                     context ctx: CGContext, color: NSColor = .black) {
        // Пикселей устройства на пункт — из CTM контекста (2 на Retina, 1 при
        // растровом рендере 1 px = 1 pt).
        let deviceScale = max(1, abs(ctx.ctm.a))
        let (payload, caret) = paths(state: state, phase: phase, in: rect, deviceScale: deviceScale)

        // Волна и точка записи - одна заливка: точка не спорит с волной ни
        // цветом, ни плотностью, она просто ещё один элемент того же знака.
        //
        // Прежде запись рисовалась отдельной залитой плашкой: спека §2.6 просила
        // тихой волны, владелец возразил живьём - «я не вижу, когда работает
        // запись», и плашка появилась. Она решала видимость, но 04.09.2026
        // владелец отверг и её: «когда появляется непонятное белое выделение,
        // это херня... пусть будет гора и просто волны, или большая гора и
        // внутри горы волны, там же мало места под значок».
        //
        // Крупная гора с выбитой внутри волной закрывает обе претензии сразу:
        // чернил на холсте больше, чем было у горы с волной над ней, поэтому
        // знак виден периферийным зрением, а видимость записи держит анимация
        // волны, а не белый прямоугольник в строке меню.
        let mark = CGMutablePath()
        mark.addPath(caret)
        mark.addPath(payload)
        ctx.setFillColor(color.withAlphaComponent(state.payloadAlpha).cgColor)
        ctx.addPath(mark)
        ctx.fillPath(using: .evenOdd)
    }

    /// Гора семьи - постоянная часть знака, как прежде была каретка. Тот же
    /// Олимп, что на значке приложения: широкий щит с плоской вершиной и
    /// вырезом кальдеры. Форма упрощена до восьми точек - на холсте 18 pt
    /// подробности профиля всё равно не переживают растр, а плоская вершина
    /// с укусом переживает.
    /// Точка записи - единственная добавка к волне, и только на записи.
    /// Прежде запись показывала себя залитой плашкой во весь холст: она решала
    /// видимость, но владелец отверг её живьём («непонятное белое выделение»).
    /// Точка говорит то же самое одним элементом и не спорит с волной.
    private static func recordingDotPath(state: MarkState,
                                         transform t: inout CGAffineTransform) -> CGPath {
        let path = CGMutablePath()
        guard state.mode == .dictating else { return path }
        let side: CGFloat = 16
        path.addEllipse(in: CGRect(x: 4, y: 50 - side / 2, width: side, height: side))
        return path.copy(using: &t) ?? path
    }

    /// Волна: пять столбиков, высокие в середине, к краям садятся. Та же
    /// грамматика, что у плашки и у значка приложения - один продукт говорит
    /// одним языком.
    ///
    /// При потере разрешений волна ложится в ОДНУ ровную линию: тот же язык,
    /// каким плашка показывает обрыв. Линия вместо волны значит «не звучит».
    private static func wavePath(state: MarkState, phase: CGFloat,
                                 transform: CGAffineTransform) -> CGPath {
        var t = transform
        let path = CGMutablePath()
        let width: CGFloat = 11
        let centre: CGFloat = 50
        // На записи волна уступает место точке слева: иначе точка наезжает на
        // первый столбик и оба перестают читаться.
        let left: CGFloat = state.mode == .dictating ? 28 : 12
        let right: CGFloat = 88

        if state.alarm == .noPermission {
            path.addRoundedRect(
                in: CGRect(x: left, y: centre - width / 2, width: right - left, height: width),
                cornerWidth: width / 2, cornerHeight: width / 2
            )
            return path.copy(using: &t) ?? path
        }

        let count = state.mode == .dictating ? 4 : 5
        let span = right - left
        let step = (span - width) / CGFloat(count - 1)
        for index in 0..<count {
            let position = CGFloat(index)
            let envelope = 0.42 + 0.58 * sin(.pi * (position + 0.5) / CGFloat(count))
            let animated = state.mode == .dictating
                ? 0.55 + 0.45 * sin(phase + position * 1.15)
                : 1.0
            let height = max(width * 1.6, 78 * envelope * animated)
            let x = left + position * step
            path.addRoundedRect(
                in: CGRect(x: x, y: centre - height / 2, width: width, height: height),
                cornerWidth: width / 2, cornerHeight: width / 2
            )
        }
        return path.copy(using: &t) ?? path
    }

    /// Кубическая Безье как четвёрка точек (начало, контроль1, контроль2, конец).
    private typealias Cubic = (p0: CGPoint, c1: CGPoint, c2: CGPoint, p3: CGPoint)

    /// Волна строго по §2.6 — контрольные точки даны буквально:
    ///   M (34, 49) C (42.33, 21) (50.67, 21) (59, 49)    гребень y = 28
    ///              C (67.33, 77) (75.67, 77) (84, 49)    впадина y = 70
    /// (25/3 = 8,33…; контрольные на 49 ∓ 28 = 49 ∓ 4/3·амплитуды, поэтому
    /// кривая достигает ровно y = 28 и y = 70).
    ///
    /// Волна периодична с периодом 50 единиц, а окно слота — ровно один период,
    /// поэтому фаза φ — это честный сдвиг той же кривой вдоль x на 25φ/π единиц
    /// (анимация §4: фазовый сдвиг геометрии, период 1,2 с). В произвольной фазе
    /// окно [34, 84] заполняют те же полуволны, а граничные куски отсекаются
    /// де Кастельжо — при φ = 0 путь совпадает со спекой точь-в-точь.
    private static func waveCenterline(phase: CGFloat) -> CGPath {
        let shift = (25 * phase / .pi).truncatingRemainder(dividingBy: 50)
        let s = shift < 0 ? shift + 50 : shift
        // Нулевые пересечения средней линии сдвинутой волны: x = 34 + s + 25k.
        // Чётная полуволна — гребень (контрольные на y = 21), нечётная — впадина (77).
        var curves: [Cubic] = []
        for k in -2...2 {
            let x0 = 34 + s + 25 * CGFloat(k)
            guard x0 + 25 > 34, x0 < 84 else { continue }
            let controlY: CGFloat = (k & 1) == 0 ? 21 : 77
            let cubic: Cubic = (CGPoint(x: x0, y: 49),
                                CGPoint(x: x0 + 25.0 / 3.0, y: controlY),
                                CGPoint(x: x0 + 50.0 / 3.0, y: controlY),
                                CGPoint(x: x0 + 25, y: 49))
            let t0 = max(0, (34 - x0) / 25)
            let t1 = min(1, (84 - x0) / 25)
            guard t1 > t0 else { continue }
            curves.append(subcubic(cubic, from: t0, to: t1))
        }
        let path = CGMutablePath()
        if let first = curves.first {
            path.move(to: first.p0)
            for cubic in curves {
                path.addCurve(to: cubic.p3, control1: cubic.c1, control2: cubic.c2)
            }
        }
        return path
    }

    /// Под-кривая кубической на [t0, t1]: разбиение де Кастельжо в t1, затем
    /// левая часть — в t0/t1. При t0 = 0 и t1 = 1 возвращает исходную кривую.
    private static func subcubic(_ c: Cubic, from t0: CGFloat, to t1: CGFloat) -> Cubic {
        let (left, _) = splitCubic(c, at: t1)
        let (_, right) = splitCubic(left, at: t0 / t1)
        return right
    }

    /// Разбиение де Кастельжо кубической в точке t на левую и правую кубические.
    private static func splitCubic(_ c: Cubic, at t: CGFloat) -> (Cubic, Cubic) {
        func lerp(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let p01 = lerp(c.p0, c.c1), p12 = lerp(c.c1, c.c2), p23 = lerp(c.c2, c.p3)
        let p012 = lerp(p01, p12), p123 = lerp(p12, p23)
        let p0123 = lerp(p012, p123)
        return ((c.p0, p01, p012, p0123), (p0123, p123, p23, c.p3))
    }

    // MARK: - Строка меню

    /// Кэш: 6 состояний × template-образ, плюс до waveFramesPerPeriod кадров
    /// волны во время диктовки (фаза квантована — множество ключей конечно).
    /// Знак НЕ перерисовывается на каждое нажатие клавиши (§8) — NSImage
    /// строится лениво один раз на состояние.
    @MainActor private static var imageCache: [MarkState: NSImage] = [:]

    /// Template-образ 18×18 pt для статус-элемента. Система сама красит его под
    /// тему и тонировку строки меню; собственных цветов в маске нет (§3.3).
    /// Фаза волны берётся из state.wavePhase — анимация крутится сменой кадра
    /// геометрии, не поворотом и не масштабом готовой картинки (§4).
    @MainActor
    static func statusImage(state: MarkState) -> NSImage {
        if let cached = imageCache[state] { return cached }
        let image = NSImage(size: NSSize(width: canvasPoints, height: canvasPoints), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(state: state, phase: state.wavePhase, in: rect, context: ctx)
            return true
        }
        image.isTemplate = true
        imageCache[state] = image
        return image
    }

    // MARK: - Иконка приложения

    /// Иконка приложения: дуга Ириды над Олимпом Марсианским.
    ///
    /// Знак строки меню сюда не переносится, и это решение, а не лень. У него
    /// холст 18 pt и он обязан нести раскладку буквой; у иконки холст 1024, и
    /// требовать от одной формы работать в обоих размерах значит испортить обе.
    /// Разбор того же класса ошибки - в `VISUAL_SPEC.md` §7, где клавиатура
    /// проиграла именно по этой причине.
    ///
    /// Что нарисовано и почему:
    ///
    /// - **Дуга** - Ирида: в мифе она радуга и вестница, то есть та, кто
    ///   доносит сказанное. Для приложения, превращающего речь в текст, это
    ///   не украшение, а прямое имя занятия.
    /// - **Щит горы** - Олимп Марсианский, решение владельца 03.09.2026 в
    ///   канон семьи: широкий пологий силуэт, а не остроконечный пик, с
    ///   кальдерой на вершине и резким уступом по подножию.
    /// - Фон и знак плоские. Скругление, маску и блики добавляет система:
    ///   запечённые тени дадут двойной рельеф.
    static func iconImage(pixels: Int) -> NSImage {
        let n = CGFloat(pixels)
        return NSImage(size: NSSize(width: n, height: n), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = n / 1024

            ctx.setFillColor(IRIZ_ICON_BACKGROUND.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 100 * s, y: 100 * s,
                                                   width: 824 * s, height: 824 * s),
                               cornerWidth: 184 * s, cornerHeight: 184 * s, transform: nil))
            ctx.fillPath()

            drawIridaArc(in: ctx, scale: s)
            drawOlympusShield(in: ctx, scale: s)
            return true
        }
    }

    /// Дуга Ириды: широкая радуга над горой, одной сплошной лентой.
    private static func drawIridaArc(in ctx: CGContext, scale s: CGFloat) {
        let centre = CGPoint(x: 512 * s, y: 372 * s)
        let outer: CGFloat = 306 * s
        let band: CGFloat = 58 * s
        let path = CGMutablePath()
        path.addArc(center: centre, radius: outer, startAngle: 0, endAngle: .pi,
                    clockwise: false)
        path.addArc(center: centre, radius: outer - band, startAngle: .pi, endAngle: 0,
                    clockwise: true)
        path.closeSubpath()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }

    /// Щит Олимпа Марсианского: ширина главнее высоты, на вершине кальдера,
    /// у подножия уступ. Треугольного пика здесь не бывает - именно этим
    /// силуэт и опознаётся.
    private static func drawOlympusShield(in ctx: CGContext, scale s: CGFloat) {
        // Щит, а не пик: ширина 520 при высоте подъёма 112, то есть почти
        // впятеро. Настоящий Olympus Mons ещё площе - 600 км на 22, - и любое
        // приближение к конусу здесь уже ошибка узнавания.
        let base: CGFloat = 356 * s
        let left: CGFloat = 252 * s
        let right: CGFloat = 772 * s
        let peak: CGFloat = 468 * s
        let shield = CGMutablePath()
        shield.move(to: CGPoint(x: left, y: base))
        // Пологие склоны: контрольные точки прижаты к подножию, поэтому масса
        // растекается вширь, а не собирается в конус.
        shield.addCurve(to: CGPoint(x: 512 * s, y: peak),
                        control1: CGPoint(x: 340 * s, y: base + 4 * s),
                        control2: CGPoint(x: 402 * s, y: peak))
        shield.addCurve(to: CGPoint(x: right, y: base),
                        control1: CGPoint(x: 622 * s, y: peak),
                        control2: CGPoint(x: 684 * s, y: base + 4 * s))
        shield.closeSubpath()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(shield)
        ctx.fillPath()

        // Кальдера: вырез фоном, а не вторым цветом - слоя по-прежнему два.
        ctx.setFillColor(IRIZ_ICON_BACKGROUND.cgColor)
        ctx.addPath(CGPath(ellipseIn: CGRect(x: 512 * s - 46 * s, y: peak - 26 * s,
                                             width: 92 * s, height: 26 * s), transform: nil))
        ctx.fillPath()

        // Уступ подножия: чистая линия среза, а не осыпь.
        ctx.setFillColor(IRIZ_ICON_BACKGROUND.cgColor)
        ctx.addPath(CGPath(rect: CGRect(x: left - 30 * s, y: base - 22 * s,
                                        width: (right - left) + 60 * s, height: 13 * s),
                           transform: nil))
        ctx.fillPath()
    }
}

/// Фон иконки. Тот же уголь, что и прежде: иконка семьи тёмная только здесь,
/// потому что знак на ней обязан быть монолитом, а не выцветать на светлом.
let IRIZ_ICON_BACKGROUND = NSColor(calibratedRed: 0x1E / 255, green: 0x1E / 255,
                                    blue: 0x21 / 255, alpha: 1)
