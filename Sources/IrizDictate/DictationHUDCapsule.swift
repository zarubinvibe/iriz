// Части адаптированы из SuperDictate (форк Parakey), © 2026 Richard Courtman, лицензия MIT.
// Полный текст: THIRD-PARTY/SuperDictate-LICENSE

import AppKit
import Foundation

enum DictationHUDCapsuleBackgroundStyle {
    case system
    case dark
    case light
}

final class DictationHUDCapsuleView: NSView {
    var content: DictationHUDContent? {
        didSet {
            if oldValue?.visual != content?.visual {
                visualChangedAt = ProcessInfo.processInfo.systemUptime
                // Перекраска на распознавании стартует с ФАКТИЧЕСКОГО прошлого
                // цвета, а не с угаданного по стадии: после промпт-записи
                // предыдущий цвет фиолетовый, и вспышка красным была бы враньём
                // про режим ровно там, где его только что показали.
                previousAccent = oldValue?.visual.accent
            }
            needsDisplay = true
        }
    }

    var backgroundStyle: DictationHUDCapsuleBackgroundStyle = .system {
        didSet { needsDisplay = true }
    }

    var revealProgress: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    var level: Float = 0 {
        didSet { needsDisplay = true }
    }

    var phase: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    var processingElapsedOverride: CGFloat? {
        didSet { needsDisplay = true }
    }

    /// Палитра ленты. Читается из настроек при показе плашки, поэтому смена
    /// вступает в силу со следующей записи, а не посреди идущей.
    var palette: DictationHUDWavePalette = DICTATION_HUD_DEFAULT_WAVE_PALETTE {
        didSet { needsDisplay = true }
    }

    private var visualChangedAt = ProcessInfo.processInfo.systemUptime
    private var previousAccent: DictationHUDAccent?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let content else { return }
        drawCapsule(content)
    }

    /// Живая лента и плашка исхода — два РАЗНЫХ объекта, и рисуются они врозь.
    ///
    /// Владелец, 11.08.2026: «в этой плашке мне не нужна сзади пузырек». Пилюля,
    /// кант 1,15 pt и кольцо ореола — это и был пузырёк, их больше нет: живая
    /// запись висит на экране голой лентой поверх чужого содержимого.
    ///
    /// Исход при этом остался с собственным фоном, и это не поблажка. Индикатор живёт
    /// минутами и не имеет права тащить за собой рамку; сообщение живёт от 0,9
    /// до 5 секунд, и «не вставилось» обязано читаться поверх ЧЕГО УГОДНО —
    /// белого документа, тёмного терминала, чужого видео. Момент и постоянный
    /// объект — разные вещи, и выглядят они по-разному честно.
    /// Плашку рисует не Core Graphics, а стекло: `DictationHUDGlassStack`
    /// держит форму, а этот вид живёт ВНУТРИ него. Тогда собственную плиту
    /// исхода рисовать нельзя - иначе в кадре два объекта сразу, круглое
    /// стекло и квадратный чип внутри него. Поймано первым же живым кадром.
    var hostedInGlass = false

    private func drawCapsule(_ content: DictationHUDContent) {
        let reveal = max(0, min(1, revealProgress))
        guard reveal > 0.001 else { return }

        let clampedLevel = CGFloat(max(0, min(1, level.isFinite ? level : 0)))
        // Перцептивная кривая живёт одной функцией на весь продукт: размах,
        // темп фазы и аура обязаны читать одну и ту же шкалу.
        let audio = CGFloat(dictationHUDPerceptualLevel(Float(clampedLevel)))
        let layers = dictationHUDRevealLayers(progress: reveal)
        let motionEnabled = content.animatesLevel || content.animatesWaiting
        let breathingReady = motionEnabled ? layers.breathAlpha : 0
        let idleBreath = 0.0032 + (0.0018 * sin(phase * 0.31))
        let voiceBreath = audio * (0.014 + (0.008 * ((sin(phase * 0.87) + 1) / 2)))
        let liveScale = 1 + ((idleBreath + voiceBreath) * breathingReady)

        if dictationHUDFormShowsChip(content.visual.form) {
            if hostedInGlass {
                drawOutcomeGlyphOnly(content, layers: layers, liveScale: liveScale)
            } else {
                drawOutcomeChip(content, layers: layers, liveScale: liveScale)
            }
            return
        }
        drawLiveWave(content, layers: layers, audio: audio, liveScale: liveScale)
    }

    // MARK: - Живая лента

    /// Геометрия ленты в этом кадре. Одна на оба пути рисования: разъехавшись,
    /// GPU и Core Graphics нарисовали бы две разные плашки.
    private struct WaveGeometry {
        let startX: CGFloat
        let width: CGFloat
        let midY: CGFloat
        let span: CGFloat
        let amplitude: CGFloat
        let flow: DictationHUDWaveFlow
    }

    private func drawLiveWave(_ content: DictationHUDContent,
                              layers: DictationHUDRevealLayers,
                              audio: CGFloat,
                              liveScale: CGFloat) {
        let geometry = waveGeometry(content, layers: layers, audio: audio, liveScale: liveScale)
        let accent = color(for: content.visual.accent)

        // Лента и её аура уезжают на GPU одним кадром. `nil` — Metal на машине
        // нет, и всё ниже честно рисуется путём Core Graphics.
        if let wave = renderedWave(content, geometry: geometry, layers: layers, audio: audio) {
            NSImage(cgImage: wave, size: bounds.size).draw(in: bounds)
        } else {
            guard layers.contentAlpha > 0.001 else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(layers.contentAlpha)
            if content.visual.form == .processing, content.animatesWaiting {
                let fallback: DictationHUDAccent = content.stage == .buildingPrompt ? .blue : .red
                drawProcessingRibbon(geometry: geometry,
                                     sourceColor: color(for: previousAccent ?? fallback),
                                     color: accent)
            } else {
                drawRibbon(geometry: geometry,
                           accent: content.visual.accent,
                           halo: content.visual.halo,
                           auraStrength: auraStrength(content, audio: audio,
                                                      alpha: layers.breathAlpha),
                           auraHead: auraHead(content))
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        guard layers.contentAlpha > 0.001 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(layers.contentAlpha)
        drawMark(content.visual.mark, geometry: geometry, color: accent, audio: audio)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Вход плашки: лента разворачивается из искры 6,9 pt вширь и ввысь — тем же
    /// скаляром `revealProgress`, каким прежде разворачивалась пилюля, и с тем же
    /// перелётом на 10 %. Раскрытие никуда не делось вместе с пилюлей: оно
    /// теперь про саму волну.
    private func waveGeometry(_ content: DictationHUDContent,
                              layers: DictationHUDRevealLayers,
                              audio: CGFloat,
                              liveScale: CGFloat) -> WaveGeometry {
        let start = DICTATION_HUD_REVEAL_START_DIAMETER
        let grown = { (full: CGFloat) in (start + ((full - start) * layers.scale)) * liveScale }
        let amplitude: CGFloat
        let span: CGFloat
        var flow = DictationHUDWaveFlow.symmetric
        var shift: CGFloat = 0

        switch content.visual.form {
        case .waveform:
            // Знак сдвигает волну вправо на половину занятого места, чтобы
            // «шеврон + волна» стояли по центру окна как одна композиция.
            shift = content.visual.mark == .none ? 0 : DICTATION_HUD_MARK_SHIFT
            amplitude = dictationHUDRibbonAmplitude(audio: audio,
                                                    phase: phase,
                                                    motion: content.animatesLevel)
            span = DICTATION_HUD_RIBBON_LISTENING_SPAN
            flow = content.visual.flow
        case .processing:
            span = DICTATION_HUD_RIBBON_PROCESSING_SPAN
            amplitude = content.animatesWaiting
                ? processingMotion().amplitude
                : max(0.30, audio * 0.72)
            if content.animatesWaiting { flow = content.visual.flow }
        case .line, .historyLine, .exclamation, .ellipsis, .slash:
            amplitude = 0
            span = DICTATION_HUD_RIBBON_LISTENING_SPAN
        }

        let width = grown(DICTATION_HUD_WAVEFORM_WIDTH)
        return WaveGeometry(startX: bounds.midX - (width / 2) + shift,
                            width: width,
                            midY: bounds.midY,
                            span: grown(span),
                            amplitude: amplitude,
                            flow: flow)
    }

    /// Сила ауры. Прежние альфы ореола на месте: смысл «идёт запись» не менялся,
    /// сменился носитель — свечение обнимает ленту, а не кант пилюли.
    private func auraStrength(_ content: DictationHUDContent,
                              audio: CGFloat,
                              alpha: CGFloat) -> CGFloat {
        let halo = content.visual.halo
        guard halo != .none, alpha > 0.001 else { return 0 }
        let gain = halo == .traveling ? DICTATION_HUD_HALO_TRAVEL_GAIN : 1
        return alpha * gain * DICTATION_HUD_WAVE_HALO_GAIN
            * (DICTATION_HUD_HALO_IDLE_ALPHA + (DICTATION_HUD_HALO_VOICE_ALPHA * audio))
    }

    /// Где сейчас гребень бегущей ауры, в долях длины ленты. Стоит на месте,
    /// пока движение выключено: режим виден по цвету, знаку и ходу волны,
    /// а не по тому, что свечение куда-то бежит.
    private func auraHead(_ content: DictationHUDContent) -> CGFloat {
        content.animatesLevel
            ? (phase * DICTATION_HUD_HALO_TRAVEL_SPEED).truncatingRemainder(dividingBy: 1)
            : 0
    }

    // MARK: - Волна на GPU

    /// Кадр ленты, ауры и подложки с GPU, или `nil` — Metal на машине нет.
    private func renderedWave(_ content: DictationHUDContent,
                              geometry: WaveGeometry,
                              layers: DictationHUDRevealLayers,
                              audio: CGFloat) -> CGImage? {
        guard let renderer = DictationHUDWaveRenderer.shared() else { return nil }
        return renderer.image(waveScene(content, geometry: geometry,
                                        layers: layers, audio: audio))
    }

    private func waveScene(_ content: DictationHUDContent,
                           geometry: WaveGeometry,
                           layers: DictationHUDRevealLayers,
                           audio: CGFloat) -> DictationHUDWaveScene {
        var scene = DictationHUDWaveScene(viewSize: bounds.size,
                                          scale: renderScale,
                                          contentAlpha: layers.contentAlpha,
                                          lightBackground: usesLightBackground)
        applyAura(to: &scene, content: content, audio: audio, alpha: layers.breathAlpha)
        applyRibbon(to: &scene, content: content, geometry: geometry,
                    contentAlpha: layers.contentAlpha)
        return scene
    }

    private func applyAura(to scene: inout DictationHUDWaveScene,
                           content: DictationHUDContent,
                           audio: CGFloat,
                           alpha: CGFloat) {
        let strength = auraStrength(content, audio: audio, alpha: alpha)
        guard strength > 0.0005 else { return }
        scene.haloStrength = strength
        scene.haloSpread = DICTATION_HUD_HALO_SPREAD
            * (1 + (DICTATION_HUD_HALO_VOICE_SPREAD * audio))
        scene.haloTraveling = content.visual.halo == .traveling
        scene.haloHead = auraHead(content)
        scene.haloColor = waveComponents(color(for: content.visual.accent))
    }

    /// Цвета ленты. Геометрия уже посчитана снаружи — одна на оба пути.
    private func applyRibbon(to scene: inout DictationHUDWaveScene,
                             content: DictationHUDContent,
                             geometry: WaveGeometry,
                             contentAlpha: CGFloat) {
        guard contentAlpha > 0.001 else { return }
        if content.visual.form == .processing, content.animatesWaiting {
            applyProcessingFront(to: &scene, content: content)
        }

        scene.waveStartX = geometry.startX
        scene.waveWidth = geometry.width
        scene.waveMidY = geometry.midY
        scene.halfHeight = geometry.span / 2
        scene.amplitude = geometry.amplitude
        scene.phase = phase
        scene.flow = geometry.flow

        // Вырожденный размах — одна нить: совпавшие кривые сложились бы
        // кратно по яркости и выжгли бы цвет в белое.
        let parameters = geometry.amplitude < 0.02
            ? [CGFloat(0)]
            : dictationHUDRibbonStrandParameters()
        scene.strandParameters = parameters
        if scene.front != nil {
            // Матрица нитей белая: цвет ей даёт фронт перекраски.
            scene.strandColors = parameters.map { _ in SIMD4<Float>(1, 1, 1, 1) }
            scene.bandColor = SIMD4<Float>(1, 1, 1, 1)
        } else {
            let base = color(for: content.visual.accent)
            let device = base.usingColorSpace(.deviceRGB) ?? base
            scene.strandColors = parameters.map {
                waveComponents(ribbonTint(device, accent: content.visual.accent, strand: $0))
            }
            // Заливка — НАСЫЩЕННЫЙ тон режима, а не средний тон нитей: нити
            // у ядра выбелены, и от их среднего заливка вышла бы белёсой.
            // Внутри ленты цвет, по краям горячие нити — так режим виден
            // именно там, где ленты больше всего.
            scene.bandColor = waveComponents(ribbonBandTint(device,
                                                            accent: content.visual.accent))
        }
    }

    /// Ход распознавания: размах и место фронта перекраски. Чистая арифметика
    /// от возраста стадии — её спрашивают и геометрия, и цвет.
    private func processingMotion() -> (amplitude: CGFloat, head: CGFloat, band: CGFloat) {
        let age = processingElapsedOverride
            ?? CGFloat(max(0, ProcessInfo.processInfo.systemUptime - visualChangedAt))
        let resolveProgress = min(1, age / DICTATION_HUD_PROCESSING_TRANSITION_DURATION)
        let loopPhase = max(0, age - DICTATION_HUD_PROCESSING_TRANSITION_DURATION)
        // Пока фронт идёт — лента подаётся вперёд; дальше остаётся ровный
        // пульс, по которому видно, что работа не встала.
        let front = max(0, 1 - abs(resolveProgress - 0.5) * 2)
        let pulse = (sin(loopPhase * 4.1) + 1) / 2
        let band = DICTATION_HUD_WAVE_FRONT_BAND
        return (amplitude: min(1, 0.30 + (0.20 * front) + (0.14 * pulse)),
                head: (min(1, max(0, resolveProgress)) * (1 + band)) - (band / 2),
                band: band)
    }

    /// Распознавание: фронт перекраски идёт слева направо, слева уже цвет
    /// работы, справа ещё цвет режима, в котором говорили.
    private func applyProcessingFront(to scene: inout DictationHUDWaveScene,
                                      content: DictationHUDContent) {
        let motion = processingMotion()
        let fallback: DictationHUDAccent = content.stage == .buildingPrompt ? .blue : .red
        scene.front = (near: waveComponents(color(for: content.visual.accent)),
                       far: waveComponents(color(for: previousAccent ?? fallback)),
                       head: motion.head,
                       band: motion.band)
    }

    // MARK: - Плашка исхода

    /// Компактный скруглённый квадрат со своей подложкой. Форма НЕ пилюля
    /// намеренно: пилюля — это тот самый пузырёк, а исход обязан читаться как
    /// другой объект, а не как вернувшаяся плашка.
    private func drawOutcomeChip(_ content: DictationHUDContent,
                                 layers: DictationHUDRevealLayers,
                                 liveScale: CGFloat) {
        let start = DICTATION_HUD_REVEAL_START_DIAMETER
        let side = (start + ((DICTATION_HUD_CHIP_SIZE - start) * layers.scale)) * liveScale
        guard side > 0.5 else { return }
        let rect = NSRect(x: bounds.midX - (side / 2),
                          y: bounds.midY - (side / 2),
                          width: side,
                          height: side)
        // Радиус едет вместе со стороной: иначе на входе квадратик 7 pt был бы
        // почти кругом, а к концу роста скругление отставало бы от размера.
        let radius = DICTATION_HUD_CHIP_RADIUS * (side / DICTATION_HUD_CHIP_SIZE)
        let chip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        // Имя не `palette`: так зовётся палитра ЛЕНТЫ, и путать их нельзя.
        let background = backgroundPalette(alpha: layers.backgroundAlpha)
        background.fill.setFill()
        chip.fill()
        background.stroke.setStroke()
        chip.lineWidth = DICTATION_HUD_CHIP_BORDER_WIDTH
        chip.stroke()

        guard layers.contentAlpha > 0.001 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        chip.addClip()
        context.setAlpha(layers.contentAlpha)

        let accent = color(for: content.visual.accent)
        switch content.visual.form {
        case .line:
            drawOutcomeLine(in: rect, color: accent)
        case .historyLine:
            drawOutcomeLine(in: rect, color: accent)
            drawHistoryDot(in: rect, color: accent)
        case .exclamation:
            drawExclamation(in: rect, color: accent)
        case .ellipsis:
            drawEllipsis(in: rect, color: accent)
        case .slash:
            drawSlash(in: rect, color: accent)
        case .waveform, .processing:
            break
        }
    }

    /// Знак исхода БЕЗ собственной плиты: форму держит стекло, и вторая
    /// плита внутри него - это два объекта в одном кадре. Глиф тот же самый,
    /// геометрия та же; выброшены только заливка, кант и клип по чипу.
    private func drawOutcomeGlyphOnly(_ content: DictationHUDContent,
                                      layers: DictationHUDRevealLayers,
                                      liveScale: CGFloat) {
        let start = DICTATION_HUD_REVEAL_START_DIAMETER
        let side = (start + ((DICTATION_HUD_CHIP_SIZE - start) * layers.scale)) * liveScale
        guard side > 0.5, layers.contentAlpha > 0.001 else { return }
        let rect = NSRect(x: bounds.midX - (side / 2),
                          y: bounds.midY - (side / 2),
                          width: side,
                          height: side)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setAlpha(layers.contentAlpha)

        let accent = color(for: content.visual.accent)
        switch content.visual.form {
        case .line:
            drawOutcomeLine(in: rect, color: accent)
        case .historyLine:
            drawOutcomeLine(in: rect, color: accent)
            drawHistoryDot(in: rect, color: accent)
        case .exclamation:
            drawExclamation(in: rect, color: accent)
        case .ellipsis:
            drawEllipsis(in: rect, color: accent)
        case .slash:
            drawSlash(in: rect, color: accent)
        case .waveform, .processing:
            break
        }
    }

    /// Прямая линия исхода. Прежде это была осевшая лента во всю ширину пилюли;
    /// в плашке 32,2 pt столько не влезает, да и незачем — здесь линия работает
    /// знаком «дошло / пусто», а не остатком волны.
    private func drawOutcomeLine(in rect: NSRect, color: NSColor) {
        let thickness: CGFloat = 2.3
        let bar = NSRect(x: rect.midX - (DICTATION_HUD_CHIP_LINE_WIDTH / 2),
                         y: rect.midY - (thickness / 2),
                         width: DICTATION_HUD_CHIP_LINE_WIDTH,
                         height: thickness)
        fillGlowing([NSBezierPath(roundedRect: bar,
                                  xRadius: thickness / 2,
                                  yRadius: thickness / 2)],
                    color: color)
    }

    private func waveComponents(_ color: NSColor) -> SIMD4<Float> {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return SIMD4(Float(rgb.redComponent),
                     Float(rgb.greenComponent),
                     Float(rgb.blueComponent),
                     1)
    }

    /// Во сколько пикселей на пункт рисуется кадр. Берётся из текущего
    /// контекста, а не из окна: раскадровка рендерится в 4× вне экрана, и
    /// спросить окно там некого.
    private var renderScale: CGFloat {
        let fallback = window?.backingScaleFactor ?? 2
        guard let context = NSGraphicsContext.current?.cgContext else { return fallback }
        let transform = context.ctm
        let determinant = abs((transform.a * transform.d) - (transform.b * transform.c))
        let scale = determinant > 0 ? sqrt(determinant) : 0
        return scale.isFinite && scale >= 1 ? min(8, scale) : fallback
    }

    /// Непрерывная лента вместо восьми столбиков.
    ///
    /// Четыре приёма, из которых складывается «дорого», и все четыре — обычная
    /// графика, не чужой шейдер:
    ///
    /// 1. Колокол огибающей — лента растворяется у краёв, а не обрывается.
    /// 2. Хроматическое расслоение — четыре фазово-сдвинутые нити, каждая
    ///    своего тона, складываются светом; переливы на нахлёсте и есть
    ///    тот эффект.
    /// 3. Свечение слоями — растущая толщина при падающей альфе вместо плоской
    ///    обводки: мягкое ядро с длинным хвостом.
    /// 4. Заливка между крайними нитями — из-за неё это лента, а не проволоки.
    ///
    /// Всё рисуется в отдельный слой прозрачности: внутри него нити складываются
    /// между собой, а наружу слой уходит одним куском с краевой маской — только
    /// так растворение края видно и на заливке, и на свечении сразу.
    private func drawRibbon(geometry: WaveGeometry,
                            accent: DictationHUDAccent,
                            halo: DictationHUDHalo,
                            auraStrength: CGFloat,
                            auraHead: CGFloat) {
        let base = color(for: accent).usingColorSpace(.deviceRGB) ?? color(for: accent)
        // Вырожденный размах — одна нить: совпавшие кривые сложились бы
        // кратно по яркости и выжгли бы цвет в белое.
        let parameters = geometry.amplitude < 0.02
            ? [CGFloat(0)]
            : dictationHUDRibbonStrandParameters()
        let paths = parameters.map { ribbonPath(geometry: geometry, strand: $0) }

        drawAura(paths: paths, geometry: geometry, color: base,
                 halo: halo, strength: auraStrength, head: auraHead)
        inRibbonLayer { context in
            if let first = parameters.first, let last = parameters.last, first != last {
                ribbonTint(base, accent: accent, strand: 0)
                    .withAlphaComponent(DICTATION_HUD_RIBBON_FILL_ALPHA)
                    .setFill()
                ribbonFillPath(geometry: geometry, from: first, to: last).fill()
            }
            for (index, path) in paths.enumerated() {
                let strand = parameters[index]
                strokeRibbonGlow(path,
                                 color: ribbonTint(base, accent: accent, strand: strand),
                                 coreAlpha: ribbonCoreAlpha
                                    * dictationHUDRibbonStrandWeight(strand))
            }
            // Гребень ведёт саму ленту, а не одну её юбку — то же, что делает
            // шейдер множителем яркости. Здесь это маска по альфе, поэтому
            // ярче единицы не бывает: тот же контраст, взятый вниз от гребня.
            // Плита за лентой не стоит, и «тусклее» тут неотличимо от «прозрачнее».
            if halo == .traveling, auraStrength > 0.0005 {
                applyRidgeMask(context: context, geometry: geometry, head: auraHead)
            }
            maskRibbonEdges(context: context, geometry: geometry)
        }
    }

    private func applyRidgeMask(context: CGContext, geometry: WaveGeometry, head: CGFloat) {
        guard let crest = travelingAuraMask(head: head) else { return }
        context.setBlendMode(.destinationIn)
        context.drawLinearGradient(crest,
                                   start: CGPoint(x: geometry.startX, y: 0),
                                   end: CGPoint(x: geometry.startX + geometry.width, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Аура ленты — то, чем на пути Core Graphics стал прежний ореол по канту.
    /// Кольца вокруг пилюли рисовать больше нечего вокруг, поэтому свечение
    /// кладётся широкими слабыми обводками вдоль самой ленты. У бегущей ауры
    /// поверх ложится продольный градиент с гребнем: гейт «ровно / бежит» тот же,
    /// что в шейдере, только собран другим инструментом.
    private func drawAura(paths: [NSBezierPath],
                          geometry: WaveGeometry,
                          color: NSColor,
                          halo: DictationHUDHalo,
                          strength: CGFloat,
                          head: CGFloat) {
        guard halo != .none, strength > 0.0005, let outer = paths.first,
              let inner = paths.last else { return }
        inRibbonLayer { context in
            for path in [outer, inner] {
                strokeRibbonGlow(path,
                                 color: color,
                                 coreAlpha: strength,
                                 coreWidth: DICTATION_HUD_HALO_SPREAD,
                                 layers: 3,
                                 spread: 0.9)
            }
            if halo == .traveling {
                applyRidgeMask(context: context, geometry: geometry, head: head)
            }
            maskRibbonEdges(context: context, geometry: geometry)
        }
    }

    /// Продольная маска гребня: тот же множитель `dictationHUDHaloRidgeGain`,
    /// что уезжает в шейдер числами `haloRidgeBase`/`haloRidgeScale`, только
    /// нормированный на свой максимум — маска не умеет быть ярче единицы.
    /// Контраст между впадиной и гребнем от этого не меняется, а меняется общая
    /// яркость; на прозрачной плашке без плиты «тусклее» и «прозрачнее» — одно
    /// и то же, поэтому обмен честный.
    ///
    /// Двух дюжин опорных точек хватает: между ними Core Graphics интерполирует
    /// сам, и гребень выходит гладким, без граней.
    private func travelingAuraMask(head: CGFloat) -> CGGradient? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let stops = 24
        let peak = dictationHUDHaloRidgeGain(1)
        guard peak > 0.0001 else { return nil }
        var components: [CGFloat] = []
        var locations: [CGFloat] = []
        for stop in 0...stops {
            let position = CGFloat(stop) / CGFloat(stops)
            let ridge = dictationHUDHaloRidge(at: position, head: head)
            components.append(contentsOf: [1, 1, 1,
                                           min(1, dictationHUDHaloRidgeGain(ridge) / peak)])
            locations.append(position)
        }
        return CGGradient(colorSpace: space,
                          colorComponents: components,
                          locations: locations,
                          count: locations.count)
    }

    /// Одна нить: ломаная по `DICTATION_HUD_RIBBON_SAMPLES` точкам. Кривые Безье
    /// здесь ничего не добавили бы — на 0,7 pt сегмента грани не видно даже
    /// в четырёхкратном экспорте.
    private func ribbonPath(geometry: WaveGeometry, strand: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let half = geometry.span / 2
        for index in 0...DICTATION_HUD_RIBBON_SAMPLES {
            let t = CGFloat(index) / CGFloat(DICTATION_HUD_RIBBON_SAMPLES)
            let offset = dictationHUDRibbonSample(x: (t * 2) - 1,
                                                  phase: phase,
                                                  amplitude: geometry.amplitude,
                                                  flow: geometry.flow,
                                                  strand: strand)
            let point = NSPoint(x: geometry.startX + (t * geometry.width),
                                y: geometry.midY + (offset * half))
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    private func ribbonFillPath(geometry: WaveGeometry,
                                from: CGFloat,
                                to: CGFloat) -> NSBezierPath {
        let path = ribbonPath(geometry: geometry, strand: from)
        path.append(ribbonPath(geometry: geometry, strand: to).reversed)
        path.close()
        return path
    }

    /// Лоренцев спад в лоб: яркость слоя падает быстрее, чем растёт толщина,
    /// поэтому ядро остаётся ядром, а хвост длинным.
    private func strokeRibbonGlow(_ path: NSBezierPath,
                                  color: NSColor,
                                  coreAlpha: CGFloat,
                                  coreWidth: CGFloat = DICTATION_HUD_RIBBON_CORE_WIDTH,
                                  layers: Int = DICTATION_HUD_RIBBON_GLOW_LAYERS,
                                  spread: CGFloat = DICTATION_HUD_RIBBON_GLOW_STEP) {
        for layer in stride(from: layers - 1, through: 0, by: -1) {
            let step = CGFloat(layer) * spread
            path.lineWidth = coreWidth * (1 + step)
            color
                .withAlphaComponent(min(1, coreAlpha
                                        / (1 + (step * DICTATION_HUD_RIBBON_GLOW_FALLOFF))))
                .setStroke()
            path.stroke()
        }
    }

    /// Краевая маска: `destinationIn` домножает альфу всего, что уже нарисовано
    /// в слое. Огибающая гасит только размах, а маска — саму видимость, поэтому
    /// у ленты нет торцов ни у линий, ни у заливки.
    private func maskRibbonEdges(context: CGContext, geometry: WaveGeometry) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let fade = CGGradient(colorSpace: space,
                                    colorComponents: [1, 1, 1, 0,
                                                      1, 1, 1, 1,
                                                      1, 1, 1, 1,
                                                      1, 1, 1, 0],
                                    locations: [0,
                                                DICTATION_HUD_RIBBON_FADE,
                                                1 - DICTATION_HUD_RIBBON_FADE,
                                                1],
                                    count: 4) else { return }
        context.setBlendMode(.destinationIn)
        context.drawLinearGradient(fade,
                                   start: CGPoint(x: geometry.startX, y: 0),
                                   end: CGPoint(x: geometry.startX + geometry.width, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// На тёмном фоне нити складываются светом — нахлёст ярче составляющих.
    /// На светлом сложение выжгло бы всё в белое, и там они смешиваются
    /// краской: нахлёст темнее и насыщеннее. Приём один, знак разный.
    private var ribbonBlendMode: CGBlendMode {
        usesLightBackground ? .multiply : .plusLighter
    }

    /// Ядро НЕ на полную силу. Четыре нити по четыре слоя складываются светом,
    /// и на единице их сумма выжигает цвет в белое — то есть ровно ту хроматику,
    /// ради которой всё и рисуется. На тёмном фоне сумма сходится к белому
    /// только в самых горячих пересечениях, и это и есть ядро.
    private var ribbonCoreAlpha: CGFloat {
        usesLightBackground ? 0.80 : 0.58
    }

    private func ribbonTint(_ base: NSColor,
                            accent: DictationHUDAccent,
                            strand: CGFloat) -> NSColor {
        let offset = dictationHUDRibbonHueOffset(palette: palette,
                                                 accent: accent,
                                                 strand: strand)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Серому крутить нечего: у состояний без цвета (тишина, история) лента
        // так и остаётся одноцветной, и это правда про них.
        guard saturation > 0.01 else { return base }
        let shifted = (hue + offset).truncatingRemainder(dividingBy: 1)
        // Внутренние нити выбелены, крайние спектральные: пересечение выбеленных
        // читается светом, а четыре одинаково насыщенные — краской. На светлом
        // фоне выбеливать нечего: там лента ложится краской, и белая краска —
        // это дырка в ленте.
        let white = usesLightBackground ? 0 : dictationHUDRibbonWhiteMix(strand: strand)
        return NSColor(deviceHue: shifted < 0 ? shifted + 1 : shifted,
                       saturation: min(1, saturation * DICTATION_HUD_RIBBON_SATURATION_GAIN)
                           * (1 - white),
                       brightness: brightness,
                       alpha: alpha)
    }

    /// Тон заливки между нитями: цвет режима без разлёта и без выбеливания.
    /// Заливка занимает всю площадь ленты, и режим виден именно по ней.
    private func ribbonBandTint(_ base: NSColor, accent: DictationHUDAccent) -> NSColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0.01 else { return base }
        return NSColor(deviceHue: hue,
                       saturation: min(1, saturation * DICTATION_HUD_RIBBON_SATURATION_GAIN),
                       brightness: brightness,
                       alpha: alpha)
    }

    /// Шеврон слева от волны: «сказанное станет указанием». Светится теми же
    /// слоями, что и лента, и в том же режиме наложения — иначе знак выглядел бы
    /// наклейкой поверх чужой картинки, а не частью одной композиции.
    private func drawMark(_ mark: DictationHUDMark,
                          geometry: WaveGeometry,
                          color: NSColor,
                          audio: CGFloat) {
        guard mark == .chevron else { return }
        let right = geometry.startX - DICTATION_HUD_MARK_GAP
        let left = right - DICTATION_HUD_MARK_WIDTH
        let half = DICTATION_HUD_MARK_HEIGHT / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: left, y: geometry.midY - half))
        path.line(to: NSPoint(x: right, y: geometry.midY))
        path.line(to: NSPoint(x: left, y: geometry.midY + half))
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        // Свечение знака уже ленточного: у ленты бахрома в семь толщин ядра —
        // приём для тонкой нити, а на плотном шевроне 4,6 pt та же бахрома
        // превращается в кляксу.
        inRibbonLayer { _ in
            strokeRibbonGlow(path,
                             color: ribbonTint(color.usingColorSpace(.deviceRGB) ?? color,
                                               accent: .neutral,
                                               strand: 0),
                             coreAlpha: (ribbonCoreAlpha * 0.92) + (0.10 * audio),
                             coreWidth: DICTATION_HUD_MARK_LINE_WIDTH,
                             layers: 3,
                             spread: 0.62)
        }
    }

    /// Распознавание: та же лента, но по ней слева направо идёт фронт
    /// перекраски — слева уже цвет работы, справа ещё цвет режима, в котором
    /// говорили. Перекраска стартует с ФАКТИЧЕСКОГО прошлого цвета (см.
    /// `previousAccent`), иначе после промпт-записи вспышка была бы красной.
    ///
    /// Нити здесь рисуются белой матрицей, а цвет накладывается одним
    /// градиентом через `sourceIn`: фронт получается мягким сам собой, и на
    /// кадр приходится один градиент вместо дюжины перекрашенных обводок.
    private func drawProcessingRibbon(geometry: WaveGeometry,
                                      sourceColor: NSColor,
                                      color: NSColor) {
        let motion = processingMotion()
        let parameters = dictationHUDRibbonStrandParameters()

        // Матрица всегда складывается светом, даже на светлом фоне: это не
        // цвет, а альфа, и цвет ляжет на неё следующим шагом.
        inRibbonLayer(blend: .plusLighter) { context in
            for strand in parameters {
                // Ход берётся из визуальной таблицы через геометрию, а не
                // назначается здесь: рисование не имеет права расходиться
                // с моделью, даже если «так красивее».
                let path = ribbonPath(geometry: geometry, strand: strand)
                strokeRibbonGlow(path,
                                 color: .white,
                                 coreAlpha: ribbonCoreAlpha
                                    * dictationHUDRibbonStrandWeight(strand))
            }
            if let gradient = processingFrontGradient(from: sourceColor,
                                                      to: color,
                                                      head: motion.head,
                                                      band: motion.band) {
                context.setBlendMode(.sourceIn)
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: geometry.startX, y: 0),
                    end: CGPoint(x: geometry.startX + geometry.width, y: 0),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
            maskRibbonEdges(context: context, geometry: geometry)
        }
    }

    /// Фронт перекраски: полоса перехода шириной `band` стоит на `head`.
    private func processingFrontGradient(from sourceColor: NSColor,
                                         to color: NSColor,
                                         head: CGFloat,
                                         band: CGFloat) -> CGGradient? {
        let source = sourceColor.usingColorSpace(.sRGB) ?? sourceColor
        let target = color.usingColorSpace(.sRGB) ?? color
        let components: [CGFloat] = [
            target.redComponent, target.greenComponent, target.blueComponent, 1,
            target.redComponent, target.greenComponent, target.blueComponent, 1,
            source.redComponent, source.greenComponent, source.blueComponent, 1,
            source.redComponent, source.greenComponent, source.blueComponent, 1,
        ]
        let locations: [CGFloat] = [0,
                                    min(1, max(0, head - (band / 2))),
                                    min(1, max(0, head + (band / 2))),
                                    1]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGGradient(colorSpace: space,
                          colorComponents: components,
                          locations: locations,
                          count: 4)
    }

    private func drawExclamation(in capsuleRect: NSRect, color: NSColor) {
        let stemWidth: CGFloat = 2.76
        let stemHeight: CGFloat = 10.35
        let dotDiameter: CGFloat = 2.76
        let gap: CGFloat = 2.3
        let totalHeight = stemHeight + gap + dotDiameter
        let top = capsuleRect.midY - totalHeight / 2
        fillGlowing([
            NSBezierPath(roundedRect: NSRect(x: capsuleRect.midX - stemWidth / 2,
                                             y: top,
                                             width: stemWidth,
                                             height: stemHeight),
                         xRadius: stemWidth / 2,
                         yRadius: stemWidth / 2),
            NSBezierPath(ovalIn: NSRect(x: capsuleRect.midX - dotDiameter / 2,
                                        y: top + stemHeight + gap,
                                        width: dotDiameter,
                                        height: dotDiameter)),
        ], color: color)
    }

    private func drawEllipsis(in capsuleRect: NSRect, color: NSColor) {
        let diameter: CGFloat = 2.76
        let gap: CGFloat = 2.3
        let width = diameter * 3 + gap * 2
        fillGlowing((0..<3).map { index in
            let x = capsuleRect.midX - width / 2 + CGFloat(index) * (diameter + gap)
            return NSBezierPath(ovalIn: NSRect(x: x,
                                               y: capsuleRect.midY - diameter / 2,
                                               width: diameter,
                                               height: diameter))
        }, color: color)
    }

    private func drawSlash(in capsuleRect: NSRect, color: NSColor) {
        let halfOffset: CGFloat = 6.1
        let path = NSBezierPath()
        path.move(to: NSPoint(x: capsuleRect.midX - halfOffset,
                              y: capsuleRect.midY + halfOffset))
        path.line(to: NSPoint(x: capsuleRect.midX + halfOffset,
                              y: capsuleRect.midY - halfOffset))
        path.lineCapStyle = .round
        inRibbonLayer { _ in
            strokeRibbonGlow(path,
                             color: color.usingColorSpace(.deviceRGB) ?? color,
                             coreAlpha: 0.88,
                             coreWidth: 2.3,
                             layers: 3,
                             spread: 1.5)
        }
    }

    private func drawHistoryDot(in capsuleRect: NSRect, color: NSColor) {
        let diameter: CGFloat = 2.76
        fillGlowing([NSBezierPath(ovalIn: NSRect(x: capsuleRect.midX - diameter / 2,
                                                 y: capsuleRect.midY + 5.75 - diameter / 2,
                                                 width: diameter,
                                                 height: diameter))],
                    color: color)
    }

    /// Знаки исхода светятся теми же слоями, что и лента, и в том же режиме
    /// наложения. После перехода на ленту плоская заливка выглядела бы
    /// наклейкой из другого приложения — а это одна плашка, а не витрина.
    private func fillGlowing(_ paths: [NSBezierPath], color: NSColor) {
        let tint = color.usingColorSpace(.deviceRGB) ?? color
        inRibbonLayer { _ in
            for path in paths {
                strokeRibbonGlow(path,
                                 color: tint,
                                 coreAlpha: 0.30,
                                 coreWidth: 1.15,
                                 layers: 3,
                                 spread: 1.4)
            }
            tint.withAlphaComponent(0.88).setFill()
            for path in paths { path.fill() }
        }
    }

    /// Слой прозрачности с режимом наложения ленты. Отдельной обёрткой, чтобы
    /// ни один знак не забыл ни `endTransparencyLayer`, ни `restoreGState`.
    private func inRibbonLayer(blend: CGBlendMode? = nil, _ body: (CGContext) -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setBlendMode(blend ?? ribbonBlendMode)
        body(context)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func color(for accent: DictationHUDAccent) -> NSColor {
        switch accent {
        case .red: return .systemRed
        case .violet:
            // Свой цвет, не systemPurple: тот уходит в розовое и на светлом фоне
            // спорит с красным. Этот холоднее красного по любому каналу, поэтому
            // остаётся другим и при дальтонизме, где красный и зелёный сходятся.
            return NSColor(calibratedRed: 0.45, green: 0.36, blue: 0.97, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0, green: 0.44, blue: 1, alpha: 1)
        case .cyan: return .systemCyan
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .orange: return .systemOrange
        case .neutral: return NSColor(calibratedWhite: 0.55, alpha: 1)
        }
    }

    private func backgroundPalette(alpha: CGFloat) -> (fill: NSColor, stroke: NSColor) {
        if usesLightBackground {
            return (NSColor(calibratedWhite: 1, alpha: 0.84 * alpha),
                    NSColor(calibratedWhite: 0, alpha: 0.14 * alpha))
        }
        return (NSColor(calibratedWhite: 0, alpha: 0.96 * alpha),
                NSColor(calibratedWhite: 0.22, alpha: 0.26 * alpha))
    }

    private var usesLightBackground: Bool {
        switch backgroundStyle {
        case .light: return true
        case .dark: return false
        case .system:
            return effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        }
    }
}
