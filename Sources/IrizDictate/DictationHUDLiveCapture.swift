// Прибор приговора для стеклянной плашки.
//
// ПОЧЕМУ НЕ РАСКАДРОВКА. Liquid Glass невозможно снять офскрином по построению:
// стекло сэмплирует то, что позади ОКНА, а в битмапе позади ничего нет, и кадр
// выходит пустым. Проверено пробой до начала работы, а не после.
//
// Поэтому плашка поднимается на экран поверх известной подложки, и кадр
// снимается захватом области. Правило приговора не ослаблено: кадр
// по-прежнему ровно 248 x 74 физических пикселя, потому что область
// захватывается ровно по размеру плашки, а экран ретиновый.
import AppKit

@available(macOS 26.0, *)
@MainActor
public func captureDictationHUDLiveFrames(to directory: URL) throws -> [URL] {
    var all: [URL] = []
    for choice in DictationHUDSizeChoice.allCases {
        all += try captureDictationHUDLiveFrames(to: directory, size: choice)
    }
    return all
}

@available(macOS 26.0, *)
@MainActor
public func captureDictationHUDLiveFrames(to directory: URL,
                                          size choice: DictationHUDSizeChoice) throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    guard let screen = NSScreen.main else {
        throw dictationHUDExportError(code: 10, message: "Экрана нет - живой кадр снять негде.")
    }

    let size = dictationHUDCollapsedSize(choice)
    let barCount = dictationHUDBarCount(choice)
    // Плашка встаёт в спокойное место экрана, подложка - шире её на поле,
    // чтобы стеклу было что преломлять по краям.
    let origin = CGPoint(x: screen.frame.minX + 260, y: screen.frame.minY + 260)
    let pad: CGFloat = 44

    let backdropWindow = NSWindow(
        contentRect: CGRect(x: origin.x - pad, y: origin.y - pad,
                            width: size.width + pad * 2, height: size.height + pad * 2),
        styleMask: [.borderless], backing: .buffered, defer: false)
    backdropWindow.level = .floating
    backdropWindow.isOpaque = true
    backdropWindow.hasShadow = false

    let panel = NSWindow(contentRect: CGRect(origin: origin, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    panel.level = .floating
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = true

    let glass = DictationHUDGlassStack(frame: CGRect(origin: .zero, size: size))
    // Внутри стекла живёт звуковая волна. Ленту из спектральных нитей владелец
    // отменил 03.09.2026: «отказываемся от этих вот линий красных и фиолетовых...
    // давай вернём вот эти вот звуковые волны».
    let bars = DictationHUDWaveBarsView(frame: .zero)
    glass.bodyContent = bars
    panel.contentView = glass

    var written: [URL] = []
    for scene in dictationHUDLiveScenes() {
        backdropWindow.contentView = dictationHUDBackdropView(scene.backdrop,
                                                              size: backdropWindow.frame.size)
        // Вид окна задаётся ЯВНО: стекло `.regular` адаптируется к теме
        // приложения, а у прибора её никто не ставил - кадр брал системную и
        // врал про тему. Поймано кадром: тёмные сцены вышли светлыми.
        let appearance = NSAppearance(named: scene.background == .dark ? .darkAqua : .aqua)
        panel.appearance = appearance
        backdropWindow.appearance = appearance
        backdropWindow.orderFrontRegardless()
        panel.orderFrontRegardless()

        let tone = dictationHUDWaveTone(stage: scene.stage, purpose: scene.purpose)
        bars.tint = dictationHUDWaveColor(tone)
        bars.glyph = dictationHUDWaveGlyph(for: scene.stage, purpose: scene.purpose)
        bars.lineIntensity = tone == .failure ? 1.0 : 0.55
        // Тишина сливает волну в полосу так же, как обрыв: нет сигнала - нет
        // и волны. Берётся сильнейшее из двух, иначе тихий обрыв рисовал бы
        // столбики поверх черты.
        bars.collapse = max(tone == .failure ? 1 : 0,
                            dictationHUDSilenceCollapse(levels: scene.trail))
        // Вспышка за плашкой на КОНЦЕ работы, а цвет её называет исход:
        // зелёный успех обычной диктовки, синий успех промпт-режима,
        // красный обрыв.
        glass.flash(dictationHUDWaveColor(tone),
                    strength: dictationHUDWaveFlashStrength(stage: scene.stage))
        glass.haloPhase = scene.phase
        bars.phase = scene.phase
        // «Думает» показывает собственную волну работы, а не последний кадр
        // голоса: иначе она неотличима от записи, только застывшей.
        switch scene.stage {
        case .recognizing, .buildingPrompt:
            bars.heights = dictationHUDWaveBarHeights(
                levels: dictationHUDWorkingLevels(phase: scene.phase, count: barCount),
                count: barCount)
        default:
            bars.heights = dictationHUDWaveBarHeights(levels: scene.trail, count: barCount)
        }
        let form = dictationHUDGlassForm(for: scene.stage)
        glass.apply(dictationHUDGlassShape(form: form, in: size), animated: false)
        bars.needsDisplay = true

        // Оборот цикла событий: стекло собирается композитором, и снимать
        // раньше - значит снять его недособранным.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))

        let url = directory.appendingPathComponent("\(choice.rawValue)-\(scene.name).png")
        try dictationHUDCaptureRegion(origin: origin, size: size, screen: screen, to: url)
        written.append(url)
    }

    panel.orderOut(nil)
    backdropWindow.orderOut(nil)
    return written
}

private struct DictationHUDLiveScene {
    let name: String
    let stage: DictationHUDStage
    /// История уровней, от старой к новой: волна показывает ФРАЗУ, а не одно
    /// число, размноженное по ширине.
    let trail: [Float]
    let purpose: DictationRecordingPurpose
    let phase: CGFloat
    let background: DictationHUDCapsuleBackgroundStyle
    let backdrop: NSColor
}

/// Сцены приговора. Подложки разные намеренно: плашка живёт поверх ЧУЖОГО
/// окна, и стекло на белом документе и на тёмном терминале выглядит по-разному.
private func dictationHUDLiveScenes() -> [DictationHUDLiveScene] {
    let dark = NSColor(calibratedWhite: 0.13, alpha: 1)
    let light = NSColor(calibratedWhite: 0.94, alpha: 1)
    let paper = NSColor(calibratedRed: 0.94, green: 0.92, blue: 0.87, alpha: 1)

    // Правдоподобная фраза: слоги, паузы между словами, затухание к началу.
    // Ровный шум показал бы забор, а волна обязана быть ПОКАЗАТЕЛЬНОЙ.
    func speech(loud: Float) -> [Float] {
        let n = 48
        return (0..<n).map { index in
            let t = Float(index) / Float(n - 1)
            let syllable = abs(sin(t * 9.4)) * 0.75 + abs(sin(t * 21.0)) * 0.25
            let pause: Float = (t > 0.44 && t < 0.52) || (t > 0.76 && t < 0.80) ? 0.12 : 1
            return min(1, max(0, syllable * pause * loud))
        }
    }

    return [
        .init(name: "01-listening-dark", stage: .listening(.dictation), trail: speech(loud: 0.92), purpose: .dictation,
              phase: 2.4, background: .dark, backdrop: dark),
        .init(name: "02-listening-quiet-dark", stage: .listening(.dictation), trail: speech(loud: 0.18), purpose: .dictation,
              phase: 2.4, background: .dark, backdrop: dark),
        .init(name: "03-listening-light", stage: .listening(.dictation), trail: speech(loud: 0.92), purpose: .dictation,
              phase: 2.4, background: .light, backdrop: light),
        .init(name: "04-prompt-dark", stage: .listening(.prompt), trail: speech(loud: 0.92), purpose: .prompt,
              phase: 25.1, background: .dark, backdrop: dark),
        .init(name: "05-thinking-dark", stage: .recognizing, trail: speech(loud: 0.45), purpose: .dictation,
              phase: 2.2, background: .dark, backdrop: dark),
        .init(name: "06-done-dark", stage: .inserted, trail: speech(loud: 0.30), purpose: .dictation,
              phase: 0, background: .dark, backdrop: dark),
        .init(name: "09-done-prompt-dark", stage: .inserted, trail: speech(loud: 0.30), purpose: .prompt,
              phase: 0, background: .dark, backdrop: dark),
        // Настоящая тишина, а не тихая речь: владелец молчит, и волна обязана
        // слиться в полосу, а не рассыпаться цепочкой точек.
        .init(name: "11-done-prompt-bolt-dark", stage: .inserted, trail: speech(loud: 0.30),
              purpose: .prompt, phase: 0, background: .dark, backdrop: dark),
        .init(name: "10-silence-dark", stage: .listening(.dictation),
              trail: Array(repeating: 0.004, count: 48), purpose: .dictation,
              phase: 2.4, background: .dark, backdrop: dark),
        .init(name: "07-rescue-dark", stage: .notDelivered(.targetNeverRequestedText), trail: speech(loud: 0.55), purpose: .dictation,
              phase: 0, background: .dark, backdrop: dark),
        .init(name: "08-rescue-paper", stage: .notDelivered(.targetNeverRequestedText), trail: speech(loud: 0.55), purpose: .dictation,
              phase: 0, background: .light, backdrop: paper),
    ]
}

private func dictationHUDBackdropView(_ color: NSColor, size: CGSize) -> NSView {
    let view = NSView(frame: CGRect(origin: .zero, size: size))
    view.wantsLayer = true
    view.layer?.backgroundColor = color.cgColor
    return view
}

/// Захват области экрана ровно по плашке. Координаты `screencapture` считаются
/// от ВЕРХНЕГО левого угла, а окна - от нижнего: без пересчёта кадр уезжает.
private func dictationHUDCaptureRegion(origin: CGPoint, size: CGSize,
                                       screen: NSScreen, to url: URL) throws {
    let top = screen.frame.maxY - origin.y - size.height
    let rect = "\(Int(origin.x.rounded())),\(Int(top.rounded())),"
        + "\(Int(size.width.rounded())),\(Int(size.height.rounded()))"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-R", rect, url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw dictationHUDExportError(code: 11,
                                      message: "screencapture отказал на области \(rect).")
    }
}
