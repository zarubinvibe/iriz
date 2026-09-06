import IrizCore
// Живой снимок окна настроек и измерение стекла.
//
// Офскрин для стекла невозможен по построению: Liquid Glass сэмплирует то, что
// позади ОКНА, а в битмапе позади ничего нет. Значит снимать надо живьём -
// поднять окно поверх ИЗВЕСТНОЙ подложки и захватить область экрана.
//
// Отсюда же и способ мерить. Четыре круга подряд стекло судили кадром над
// тёмным терминалом, где матовую краску от стекла отличить нельзя в принципе,
// и все четыре раза проверка подтверждала то, чего не было. Прибор обязан
// давать число, которое дефект проваливает:
//
//   ПРОПУСКАНИЕ. Снять окно дважды - над чёрной подложкой и над белой.
//   Содержимое окна в обоих кадрах одно и то же, значит вся разница между
//   ними приходит из-за окна. Размытие СРЕДНЮЮ яркость не меняет, поэтому
//   сдвиг среднего и есть доля пропускания, независимо от радиуса размытия.
//
//   РАЗМЫТИЕ. Снять окно над вертикальными полосами. Полосы за окном дают
//   размах яркости; внутри окна размытие этот размах гасит, а «дырка»
//   сохраняет. Отношение размахов отделяет стекло от прозрачной пустоты.
//
// Краска даёт пропускание около нуля. Дырка даёт пропускание около единицы при
// сохранённом размахе полос. Стекло - высокое пропускание при задавленном
// размахе.
import AppKit
import IrizSettings
import SwiftUI

/// Что положить под окно на время съёмки.
enum IrizBackdrop: String {
    /// Мягкий градиент: кадр для разглядывания, не для замера.
    case gradient
    case black
    case white
    /// Вертикальные полосы: замер размытия.
    case stripes

    /// Ширина полосы. Крупная нарочно: размытие окна имеет радиус в десятки
    /// точек, и на узких полосах гасило бы их полностью даже у исправного
    /// стекла - прибор мерил бы свою же полосу, а не окно.
    static let stripeWidth: CGFloat = 120
}

@MainActor
private func makeBackdropWindow(kind: IrizBackdrop, frame: CGRect, dark: Bool) -> NSWindow {
    let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.level = .normal
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
    view.wantsLayer = true

    switch kind {
    case .black:
        view.layer?.backgroundColor = NSColor.black.cgColor
    case .white:
        view.layer?.backgroundColor = NSColor.white.cgColor
    case .stripes:
        view.layer?.backgroundColor = NSColor.black.cgColor
        var x: CGFloat = 0
        while x < frame.width {
            let stripe = CALayer()
            stripe.frame = CGRect(x: x, y: 0, width: IrizBackdrop.stripeWidth, height: frame.height)
            stripe.backgroundColor = NSColor.white.cgColor
            view.layer?.addSublayer(stripe)
            x += IrizBackdrop.stripeWidth * 2
        }
    case .gradient:
        let gradient = CAGradientLayer()
        gradient.frame = view.bounds
        gradient.colors = dark
            ? [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.20, alpha: 1).cgColor,
               NSColor(calibratedRed: 0.16, green: 0.10, blue: 0.14, alpha: 1).cgColor]
            : [NSColor(calibratedRed: 0.83, green: 0.87, blue: 0.93, alpha: 1).cgColor,
               NSColor(calibratedRed: 0.93, green: 0.89, blue: 0.84, alpha: 1).cgColor]
        view.layer?.addSublayer(gradient)
    }

    window.contentView = view
    window.orderFrontRegardless()
    return window
}

/// Снять окно настроек поверх заданной подложки.
///
/// Окно берётся у общей фабрики - того же, что открывается владельцу по
/// `--settings`. Своей копии окна у прибора нет и быть не должно.
/// Голое стекло без интерфейса: потолок пропускания этой системы.
///
/// Без него порог приёмки берётся из головы. Первый порог я задал 0.30 и он
/// оказался выдумкой: страница живого окна дала 0.288 при пустых панелях, то
/// есть выше физического потолка подняться было нельзя в принципе. Приёмка
/// теперь считается ДОЛЕЙ от потолка, а потолок меряется тем же прибором.
@MainActor
private func captureBareGlass(kind: IrizBackdrop, dark: Bool, to url: URL) throws {
    try captureOverBackdrop(kind: kind, dark: dark, to: url, bare: true)
}

/// Снять ЛЮБОЕ окно продукта поверх известной подложки.
///
/// Вынесено из съёмки настроек, когда кадры понадобились не только им:
/// витрине нужны меню, история и знакомство, и каждое - в трёх языках. Копия
/// этой процедуры на каждое окно разъехалась бы с первой же правкой отступа
/// подложки.
@MainActor
func captureWindowLive(_ window: NSWindow, kind: IrizBackdrop, dark: Bool, to url: URL) throws {
    guard let screen = NSScreen.main else {
        throw NSError(domain: "iriz.uilive", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Экрана нет."])
    }
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let origin = CGPoint(x: screen.frame.minX + 160, y: screen.frame.minY + 120)
    window.setFrameOrigin(origin)
    let frame = window.frame
    let backdrop = makeBackdropWindow(kind: kind, frame: frame.insetBy(dx: -160, dy: -160), dark: dark)
    window.orderFrontRegardless()
    // Стекло сэмплирует подложку своим тактом: снимок сразу после показа ловит
    // окно ещё без материала.
    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    let top = screen.frame.maxY - frame.origin.y - frame.height
    let rect = "\(Int(frame.origin.x)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-R", rect, url.path]
    try process.run()
    process.waitUntilExit()
    window.orderOut(nil)
    backdrop.orderOut(nil)
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "iriz.uilive", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "screencapture отказал на \(rect)."])
    }
}

@MainActor
private func captureOverBackdrop(kind: IrizBackdrop, dark: Bool, to url: URL,
                                 bare: Bool = false,
                                 page: SettingsPage = .keys) throws {
    guard let screen = NSScreen.main else {
        throw NSError(domain: "iriz.uilive", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Экрана нет."])
    }

    let window = makeIrizSettingsWindow(preview: true, page: page)
    if bare {
        // То же окно с теми же флагами, но вместо интерфейса - одно стекло.
        // Потолок меряется ТЕМ ЖЕ стеклом, что отгружается. Прежде здесь
        // стоял NSGlassEffectView, а продукт возит SwiftUI `.glassEffect`:
        // прибор считал потолок другого материала и врал в обе стороны.
        window.contentView = NSHostingView(rootView: IrizGlassBackdrop())
    }
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let origin = CGPoint(x: screen.frame.minX + 160, y: screen.frame.minY + 120)
    window.setFrameOrigin(origin)
    let frame = window.frame

    // Подложка с запасом: размытие тянет краску из области ШИРЕ окна, и по
    // кромке в кадр попадал бы рабочий стол вместо подложки.
    let backdrop = makeBackdropWindow(
        kind: kind,
        frame: frame.insetBy(dx: -160, dy: -160),
        dark: dark
    )
    window.orderFrontRegardless()

    // Стекло доезжает не в первом кадре: сэмплирование подложки идёт своим
    // тактом, и снимок сразу после показа ловит окно ещё без материала.
    RunLoop.current.run(until: Date().addingTimeInterval(1.2))

    let top = screen.frame.maxY - frame.origin.y - frame.height
    let rect = "\(Int(frame.origin.x)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-R", rect, url.path]
    try process.run()
    process.waitUntilExit()

    window.orderOut(nil)
    backdrop.orderOut(nil)

    guard process.terminationStatus == 0 else {
        throw NSError(domain: "iriz.uilive", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "screencapture отказал на \(rect)."])
    }
}

/// Кадры для разглядывания: светлый и тёмный вид над мягким градиентом.
@MainActor
func captureSettingsWindowLive(to directory: URL) throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    var written: [URL] = []
    // Тёмный и светлый вид первой страницы: по ним судят вид окна.
    for dark in [true, false] {
        let url = directory.appendingPathComponent("settings-live-\(dark ? "dark" : "light").png")
        try captureOverBackdrop(kind: .gradient, dark: dark, to: url, page: .keys)
        written.append(url)
    }
    // Страницы, которые показывают функции продукта. Каждая снимается сама, а
    // не описывается словами: снимок, собранный руками, устаревает первым.
    for page in [SettingsPage.history, .dictation, .meetings, .dictionary, .files] {
        let url = directory.appendingPathComponent("page-\(page.rawValue).png")
        try captureOverBackdrop(kind: .gradient, dark: false, to: url, page: page)
        written.append(url)
    }
    return written
}

/// Кадры для замера: три подложки на каждый вид.
@MainActor
func probeSettingsGlass(to directory: URL) throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    var written: [URL] = []
    for dark in [false, true] {
        for kind in [IrizBackdrop.black, .white, .stripes] {
            let name = "probe-\(dark ? "dark" : "light")-\(kind.rawValue).png"
            let url = directory.appendingPathComponent(name)
            try captureOverBackdrop(kind: kind, dark: dark, to: url)
            written.append(url)

            let bareName = "bare-\(dark ? "dark" : "light")-\(kind.rawValue).png"
            let bareURL = directory.appendingPathComponent(bareName)
            try captureBareGlass(kind: kind, dark: dark, to: bareURL)
            written.append(bareURL)
        }
    }
    return written
}
