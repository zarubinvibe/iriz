// Звуковая волна на стекле. Рисование, без решений: что показывать - считает
// `DictationHUDWaveBars.swift`, здесь только пиксели.
//
// Core Graphics, а не Metal, и это осознанно: двадцать восемь скруглённых
// столбиков стоят копейки, а шейдер сюда тащить незачем - его цена была
// оправдана попиксельным свечением ленты, которой больше нет.
import AppKit

@MainActor
final class DictationHUDWaveBarsView: NSView {
    /// Цвет волны. Зелёный - запись идёт, синий - работа продолжается,
    /// красный - оборвалось. Решение владельца: цвет говорит про СОСТОЯНИЕ,
    /// а не про режим; режим по-прежнему различается шевроном, ходом и аурой.
    var tint: NSColor = DICTATION_HUD_WAVE_GREEN
    /// Доли высоты по столбикам, от старого к новому.
    var heights: [CGFloat] = [] { didSet { needsDisplay = true } }
    /// Фаза для тихого дыхания и для бега дуги по стеклу.
    var phase: CGFloat = 0
    /// Уменьшенная анимация: дыхание и бег выключены, голос по-прежнему виден.
    var reduceMotion = false
    /// Что рисовать в теле: звук или знак исхода. Огрызок волны в кружке
    /// ничего не сообщал - успех обязан выглядеть успехом.
    var glyph: DictationHUDWaveGlyph = .wave { didSet { needsDisplay = true } }
    /// Насколько ядро вправе выгорать в белое. Единица - как было; меньше -
    /// ядро держит собственный цвет.
    ///
    /// Зачем вообще ручка. Слои неона подмешивают к ядру до 74% белого, и при
    /// сложении света это даёт белый сердечник со цветным ореолом. Насыщенному
    /// зелёному это идёт, а золото `#C9A87A` само по себе бледное: после 74%
    /// белого от золота не остаётся ничего. Слова владельца 04.09.2026:
    /// «она больше похожа на белую, чем на золотую».
    var coreWhiteScale: CGFloat = 1 { didSet { needsDisplay = true } }
    /// Яркость опорной линии. У покоя она тише, у обрыва - в полную силу:
    /// тишина это не отказ, и гореть одинаково они не имеют права.
    var lineIntensity: CGFloat = 1 { didSet { needsDisplay = true } }
    /// 0 - звук, 1 - ровная черта. Промежуточные значения ведёт анимация:
    /// волна СОБИРАЕТСЯ в линию, а не подменяется ею.
    var collapse: CGFloat = 0 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var allowsVibrancy: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        switch glyph {
        case .wave: drawBars()
        case .check: drawStroke(dictationHUDCheckPoints(in: bounds))
        case .bolt: drawStroke(dictationHUDBoltPoints(in: bounds), closed: true)
        case .cross:
            // Крестик - две отдельные черты, а не ломаная: соединённые в одну
            // линию, они дали бы галочку с хвостом, то есть знак успеха.
            for stroke in dictationHUDCrossStrokes(in: bounds) { drawStroke(stroke) }
        }
    }

    /// Знак исхода тем же неоном, что и волна: это один и тот же свет,
    /// просто принял другую форму.
    ///
    /// `closed` - для молнии: у неё замкнутый контур с заливкой, а не линия.
    private func drawStroke(_ points: [CGPoint], closed: Bool = false) {
        guard points.count > 1 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.compositingOperation = .plusLighter

        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        if closed { path.close() }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        for layer in DICTATION_HUD_NEON_LAYERS {
            let white = layer.white * coreWhiteScale
            let color = white > 0
                ? tint.blended(withFraction: white, of: .white) ?? tint
                : tint
            color.withAlphaComponent(layer.alpha).setStroke()
            path.lineWidth = DICTATION_HUD_CHECK_WIDTH * layer.width
            path.stroke()
            if closed, layer.width <= 1 {
                color.withAlphaComponent(layer.alpha * 0.72).setFill()
                path.fill()
            }
        }
    }

    private func drawBars() {
        guard !heights.isEmpty else { return }
        let c = min(1, max(0, collapse))
        let count = heights.count
        let width = DICTATION_HUD_BAR_WIDTH + (DICTATION_HUD_BAR_GAP * c)
        let step = DICTATION_HUD_BAR_WIDTH + DICTATION_HUD_BAR_GAP
        // Волна не доходит до торцов стекла: по бокам остаётся поле, и через
        // него видно, что ЗА плашкой другой фон. Прежде линия упиралась в
        // кромку, и плашка читалась сплошной, а не стеклянной.
        let usable = bounds.width - (DICTATION_HUD_WAVE_SIDE_INSET * 2)
        let rawTotal = (CGFloat(count - 1) * step) + width
        let total = min(rawTotal, usable)
        let left = bounds.midX - total / 2

        // Края гасятся ГРАДИЕНТОМ, а не обрезкой: обрезанная волна кончается
        // ступенькой, погашенная - растворяется. Приём подсмотрен у живой
        // волны ElevenLabs на 21st.dev; там это маска `destination-out`, здесь
        // проще - множитель альфы по месту столбика.
        func edgeFade(_ x: CGFloat) -> CGFloat {
            let t = (x - left) / max(1, total)
            let d = min(t, 1 - t) / DICTATION_HUD_WAVE_EDGE_FADE
            return min(1, max(0, d))
        }
        let span = (bounds.height / 2) * DICTATION_HUD_WAVE_SPAN_SHARE

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Сложение света, а не краски: у соседних столбиков свечения
        // складываются, и волна читается диодами В СТЕКЛЕ, а не рисунком
        // поверх него.
        NSGraphicsContext.current?.compositingOperation = .plusLighter

        // Опорная линия во всю ширину. Она есть ВСЕГДА: без неё волна
        // выглядит обрывающейся у торцов - «линия просто уходит и обрывается».
        // Слева и справа остаётся линия, волна живёт посередине.
        // Опорная линия рисуется кусками, чтобы её тоже гасили края.
        let pieces = 40
        let pieceWidth = total / CGFloat(pieces)
        for index in 0..<pieces {
            let px = left + CGFloat(index) * pieceWidth
            drawNeonRod(x: px, width: pieceWidth * 1.08,
                        length: DICTATION_HUD_BAR_MIN_HEIGHT * 0.34,
                        alpha: (0.30 + (0.52 * c)) * lineIntensity
                            * edgeFade(px + pieceWidth / 2),
                        bloom: DICTATION_HUD_LINE_BLOOM)
        }

        guard c < 0.996 else { return }
        var x = left
        for (index, fraction) in heights.enumerated() {
            let breath: CGFloat = (reduceMotion || c > 0.001)
                ? 0
                : 0.05 * sin((phase * 1.7) + CGFloat(index) * 0.55)
            // ВЫСОТА ИДЁТ ОТ ГОЛОСА И БОЛЬШЕ НИ ОТ ЧЕГО.
            //
            // Здесь стоял колокол по длине - и он врал: середина всегда была
            // высокой, края всегда низкими, независимо от того, что владелец
            // говорил. Получался «червяк», а не голос. Края теперь гаснут
            // ПРОЗРАЧНОСТЬЮ (`edgeFade`), и волна растворяется в опорной линии,
            // не переставая быть правдой про громкость.
            let voice = dictationHUDWaveBarLength(fraction: fraction + breath, span: span)
            let length = voice * (1 - c)
            guard length > DICTATION_HUD_BAR_MIN_HEIGHT * 0.36 else { x += step; continue }
            let age = CGFloat(index) / CGFloat(max(1, count - 1))
            // Громче - ярче: у тихого места и высота меньше, и свет слабее,
            // иначе шёпот горит так же, как крик.
            let loudness = 0.42 + (0.58 * min(1, fraction))
            let fade = (0.40 + (0.60 * pow(age, 0.85))) * loudness
            let alpha = fade * (1 - c) * edgeFade(x + width / 2)
            guard alpha > 0.004 else { x += step; continue }
            drawNeonRod(x: x, width: width, length: length, alpha: alpha)
            x += step
        }
    }

    /// Один светящийся стержень: цветной ореол снаружи, выбеленное ядро внутри.
    ///
    /// Слова владельца: «стекло, а внутри как будто бы диоды... или лазером на
    /// стекле выбивается всё». Диод так и устроен: ядро горит почти белым,
    /// потому что свет такой яркости глаз белым и видит, а цвет остаётся в
    /// ореоле вокруг. Плоская заливка цветом даёт краску, а не свет, - и
    /// именно этим прежняя волна была нарисованной, а не горящей.
    private func drawNeonRod(x: CGFloat, width: CGFloat, length: CGFloat,
                             alpha: CGFloat, bloom: CGFloat = 1) {
        for layer in DICTATION_HUD_NEON_LAYERS {
            // `bloom` сжимает ореол, не трогая ядро: у линии свет обязан быть
            // узким, иначе «тоненькая красная линия» заливает всю плашку - на
            // этом кадре я ошибся трижды подряд.
            let w = width * (1 + ((layer.width - 1) * bloom))
            let extra = (w - width) / 2
            let rect = NSRect(x: x - extra, y: bounds.midY - length - extra,
                              width: w, height: (length * 2) + (extra * 2))
            let radius = min(rect.width, rect.height) / 2
            let white = layer.white * coreWhiteScale
            let color = white > 0
                ? tint.blended(withFraction: white, of: .white) ?? tint
                : tint
            color.withAlphaComponent(layer.alpha * alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }
}

/// Какую долю полувысоты стекла занимает волна на полном голосе. Остальное -
/// стекло, и оно обязано остаться видимым.
let DICTATION_HUD_WAVE_SPAN_SHARE: CGFloat = 0.72

/// Поле от волны до торца стекла. Ради него всё и затевалось: сквозь пустое
/// стекло по бокам видно чужое окно, и плашка читается СТЕКЛОМ, а не плиткой.
let DICTATION_HUD_WAVE_SIDE_INSET: CGFloat = 9.0

/// Доля длины волны, на которой она гаснет у каждого края.
let DICTATION_HUD_WAVE_EDGE_FADE: CGFloat = 0.22

/// Что рисует тело плашки.
public enum DictationHUDWaveGlyph: String, Sendable {
    case wave, check, bolt, cross
}

/// Что рисует тело на этой стадии. Галочка - только у подтверждённого успеха:
/// «ничего не услышал» и «отказ» успехом не являются, и галочка там врала бы.
func dictationHUDWaveGlyph(for stage: DictationHUDStage,
                           purpose: DictationRecordingPurpose) -> DictationHUDWaveGlyph {
    switch stage {
    case .inserted, .promptSavedAfterFocusChange:
        // Молния - там, где работал ИИ. Галочка говорит «текст доехал»,
        // молния - «работу сделал бог».
        return purpose == .prompt ? .bolt : .check
    case .notDelivered, .promptNotDelivered, .promptFailed,
         .recognitionFailed, .recognitionTimedOut, .refused, .nothingRecognized:
        // Слова владельца 04.09.2026: волна «должна из линий потом также
        // схлопнуться в кружочек, в котором будет красный крестик». Прежде
        // отказ показывал огрызок волны в круге - ровно та же ошибка, за
        // которую успех получил галочку: неудача обязана выглядеть неудачей.
        return .cross
    default:
        return .wave
    }
}

/// Точки галочки в своём поле.
/// Две черты крестика. Каждая рисуется отдельным ходом.
func dictationHUDCrossStrokes(in bounds: CGRect) -> [[CGPoint]] {
    let side = min(bounds.width, bounds.height) * 0.42
    let cx = bounds.midX, cy = bounds.midY
    let a = side * 0.5
    return [
        [CGPoint(x: cx - a, y: cy - a), CGPoint(x: cx + a, y: cy + a)],
        [CGPoint(x: cx - a, y: cy + a), CGPoint(x: cx + a, y: cy - a)],
    ]
}

func dictationHUDCheckPoints(in bounds: CGRect) -> [CGPoint] {
    let side = min(bounds.width, bounds.height) * 0.46
    let cx = bounds.midX, cy = bounds.midY
    return [
        CGPoint(x: cx - side * 0.52, y: cy + side * 0.04),
        CGPoint(x: cx - side * 0.12, y: cy - side * 0.36),
        CGPoint(x: cx + side * 0.56, y: cy + side * 0.40),
    ]
}

/// Точки молнии - знака Олимпа.
///
/// Слова владельца: «может быть, потом он не в галочку, а как раз в значок
/// молнии». Молния стоит там, где работал ИИ: галочка говорит «текст доехал»,
/// молния - «работу сделал бог». Разные исходы разными знаками, а не одним
/// на всё.
func dictationHUDBoltPoints(in bounds: CGRect) -> [CGPoint] {
    let h = min(bounds.width, bounds.height) * 0.62
    let w = h * 0.52
    let cx = bounds.midX, cy = bounds.midY
    return [
        CGPoint(x: cx + w * 0.34, y: cy + h * 0.50),
        CGPoint(x: cx - w * 0.46, y: cy - h * 0.06),
        CGPoint(x: cx - w * 0.02, y: cy - h * 0.06),
        CGPoint(x: cx - w * 0.34, y: cy - h * 0.50),
        CGPoint(x: cx + w * 0.46, y: cy + h * 0.10),
        CGPoint(x: cx + w * 0.02, y: cy + h * 0.10),
    ]
}

/// Толщина знака исхода.
let DICTATION_HUD_CHECK_WIDTH: CGFloat = 1.7

/// Насколько узок ореол у ЛИНИИ против волны. Линия тонкая по смыслу, и
/// широкий ореол превращает её в полосу света.
let DICTATION_HUD_LINE_BLOOM: CGFloat = 0.34

/// Слои стержня: снаружи широкий и тусклый цвет, внутри узкое выбеленное ядро.
/// Ширина - множитель к толщине столбика, `white` - доля подмешанного белого.
let DICTATION_HUD_NEON_LAYERS: [(width: CGFloat, alpha: CGFloat, white: CGFloat)] = [
    (6.2, 0.055, 0.00),
    (4.2, 0.090, 0.00),
    (2.8, 0.150, 0.00),
    (1.8, 0.280, 0.08),
    (1.0, 0.780, 0.26),
    (0.46, 0.960, 0.74),
]

/// Голубой ореола - `#B8D6EA` канона Пантеона: в семье это цвет потока и
/// публичного движения, и здесь он значит ровно то же самое.
let DICTATION_HUD_HALO_COLOR = NSColor(srgbRed: 0.722, green: 0.839, blue: 0.918, alpha: 1)

/// Слои свечения: толще - тусклее. Четырёх хватает, чтобы кромка светилась,
/// а не была обведена.
let DICTATION_HUD_HALO_LAYERS: [(width: CGFloat, alpha: CGFloat)] = [
    (5.4, 0.06),
    (3.4, 0.12),
    (2.0, 0.24),
    (1.0, 0.62),
]

/// Зелёный - обычная диктовка. Не `systemGreen`: тот на стекле уходит в
/// кислоту, а плашка живёт поверх чужого окна и обязана остаться спокойной.
public let DICTATION_HUD_WAVE_GREEN = NSColor(srgbRed: 0.22, green: 0.80, blue: 0.46, alpha: 1)
/// Золото - промпт-режим. Решение владельца 04.09.2026: «ведь это Олимп».
///
/// Не произвольный жёлтый: `#C9A87A` - золото канона Пантеона, цвет личного и
/// ценного, а в ночном каноне вообще единственное тёплое пятно кадра. Когда
/// работает ИИ, плашка горит золотом семьи - и это читается как принадлежность,
/// а не как ещё один оттенок.
///
/// Прежде тут был синий. Он оказался не на своём месте дважды: сначала им было
/// «идёт работа» и режим переставал различаться цветом вовсе, потом он стал
/// режимом - и остался просто вторым холодным тоном рядом с зелёным.
public let DICTATION_HUD_WAVE_GOLD = NSColor(srgbRed: 0.945, green: 0.729, blue: 0.322, alpha: 1)
/// Запись встречи. Оранжево-алый, между золотом промпта и красным отказа, но
/// заметно теплее и насыщеннее обоих: «идёт запись» обязано читаться одним
/// взглядом через комнату, а не сравнением оттенков рядом.
public let DICTATION_HUD_WAVE_MEETING = NSColor(srgbRed: 0.976, green: 0.443, blue: 0.180, alpha: 1)
/// Насколько ядро золота вправе выгорать в белое. Золото бледнее зелёного, и
/// общая доля белого его убивает: владелец увидел белую волну вместо золотой.
let DICTATION_HUD_GOLD_CORE_WHITE: CGFloat = 0.22
/// Сила постоянного свечения по контуру в режиме промпта. Не в полную силу:
/// вспышке исхода нужно оставаться заметно ярче метки режима, иначе «получилось»
/// и «идёт работа» сливаются.
let DICTATION_HUD_MODE_GLOW_STRENGTH: CGFloat = 0.55
/// Красный - оборвалось. Слова владельца: «красные, если вдруг что-то оборвалось».
public let DICTATION_HUD_WAVE_RED = NSColor(srgbRed: 1.00, green: 0.32, blue: 0.30, alpha: 1)
/// Фиолетовый - режим перевода. Слово владельца: «пусть будет не зеленый, а
/// фиолетовый, значит это перевод».
///
/// Взят насыщенным по той же причине, что и золото: слои неона подмешивают к
/// ядру белое, и бледный тон выгорает начисто.
public let DICTATION_HUD_WAVE_VIOLET = NSColor(srgbRed: 0.667, green: 0.427, blue: 0.980, alpha: 1)

/// Что говорит цвет. Три значения, и все три названы владельцем.
public enum DictationHUDWaveTone: String, CaseIterable, Sendable {
    case normal, prompt, translation, meeting, failure
}

func dictationHUDWaveTone(stage: DictationHUDStage,
                          purpose: DictationRecordingPurpose) -> DictationHUDWaveTone {
    switch stage {
    case .notDelivered, .promptNotDelivered, .promptFailed,
         .recognitionFailed, .recognitionTimedOut, .refused, .nothingRecognized:
        // Обрыв старше режима: когда не получилось, владельцу важно ЭТО,
        // а не то, в каком режиме не получилось.
        return .failure
    case .buildingPrompt:
        return .prompt
    case .listening, .recognizing, .inserted, .promptSavedAfterFocusChange:
        switch purpose {
        case .prompt: return .prompt
        case .translation: return .translation
        case .dictation: return .normal
        case .meeting: return .meeting
        }
    }
}

public func dictationHUDWaveColor(_ tone: DictationHUDWaveTone) -> NSColor {
    switch tone {
    case .normal: return DICTATION_HUD_WAVE_GREEN
    case .prompt: return DICTATION_HUD_WAVE_GOLD
    case .translation: return DICTATION_HUD_WAVE_VIOLET
    case .meeting: return DICTATION_HUD_WAVE_MEETING
    case .failure: return DICTATION_HUD_WAVE_RED
    }
}

/// Терминальная стадия: работа кончилась, и это надо показать вспышкой.
/// Вспышка не только у обрыва - решение владельца: «если зелёное
/// заканчивается успехом, пусть так же взрывается зелёным; если синее
/// заканчивается успехом; если нет, то красное». Цвет вспышки называет ИСХОД,
/// и потому её видно даже краем глаза.
func dictationHUDWaveFlashStrength(stage: DictationHUDStage) -> CGFloat {
    switch stage {
    case .listening, .recognizing, .buildingPrompt:
        return 0
    case .inserted, .promptSavedAfterFocusChange:
        // Успех тише отказа: подтверждение не обязано кричать, а отказ обязан.
        return 0.42
    case .notDelivered, .promptNotDelivered, .promptFailed,
         .recognitionFailed, .recognitionTimedOut, .refused, .nothingRecognized:
        return 0.62
    }
}

/// Насколько волна СОБРАНА В ЛИНИЮ: 0 - звук, 1 - ровная черта.
///
/// Слова владельца: «чтобы волна была не волной, а... превращалась в линию
/// какую-нибудь, чтобы было ясно, понятно, что не получилось». Линия - это
/// та же волна, у которой отняли и высоту, и просветы: один объект доехал до
/// другого состояния, а не сменился картинкой.
func dictationHUDWaveCollapse(stage: DictationHUDStage) -> CGFloat {
    dictationHUDWaveTone(stage: stage, purpose: .dictation) == .failure ? 1 : 0
}
