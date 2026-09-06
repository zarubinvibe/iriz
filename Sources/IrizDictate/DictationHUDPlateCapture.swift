// Съёмка НАСТОЯЩЕЙ плашки во всех её формах.
//
// Прежний прибор (`--capture-hud-live`) собирает стекло и волну руками, минуя
// поверхность: он снимает ФОРМУ, а не плашку. Пока форм было три и все они
// сводились к геометрии стекла, разницы не было. С покоем, раскрытием по
// щелчку и кнопками разница стала решающей: собранный руками кадр не покажет
// ни кнопок, ни панели, ни размера окна в покое - то есть ровно того, что
// владелец просил и что чаще всего ломается.
//
// Здесь поднимается та же DictationHUDPanelSurface, которой живёт продукт, и
// кормится тем же DictationHUDContent, что приходит из презентера. Кадр
// снимается с экрана: стекло офскрином не снять по построению.
import AppKit
import Foundation

/// Одна сцена съёмки: как назвать кадр и что подать в плашку.
private struct DictationHUDPlateScene {
    let name: String
    let content: DictationHUDContent
    /// Сцена снимается «под мышью»: полоска кнопок раскрывается только на
    /// наведении, и без него прибор снял бы форму, которой владелец не увидит.
    var hovered: Bool = false
    /// Сцена переноса: плашку тащат, экран мутнеет, зона подсвечена. Снимается
    /// целым экраном, а не по кадру плашки: смысл сцены как раз в остальном
    /// экране.
    var dragging: Bool = false
    /// Какая кнопка полоски под курсором. `nil` - ни одна.
    var hoveredButton: Int?
    /// Сколько крутить цикл событий до снимка. Морфу нужно доехать: снимок
    /// раньше времени поймает плашку на полпути и соврёт про обе формы.
    let settle: TimeInterval
}

/// Снять плашку во всех формах над градиентной подложкой.
///
/// Возвращает пути кадров. Каждая форма снимается в светлой и тёмной теме:
/// плашка стоит поверх ЧУЖОГО окна, и какого оно тона, заранее не знает никто.
@available(macOS 26.0, *)
@MainActor
public func captureDictationHUDPlateScenes(to directory: URL) throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    guard let screen = NSScreen.main else {
        throw dictationHUDExportError(code: 10, message: "Экрана нет - живой кадр снять негде.")
    }

    let scenes: [DictationHUDPlateScene] = [
        .init(name: "resting",
              content: dictationHUDContent(stage: .resting, level: 0,
                                           reduceMotion: false, historyHint: ""),
              settle: 0.9),
        .init(name: "hover",
              content: dictationHUDContent(stage: .resting, level: 0,
                                           reduceMotion: false, historyHint: ""),
              hovered: true,
              settle: 1.2),
        .init(name: "hover-label",
              content: dictationHUDContent(stage: .resting, level: 0,
                                           reduceMotion: false, historyHint: ""),
              hovered: true,
              hoveredButton: 1,
              settle: 1.2),
        .init(name: "drag",
              content: dictationHUDContent(stage: .resting, level: 0,
                                           reduceMotion: false, historyHint: ""),
              dragging: true,
              settle: 0.6),
        .init(name: "open-empty",
              content: dictationHUDContent(stage: .resting, level: 0,
                                           reduceMotion: false, historyHint: "",
                                           expanded: true),
              settle: 1.1),
        .init(name: "open-text",
              content: dictationHUDContent(stage: .listening(.dictation), level: 0.5,
                                           reduceMotion: false, historyHint: "",
                                           transcript: "Проверка связи. Текст появляется прямо здесь, пока я говорю.",
                                           expanded: true, isRecording: true),
              settle: 1.1),
        .init(name: "listening",
              content: dictationHUDContent(stage: .listening(.dictation), level: 0.55,
                                           reduceMotion: false, historyHint: ""),
              settle: 0.9),
    ]

    var written: [URL] = []
    for dark in [false, true] {
        let surface = DictationHUDPanelSurface()
        // Полоска спрашивает язык у управления: без него она не соберётся, и
        // кадр покажет пустую плашку вместо ряда кнопок.
        surface.controls = DictationHUDControls(
            currentLanguage: { .russian },
            setLanguage: { _ in },
            openSettings: {},
            openHistory: {}
        )
        surface.prewarm()
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Плашка стоит там, куда её поставил владелец: позиция живёт в
        // настройках и переживает запуск. Значит подложку кладём ПОД НЕЁ, а не
        // в свой угол экрана - иначе прибор снимет стекло над рабочим столом.
        // Поймано кадром: за плашкой оказался терминал.
        surface.present(dictationHUDContent(stage: .resting, level: 0,
                                            reduceMotion: false, historyHint: ""))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let plate = surface.panelScreenFrame ?? CGRect(x: screen.frame.midX,
                                                       y: screen.frame.midY,
                                                       width: 200, height: 60)
        let field = CGRect(x: plate.midX - 340, y: plate.midY - 240,
                           width: 680, height: 480)
        let backdrop = NSWindow(contentRect: field, styleMask: [.borderless],
                                backing: .buffered, defer: false)
        backdrop.level = .floating
        backdrop.isOpaque = true
        backdrop.hasShadow = false
        backdrop.appearance = appearance
        backdrop.contentView = dictationHUDPlateBackdrop(size: field.size, dark: dark)
        backdrop.orderFrontRegardless()

        for scene in scenes {
            surface.present(scene.content)
            surface.appearanceOverride = appearance
            surface.raisePanel()
            if scene.hovered { surface.hudMouseEntered() } else { surface.hudMouseExited() }
            RunLoop.current.run(until: Date().addingTimeInterval(scene.settle))
            if scene.hovered {
                surface.hoverStripButton(scene.hoveredButton)
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            if scene.dragging {
                // Подложка прибора тут мешает: сцена про ВЕСЬ экран, а не про
                // стекло над градиентом.
                backdrop.orderOut(nil)
                // Тащим к правому нижнему углу: там владелец увидит и мутный
                // экран, и подсвеченную треть.
                let from = surface.panelScreenFrame ?? .zero
                surface.hudMouseDown(at: CGPoint(x: from.midX, y: from.midY))
                surface.hudMouseDragged(to: CGPoint(x: screen.frame.maxX - 260,
                                                    y: screen.frame.minY + 120))
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            let url = directory.appendingPathComponent("plate-\(scene.name)-\(dark ? "dark" : "light").png")
            if scene.dragging {
                try dictationHUDCaptureScreen(screen: screen, to: url)
                // Отпускаем ровно там, где тащили: сцена кончилась, плашка
                // примагничивается, затемнение уходит.
                surface.hudMouseUp(at: CGPoint(x: screen.frame.maxX - 260,
                                               y: screen.frame.minY + 120))
                backdrop.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            } else {
                try dictationHUDCapturePlate(surface: surface, screen: screen, to: url)
            }
            written.append(url)
        }
        surface.dismiss()
        backdrop.orderOut(nil)
    }
    return written
}

/// Подложка для разглядывания: мягкая, но с перепадом - на ровной заливке
/// преломление стекла не читается вовсе.
@MainActor
private func dictationHUDPlateBackdrop(size: CGSize, dark: Bool) -> NSView {
    let view = NSView(frame: CGRect(origin: .zero, size: size))
    view.wantsLayer = true
    let layer = CAGradientLayer()
    layer.frame = view.bounds
    layer.colors = dark
        ? [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 1).cgColor,
           NSColor(calibratedRed: 0.28, green: 0.20, blue: 0.32, alpha: 1).cgColor]
        : [NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.90, alpha: 1).cgColor,
           NSColor(calibratedRed: 0.72, green: 0.80, blue: 0.92, alpha: 1).cgColor]
    layer.startPoint = CGPoint(x: 0, y: 0)
    layer.endPoint = CGPoint(x: 1, y: 1)
    view.layer?.addSublayer(layer)
    return view
}

/// Снять экран целиком: сцена переноса про весь экран, а не про плашку.
@MainActor
private func dictationHUDCaptureScreen(screen: NSScreen, to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw dictationHUDExportError(code: 11, message: "screencapture отказал на экране целиком.")
    }
}

/// Снять область экрана по кадру самой плашки, с полем под преломление.
@MainActor
private func dictationHUDCapturePlate(surface: DictationHUDPanelSurface,
                                      screen: NSScreen,
                                      to url: URL) throws {
    guard let frame = surface.panelScreenFrame else {
        throw dictationHUDExportError(code: 12, message: "Плашка не поднялась - снимать нечего.")
    }
    let pad: CGFloat = 28
    // Поле обрезается по экрану САМИМ прибором. `screencapture -R` за кромкой
    // не ругается - он молча отдаёт кадр короче запрошенного, и разбор кадра
    // идёт по картинке, у которой отрезан низ. Поймано 06.09.2026: раскрытая
    // панель в месте «низ-центр» приезжала без нижней трети, и понять по кадру,
    // панель это вылезла или прибор обрезал, было нельзя.
    let region = frame.insetBy(dx: -pad, dy: -pad).intersection(screen.frame)
    let top = screen.frame.maxY - region.origin.y - region.height
    let rect = "\(Int(region.origin.x.rounded())),\(Int(top.rounded())),"
        + "\(Int(region.width.rounded())),\(Int(region.height.rounded()))"
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

/// Замер стекла ПЛАШКИ: та же метода, что у окна настроек.
///
/// Плашка снимается над чёрной, белой и полосатой подложкой с одним и тем же
/// содержимым. Содержимое вычитается разностью кадров, и остаётся только то,
/// что пришло из-за окна: `(белое - чёрное) / 255` и есть пропускание.
///
/// Зачем отдельно от окна настроек. Решение владельца 06.09.2026: «всё стекло,
/// которое просто без текста, должно быть максимально прозрачным… в том числе
/// это стекло у самой плашки». Пока плашку не мерили, правило про неё жило
/// только в прозе - а проза исполняется вероятностно.
///
/// Снимается кадр САМОЙ плашки, без поля: поле - это подложка, и она увела бы
/// пропускание к единице независимо от стекла.
@available(macOS 26.0, *)
@MainActor
public func probeDictationHUDPlateGlass(to directory: URL) throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    guard let screen = NSScreen.main else {
        throw dictationHUDExportError(code: 10, message: "Экрана нет - замер невозможен.")
    }
    // Две формы правила: покой и запись. Обе несут стекло БЕЗ текста, и обе
    // обязаны быть в классе «прозрачное».
    let forms: [(String, DictationHUDContent)] = [
        ("resting", dictationHUDContent(stage: .resting, level: 0,
                                        reduceMotion: true, historyHint: "")),
        ("listening", dictationHUDContent(stage: .listening(.dictation), level: 0.55,
                                          reduceMotion: true, historyHint: "")),
    ]

    let surface = DictationHUDPanelSurface()
    surface.controls = DictationHUDControls(currentLanguage: { .russian },
                                            setLanguage: { _ in },
                                            openSettings: {},
                                            openHistory: {})
    surface.prewarm()
    surface.appearanceOverride = NSAppearance(named: .aqua)

    var written: [URL] = []
    for (name, content) in forms {
        surface.present(content)
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        guard let frame = surface.panelScreenFrame else {
            throw dictationHUDExportError(code: 12, message: "Плашка не поднялась - снимать нечего.")
        }
        for kind in ["black", "white", "stripes"] {
            // Подложка ШИРЕ плашки: стекло тянет краску из области вокруг окна,
            // и по кромке в кадр попал бы рабочий стол вместо подложки.
            let field = frame.insetBy(dx: -180, dy: -180)
            let backdrop = dictationHUDProbeBackdrop(kind: kind, frame: field)
            backdrop.orderFrontRegardless()
            surface.raisePanel()
            // Стекло сэмплирует подложку своим тактом: снимок сразу после
            // показа ловит окно ещё без материала.
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let url = directory.appendingPathComponent("plate-glass-\(name)-\(kind).png")
            try dictationHUDCaptureRegion(frame, screen: screen, to: url)
            backdrop.orderOut(nil)
            written.append(url)
        }
    }
    surface.dismiss()
    return written
}

/// Подложка замера: чёрная, белая или полосатая. Полоса широкая нарочно - на
/// узкой размытие гасит перепад целиком даже у исправного стекла.
@MainActor
private func dictationHUDProbeBackdrop(kind: String, frame: CGRect) -> NSWindow {
    let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.level = .normal
    window.isOpaque = true
    window.hasShadow = false
    window.appearance = NSAppearance(named: .aqua)
    let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
    view.wantsLayer = true
    switch kind {
    case "white":
        view.layer?.backgroundColor = NSColor.white.cgColor
    case "stripes":
        view.layer?.backgroundColor = NSColor.black.cgColor
        var x: CGFloat = 0
        while x < frame.width {
            let stripe = CALayer()
            stripe.frame = CGRect(x: x, y: 0, width: 40, height: frame.height)
            stripe.backgroundColor = NSColor.white.cgColor
            view.layer?.addSublayer(stripe)
            x += 80
        }
    default:
        view.layer?.backgroundColor = NSColor.black.cgColor
    }
    window.contentView = view
    return window
}

/// Снять область экрана ровно по кадру.
@MainActor
private func dictationHUDCaptureRegion(_ frame: CGRect, screen: NSScreen, to url: URL) throws {
    let top = screen.frame.maxY - frame.origin.y - frame.height
    let rect = "\(Int(frame.origin.x.rounded())),\(Int(top.rounded())),"
        + "\(Int(frame.width.rounded())),\(Int(frame.height.rounded()))"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-R", rect, url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw dictationHUDExportError(code: 11, message: "screencapture отказал на области \(rect).")
    }
}
