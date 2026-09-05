// Части адаптированы из SuperDictate (форк Parakey), © 2026 Richard Courtman, лицензия MIT.
// Полный текст: THIRD-PARTY/SuperDictate-LICENSE

import AppKit
import Foundation

private struct DictationHUDExportFrame {
    let name: String
    let stage: DictationHUDStage
    let level: Float
    let phase: CGFloat
    let reveal: CGFloat
    let processingElapsed: CGFloat?
    /// Кадр «уменьшения движения»: волна и ореол замирают, а цвет и знак
    /// обязаны остаться — ровно это и надо увидеть глазами.
    let reduceMotion: Bool
    let background: DictationHUDCapsuleBackgroundStyle
    /// Подложка под плашку. `nil` — прозрачный кадр раскадровки. Непрозрачная
    /// нужна там, где судят ореол: на прозрачном фоне мягкое свечение не
    /// увидеть, а плашка живёт поверх чужих окон, а не поверх пустоты.
    let backdrop: NSColor?
    let palette: DictationHUDWavePalette

    init(name: String,
         stage: DictationHUDStage,
         level: Float,
         phase: CGFloat,
         reveal: CGFloat,
         processingElapsed: CGFloat?,
         reduceMotion: Bool = false,
         background: DictationHUDCapsuleBackgroundStyle = .dark,
         backdrop: NSColor? = nil,
         palette: DictationHUDWavePalette = DICTATION_HUD_DEFAULT_WAVE_PALETTE) {
        self.name = name
        self.stage = stage
        self.level = level
        self.phase = phase
        self.reveal = reveal
        self.processingElapsed = processingElapsed
        self.reduceMotion = reduceMotion
        self.background = background
        self.backdrop = backdrop
        self.palette = palette
    }
}

/// Натуральная величина: столько физических пикселей занимает свёрнутая плашка
/// на ретине 2x, то есть ровно то, что владелец видит на экране. 124,2 x 36,8 pt
/// при этом масштабе дают 248 x 74 пикселя.
public let DICTATION_HUD_EXPORT_NATURAL_SCALE: CGFloat = 2

/// Имена кадров приговора начинаются с этого префикса. Приговор владельца
/// выносится ТОЛЬКО по ним, поэтому увеличить их нельзя ничем.
public let DICTATION_HUD_VERDICT_FRAME_PREFIX = "look-"

/// Размер кадра приговора в физических пикселях.
public func dictationHUDExportNaturalPixelSize() -> CGSize {
    CGSize(
        width: (DICTATION_HUD_BASE_SIZE.width * DICTATION_HUD_EXPORT_NATURAL_SCALE).rounded(),
        height: (DICTATION_HUD_BASE_SIZE.height * DICTATION_HUD_EXPORT_NATURAL_SCALE).rounded()
    )
}

/// Масштаб конкретного кадра раскадровки.
///
/// Пять отказов ленты подряд - прямое следствие того, что правило «приговор
/// только с кадра 248 x 74» жило в прозе хэндоффа, а в коде стояло
/// `pixelScale = 4`. Здесь правило стоит машиной: увеличенный масштаб можно
/// попросить для разглядывания, но на кадр приговора он не действует.
public func dictationHUDExportPixelScale(frameName: String, requested: CGFloat) -> CGFloat {
    if frameName.hasPrefix(DICTATION_HUD_VERDICT_FRAME_PREFIX) {
        return DICTATION_HUD_EXPORT_NATURAL_SCALE
    }
    return max(1, requested)
}

/// Рисует детерминированную PNG-раскадровку HUD вне экрана.
/// Функция не трогает аудио, историю, буфер обмена или текущий фокус.
/// - Parameter scale: масштаб разглядывания для НЕприговорных кадров.
///   Кадры `look-*` всегда идут в натуральную величину.
/// - Returns: Пути к кадрам в порядке раскадровки.
@MainActor
public func exportDictationHUDAnimationFrames(
    to directory: URL,
    scale: CGFloat = DICTATION_HUD_EXPORT_NATURAL_SCALE,
    only prefix: String? = nil
) throws -> [URL] {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )

    let pointSize = DICTATION_HUD_BASE_SIZE
    let view = DictationHUDCapsuleView(frame: CGRect(origin: .zero, size: pointSize))

    // Полный прогон - 3030 кадров, из них 2904 таймлайн. Когда правишь форму
    // и смотришь на четырнадцать кадров приговора, остальные 3016 стоят чистого
    // ожидания на каждой итерации. `--only look-` отдаёт ровно нужные.
    var frames = dictationHUDExportFrames()
        + dictationHUDInspectionFrames()
        + dictationHUDBackdropFrames()
        + dictationHUDOutcomeFrames()
        + dictationHUDPaletteFrames()
    // Таймлайн строится, только если он вообще может попасть в отбор: строить
    // 2904 кадра, чтобы тут же выбросить их фильтром, - та же трата.
    let wantsTimeline = prefix.map { "frame-".hasPrefix($0) || "prompt-".hasPrefix($0) } ?? true
    if wantsTimeline {
        frames += dictationHUDTimelineFrames(purpose: .dictation, prefix: "frame")
            + dictationHUDTimelineFrames(purpose: .prompt, prefix: "prompt")
    }
    if let prefix, !prefix.isEmpty {
        frames = frames.filter { $0.name.hasPrefix(prefix) }
    }
    var exported: [URL] = []
    exported.reserveCapacity(frames.count)
    for frame in frames {
        try autoreleasepool {
            let pixelScale = dictationHUDExportPixelScale(frameName: frame.name, requested: scale)
            let pixelWidth = Int((pointSize.width * pixelScale).rounded())
            let pixelHeight = Int((pointSize.height * pixelScale).rounded())
            view.backgroundStyle = frame.background
            view.palette = frame.palette
            view.content = dictationHUDContent(
                stage: frame.stage,
                level: frame.level,
                reduceMotion: frame.reduceMotion,
                historyHint: ""
            )
            view.level = frame.level
            view.phase = frame.phase
            view.revealProgress = frame.reveal
            view.processingElapsedOverride = frame.processingElapsed

            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw dictationHUDExportError(
                    code: 1,
                    message: "Не удалось создать RGBA-кадр."
                )
            }

            bitmap.size = pointSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(origin: .zero, size: pointSize))
            context.cgContext.scaleBy(x: pixelScale, y: pixelScale)
            if let backdrop = frame.backdrop {
                backdrop.setFill()
                NSBezierPath(rect: CGRect(origin: .zero, size: pointSize)).fill()
            }
            view.displayIgnoringOpacity(view.bounds, in: context)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()

            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw dictationHUDExportError(code: 2, message: "Не удалось закодировать PNG-кадр.")
            }
            let output = directory.appendingPathComponent(frame.name + ".png")
            try png.write(to: output, options: .atomic)
            exported.append(output)
        }
    }
    return exported
}

private func dictationHUDExportFrames() -> [DictationHUDExportFrame] {
    let stageFrames: [DictationHUDExportFrame] = [
        .init(name: "stage-01-listening-dictation", stage: .listening(.dictation),
              level: 0.62, phase: 1.35, reveal: 1, processingElapsed: nil),
        .init(name: "stage-02-listening-prompt", stage: .listening(.prompt),
              level: 0.62, phase: 25.1, reveal: 1, processingElapsed: nil),
        .init(name: "stage-03-recognizing", stage: .recognizing,
              level: 0, phase: 2.1, reveal: 1, processingElapsed: 0.62),
        .init(name: "stage-04-building-prompt", stage: .buildingPrompt,
              level: 0, phase: 2.8, reveal: 1, processingElapsed: 0.62),
        .init(name: "stage-05-inserted", stage: .inserted,
              level: 0, phase: 0, reveal: 1, processingElapsed: nil),
        .init(name: "stage-06-not-delivered", stage: .notDelivered(.targetNeverRequestedText),
              level: 0, phase: 0, reveal: 1, processingElapsed: nil),
        .init(name: "stage-07-nothing-heard", stage: .nothingRecognized(savedToHistory: false),
              level: 0, phase: 0, reveal: 1, processingElapsed: nil),
        .init(name: "stage-08-nothing-recognized-saved-to-history", stage: .nothingRecognized(savedToHistory: true),
              level: 0, phase: 0, reveal: 1, processingElapsed: nil),
        .init(name: "stage-09-recognition-timeout", stage: .recognitionTimedOut,
              level: 0, phase: 0, reveal: 1, processingElapsed: nil),
        .init(name: "stage-10-recognition-failed-unsaved", stage: .recognitionFailed(savedToHistory: false),
              level: 0, phase: 0, reveal: 1, processingElapsed: nil),
        .init(name: "stage-11-recognition-failed-saved", stage: .recognitionFailed(savedToHistory: true),
              level: 0, phase: 0, reveal: 1, processingElapsed: nil),
        .init(name: "stage-12-prompt-failed", stage: .promptFailed(.invalidResult),
              level: 0, phase: 0, reveal: 1, processingElapsed: nil),
        .init(name: "stage-13-prompt-saved-after-focus-change", stage: .promptSavedAfterFocusChange,
              level: 0, phase: 0, reveal: 1, processingElapsed: nil),
        .init(name: "stage-14-refused", stage: .refused(.secureInputActive),
              level: 0, phase: 0, reveal: 1, processingElapsed: nil),
    ]

    let motionFrames: [DictationHUDExportFrame] = [
        .init(name: "motion-01-reveal-20", stage: .listening(.dictation),
              level: 0.15, phase: 0.3, reveal: 0.20, processingElapsed: nil),
        .init(name: "motion-02-reveal-50", stage: .listening(.dictation),
              level: 0.28, phase: 0.7, reveal: 0.50, processingElapsed: nil),
        .init(name: "motion-03-reveal-85", stage: .listening(.dictation),
              level: 0.42, phase: 1.1, reveal: 0.85, processingElapsed: nil),
        .init(name: "motion-04-listening-dictation-low", stage: .listening(.dictation),
              level: 0.12, phase: 1.9, reveal: 1, processingElapsed: nil),
        .init(name: "motion-05-listening-dictation-medium", stage: .listening(.dictation),
              level: 0.48, phase: 2.8, reveal: 1, processingElapsed: nil),
        .init(name: "motion-06-listening-dictation-high", stage: .listening(.dictation),
              level: 0.92, phase: 3.7, reveal: 1, processingElapsed: nil),
        .init(name: "motion-07-listening-prompt-low", stage: .listening(.prompt),
              level: 0.12, phase: 1.9, reveal: 1, processingElapsed: nil),
        .init(name: "motion-08-listening-prompt-medium", stage: .listening(.prompt),
              level: 0.48, phase: 2.8, reveal: 1, processingElapsed: nil),
        .init(name: "motion-09-listening-prompt-high", stage: .listening(.prompt),
              level: 0.92, phase: 3.7, reveal: 1, processingElapsed: nil),
        // Четверти оборота ореола: голова гребня обязана обойти кант целиком,
        // а не дёргаться на торцах.
        .init(name: "motion-10-prompt-halo-000", stage: .listening(.prompt),
              level: 0.55, phase: 0, reveal: 1, processingElapsed: nil),
        .init(name: "motion-11-prompt-halo-025", stage: .listening(.prompt),
              level: 0.55, phase: 25, reveal: 1, processingElapsed: nil),
        .init(name: "motion-12-prompt-halo-050", stage: .listening(.prompt),
              level: 0.55, phase: 50, reveal: 1, processingElapsed: nil),
        .init(name: "motion-13-prompt-halo-075", stage: .listening(.prompt),
              level: 0.55, phase: 75, reveal: 1, processingElapsed: nil),
        .init(name: "motion-14-recognizing-transition-00", stage: .recognizing,
              level: 0, phase: 0, reveal: 1, processingElapsed: 0),
        .init(name: "motion-15-recognizing-transition-50", stage: .recognizing,
              level: 0, phase: 0.65, reveal: 1, processingElapsed: 0.10),
        .init(name: "motion-16-recognizing-transition-100", stage: .recognizing,
              level: 0, phase: 1.3, reveal: 1, processingElapsed: 0.20),
        .init(name: "motion-17-recognizing-loop", stage: .recognizing,
              level: 0, phase: 2.2, reveal: 1, processingElapsed: 0.55),
        .init(name: "motion-18-building-prompt-transition-00", stage: .buildingPrompt,
              level: 0, phase: 0, reveal: 1, processingElapsed: 0),
        .init(name: "motion-19-building-prompt-transition-50", stage: .buildingPrompt,
              level: 0, phase: 0.65, reveal: 1, processingElapsed: 0.10),
        .init(name: "motion-20-building-prompt-transition-100", stage: .buildingPrompt,
              level: 0, phase: 1.3, reveal: 1, processingElapsed: 0.20),
        .init(name: "motion-21-building-prompt-loop", stage: .buildingPrompt,
              level: 0, phase: 2.2, reveal: 1, processingElapsed: 0.55),
        .init(name: "motion-22-hide-70", stage: .inserted,
              level: 0, phase: 0, reveal: 0.70, processingElapsed: nil),
        .init(name: "motion-23-hide-35", stage: .inserted,
              level: 0, phase: 0, reveal: 0.35, processingElapsed: nil),
        .init(name: "motion-24-hide-10", stage: .inserted,
              level: 0, phase: 0, reveal: 0.10, processingElapsed: nil),
    ]
    return stageFrames + motionFrames
}

/// Кадры для приёмки глазами: два режима рядом, на тёмной и на светлой
/// подложке, с движением и без. Именно здесь видно, различимы ли режимы —
/// прозрачная раскадровка про ореол и светлый фон ничего не говорит.
private func dictationHUDInspectionFrames() -> [DictationHUDExportFrame] {
    let dark = NSColor(calibratedWhite: 0.16, alpha: 1)
    let light = NSColor(calibratedWhite: 0.92, alpha: 1)
    return [
        .init(name: "look-01-dictation-dark", stage: .listening(.dictation),
              level: 0.58, phase: 2.4, reveal: 1, processingElapsed: nil,
              background: .dark, backdrop: dark),
        .init(name: "look-02-prompt-dark", stage: .listening(.prompt),
              level: 0.58, phase: 25.1, reveal: 1, processingElapsed: nil,
              background: .dark, backdrop: dark),
        .init(name: "look-03-dictation-light", stage: .listening(.dictation),
              level: 0.58, phase: 2.4, reveal: 1, processingElapsed: nil,
              background: .light, backdrop: light),
        .init(name: "look-04-prompt-light", stage: .listening(.prompt),
              level: 0.58, phase: 25.1, reveal: 1, processingElapsed: nil,
              background: .light, backdrop: light),
        // Те же фазы, что у 01/02, и только уровень другой: иначе «как ореол
        // отзывается на голос» не сравнить — сдвинутый гребень путает картину.
        .init(name: "look-05-dictation-quiet-dark", stage: .listening(.dictation),
              level: 0.04, phase: 2.4, reveal: 1, processingElapsed: nil,
              background: .dark, backdrop: dark),
        .init(name: "look-06-prompt-quiet-dark", stage: .listening(.prompt),
              level: 0.04, phase: 25.1, reveal: 1, processingElapsed: nil,
              background: .dark, backdrop: dark),
        .init(name: "look-07-dictation-reduced-motion-dark", stage: .listening(.dictation),
              level: 0.58, phase: 0, reveal: 1, processingElapsed: nil,
              reduceMotion: true, background: .dark, backdrop: dark),
        .init(name: "look-08-prompt-reduced-motion-dark", stage: .listening(.prompt),
              level: 0.58, phase: 0, reveal: 1, processingElapsed: nil,
              reduceMotion: true, background: .dark, backdrop: dark),
        .init(name: "look-09-dictation-reduced-motion-light", stage: .listening(.dictation),
              level: 0.58, phase: 0, reveal: 1, processingElapsed: nil,
              reduceMotion: true, background: .light, backdrop: light),
        .init(name: "look-10-prompt-reduced-motion-light", stage: .listening(.prompt),
              level: 0.58, phase: 0, reveal: 1, processingElapsed: nil,
              reduceMotion: true, background: .light, backdrop: light),
        // Полный размах на ЧЁРНОМ. Здесь эффект либо есть, либо его нет:
        // на тихой речи и на светлом фоне он неизбежно слабее, и судить по ним
        // о самой ленте нельзя. Фазы разные — переливы обязаны жить в движении,
        // а не собираться в одну удачную картинку.
        .init(name: "look-11-dictation-black-full", stage: .listening(.dictation),
              level: 0.98, phase: 2.4, reveal: 1, processingElapsed: nil,
              background: .dark, backdrop: .black),
        .init(name: "look-12-dictation-black-full-later", stage: .listening(.dictation),
              level: 0.98, phase: 7.9, reveal: 1, processingElapsed: nil,
              background: .dark, backdrop: .black),
        .init(name: "look-13-prompt-black-full", stage: .listening(.prompt),
              level: 0.98, phase: 25.1, reveal: 1, processingElapsed: nil,
              background: .dark, backdrop: .black),
        .init(name: "look-14-prompt-black-full-later", stage: .listening(.prompt),
              level: 0.98, phase: 28.6, reveal: 1, processingElapsed: nil,
              background: .dark, backdrop: .black),
    ]
}

/// На чём лента лежит, когда плиты за ней нет.
///
/// Плашка висит поверх ЧУЖОГО окна, и её тема — это тема системы, а не того,
/// что под ней. Совпадение бывает любым: тёмная тема над белым документом,
/// светлая над чёрным терминалом. Раньше вопрос закрывала пилюля — она сама
/// задавала фон; теперь ответ обязан быть виден на кадрах, а не в рассуждении.
///
/// Поэтому здесь ровно четыре угла (тема × настоящий фон) плюс середина, и
/// смотреть на них надо парами: `over-*-dark-*` — тема тёмная, `over-*-light-*` —
/// светлая. Хуже всего расхождение, и именно ради него живёт подложка.
private func dictationHUDBackdropFrames() -> [DictationHUDExportFrame] {
    let backdrops: [(String, NSColor)] = [
        ("white", .white),
        ("paper", NSColor(calibratedWhite: 0.97, alpha: 1)),
        ("grey", NSColor(calibratedWhite: 0.52, alpha: 1)),
        ("slate", NSColor(calibratedWhite: 0.22, alpha: 1)),
        ("black", .black),
    ]
    var frames: [DictationHUDExportFrame] = []
    for (name, backdrop) in backdrops {
        for (themeName, theme) in [("dark", DictationHUDCapsuleBackgroundStyle.dark),
                                   ("light", DictationHUDCapsuleBackgroundStyle.light)] {
            frames.append(.init(name: "over-\(name)-\(themeName)-dictation",
                                stage: .listening(.dictation),
                                level: 0.58, phase: 2.4, reveal: 1, processingElapsed: nil,
                                background: theme, backdrop: backdrop))
            frames.append(.init(name: "over-\(name)-\(themeName)-prompt",
                                stage: .listening(.prompt),
                                level: 0.58, phase: 25.1, reveal: 1, processingElapsed: nil,
                                background: theme, backdrop: backdrop))
            // Исход рисуется другим объектом — плашкой со своей подложкой, —
            // и его читаемость поверх чужого окна надо судить отдельно.
            frames.append(.init(name: "over-\(name)-\(themeName)-not-delivered",
                                stage: .notDelivered(.targetNeverRequestedText),
                                level: 0, phase: 0, reveal: 1, processingElapsed: nil,
                                background: theme, backdrop: backdrop))
        }
    }
    return frames
}

/// Все состояния исхода на тёмном и на светлом — плашка исхода целиком.
/// Пять форм, десять стадий: молчать здесь нельзя ни об одной.
private func dictationHUDOutcomeFrames() -> [DictationHUDExportFrame] {
    let stages: [(String, DictationHUDStage)] = [
        ("inserted", .inserted),
        ("not-delivered", .notDelivered(.targetNeverRequestedText)),
        ("nothing-heard", .nothingRecognized(savedToHistory: false)),
        ("nothing-recognized", .nothingRecognized(savedToHistory: true)),
        ("timed-out", .recognitionTimedOut),
        ("recognition-failed", .recognitionFailed(savedToHistory: true)),
        ("prompt-failed", .promptFailed(.invalidResult)),
        ("prompt-not-delivered", .promptNotDelivered(.targetNeverRequestedText)),
        ("prompt-saved", .promptSavedAfterFocusChange),
        ("refused", .refused(.secureInputActive)),
    ]
    let dark = NSColor(calibratedWhite: 0.16, alpha: 1)
    let light = NSColor(calibratedWhite: 0.92, alpha: 1)
    var frames: [DictationHUDExportFrame] = []
    for (index, entry) in stages.enumerated() {
        frames.append(.init(name: String(format: "chip-%02d-%@-dark", index + 1, entry.0),
                            stage: entry.1, level: 0, phase: 0, reveal: 1,
                            processingElapsed: nil, background: .dark, backdrop: dark))
        frames.append(.init(name: String(format: "chip-%02d-%@-light", index + 1, entry.0),
                            stage: entry.1, level: 0, phase: 0, reveal: 1,
                            processingElapsed: nil, background: .light, backdrop: light))
    }
    return frames
}

/// Приёмка палитр: каждая палитра в обоих режимах, на тёмной и на светлой
/// подложке, с движением и без. 3 × 2 × 2 × 2 = 24 кадра.
///
/// Смотреть надо именно парами: любая палитра обязана оставить диктовку тёплой,
/// а промпт холодным. Палитра, в которой режимы сравнялись, — брак, каким бы
/// красивым ни был отдельный кадр.
private func dictationHUDPaletteFrames() -> [DictationHUDExportFrame] {
    let dark = NSColor(calibratedWhite: 0.16, alpha: 1)
    let light = NSColor(calibratedWhite: 0.92, alpha: 1)
    var frames: [DictationHUDExportFrame] = []
    for palette in DictationHUDWavePalette.allCases {
        for purpose in [DictationRecordingPurpose.dictation, .prompt] {
            for (styleName, style, backdrop) in [
                ("dark", DictationHUDCapsuleBackgroundStyle.dark, dark),
                ("light", DictationHUDCapsuleBackgroundStyle.light, light),
            ] {
                for still in [false, true] {
                    let mode = purpose == .dictation ? "dictation" : "prompt"
                    let motion = still ? "still" : "motion"
                    frames.append(.init(
                        name: "palette-\(palette.rawValue)-\(mode)-\(styleName)-\(motion)",
                        stage: .listening(purpose),
                        level: 0.58,
                        // Замершая плашка стоит на нулевой фазе — ровно так её
                        // видит владелец с «Уменьшением движения».
                        phase: still ? 0 : (purpose == .dictation ? 2.4 : 25.1),
                        reveal: 1,
                        processingElapsed: nil,
                        reduceMotion: still,
                        background: style,
                        backdrop: backdrop,
                        palette: palette
                    ))
                }
            }
        }
    }
    return frames
}

/// Полный 120-fps таймлайн одной надиктовки: вход, живой голос, обработка,
/// подтверждение и выход. Уровень голоса синтетический и не читает микрофон.
///
/// Режимов два, и путь у них разный: обычная диктовка идёт в поле сразу после
/// распознавания, промпт по дороге ещё собирается Codex.
private func dictationHUDTimelineFrames(purpose: DictationRecordingPurpose,
                                        prefix: String) -> [DictationHUDExportFrame] {
    let framesPerSecond = 120.0
    let emptyLead = 0.35
    let listeningDuration = 6.20
    let recognizingDuration = 2.40
    let buildingPromptDuration = purpose == .prompt ? 2.40 : 0
    let resultDuration = DICTATION_HUD_INSERTED_SECONDS
    let emptyTail = 0.50

    let revealStart = emptyLead
    let listeningStart = revealStart + DICTATION_HUD_REVEAL_IN_DURATION
    let recognizingStart = listeningStart + listeningDuration
    let buildingPromptStart = recognizingStart + recognizingDuration
    let resultStart = buildingPromptStart + buildingPromptDuration
    let hideStart = resultStart + resultDuration
    let tailStart = hideStart + DICTATION_HUD_REVEAL_OUT_DURATION
    let totalDuration = tailStart + emptyTail
    let frameCount = Int((totalDuration * framesPerSecond).rounded())

    var frames: [DictationHUDExportFrame] = []
    frames.reserveCapacity(frameCount)
    var phase: CGFloat = 0

    for frameIndex in 0..<frameCount {
        let time = Double(frameIndex) / framesPerSecond
        let stage: DictationHUDStage
        let reveal: CGFloat
        let level: Float
        let processingElapsed: CGFloat?

        if time < revealStart {
            stage = .listening(purpose)
            reveal = 0
            level = 0
            processingElapsed = nil
        } else if time < listeningStart {
            stage = .listening(purpose)
            reveal = CGFloat((time - revealStart) / DICTATION_HUD_REVEAL_IN_DURATION)
            level = 0
            processingElapsed = nil
        } else if time < recognizingStart {
            stage = .listening(purpose)
            reveal = 1
            let voiceTime = time - listeningStart
            let syllables = pow(max(0, sin((voiceTime * 8.7) + 0.35)), 0.58)
            let phrasing = 0.58 + (0.42 * ((sin((voiceTime * 2.15) - 0.7) + 1) / 2))
            let detail = 0.78 + (0.22 * ((sin((voiceTime * 13.4) + 1.8) + 1) / 2))
            level = Float(min(0.94, 0.10 + (0.78 * syllables * phrasing * detail)))
            processingElapsed = nil
        } else if time < buildingPromptStart {
            stage = .recognizing
            reveal = 1
            level = 0
            processingElapsed = CGFloat(time - recognizingStart)
        } else if time < resultStart {
            stage = .buildingPrompt
            reveal = 1
            level = 0
            processingElapsed = CGFloat(time - buildingPromptStart)
        } else if time < hideStart {
            stage = .inserted
            reveal = 1
            level = 0
            processingElapsed = nil
        } else if time < tailStart {
            stage = .inserted
            reveal = 1 - CGFloat((time - hideStart) / DICTATION_HUD_REVEAL_OUT_DURATION)
            level = 0
            processingElapsed = nil
        } else {
            stage = .inserted
            reveal = 0
            level = 0
            processingElapsed = nil
        }

        phase += dictationHUDPhaseSpeed(stage: stage, level: level) / CGFloat(framesPerSecond)
        frames.append(.init(
            name: String(format: "\(prefix)-%05d", frameIndex),
            stage: stage,
            level: level,
            phase: phase,
            reveal: max(0, min(1, reveal)),
            processingElapsed: processingElapsed
        ))
    }
    return frames
}

func dictationHUDExportError(code: Int, message: String) -> NSError {
    NSError(
        domain: "smltlk.DictationHUDExport",
        code: code,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
