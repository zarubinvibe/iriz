import AppKit
import SwiftUI
import IrizDictate
import IrizSettings

// Прибор раскадровки ПОВЕРХНОСТЕЙ приложения.
//
// Приговор внешнему виду выносится только по снимку в натуральную величину -
// то же правило, что у ленты, и по той же причине: пять отказов ленты подряд
// стоили ровно того, что правило жило в прозе. Разница в том, что у ленты
// поверхность одна, а здесь их четыре: меню, настройки, история и плашка
// исхода. Пока их нельзя снять ОДНОЙ командой, свежих снимков не будет
// никогда, и правка визуала снова пойдёт по памяти.
//
// Приём тот же, что у раскадровки HUD: рисуем вне экрана, окон не поднимаем,
// фокус не трогаем. Масштаб два - обычный (1x) и ретина (2x); тема две -
// светлая и тёмная.

/// Какие масштабы снимаются. 1x нужен: внешний монитор без ретины у владельца
/// есть, и вёрстка на нём разваливается иначе.
private let UI_SHOT_SCALES: [CGFloat] = [1, 2]

private struct UISurfaceShot {
    let name: String
    let width: CGFloat
    /// `nil` - высота по содержимому. Панель меню растёт по содержимому, и
    /// снимок с запасом врал бы про её размер пустой полосой снизу.
    let height: CGFloat?
    let view: AnyView
}

/// Снимает все поверхности приложения в датированный каталог.
/// - Returns: пути к снимкам.
@MainActor
func exportUISurfaceShots(to directory: URL, appDelegate: AppDelegate) throws -> [URL] {
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )

    var written: [URL] = []
    for shot in uiSurfaceShots(appDelegate: appDelegate) {
        for scheme in [ColorScheme.light, .dark] {
            for scale in UI_SHOT_SCALES {
                let theme = scheme == .light ? "light" : "dark"
                let name = "\(shot.name)-\(theme)@\(Int(scale))x.png"
                let url = directory.appendingPathComponent(name)
                guard let data = renderUISurface(shot: shot, scheme: scheme, scale: scale) else {
                    throw NSError(domain: "iriz.uishots", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Не удалось отрисовать поверхность \(name)."
                    ])
                }
                try data.write(to: url, options: .atomic)
                written.append(url)
            }
        }
    }
    return written
}

@MainActor
private func renderUISurface(shot: UISurfaceShot, scheme: ColorScheme, scale: CGFloat) -> Data? {
    // ImageRenderer сюда не годится, и это поймано снимком, а не рассуждением:
    // Picker, Toggle и TextField он рисует жёлтой заглушкой «не поддерживается».
    // Прибор врал бы раньше кода. Поэтому вид живёт в НАСТОЯЩЕМ окне, только
    // не поднятом на экран: тогда AppKit рисует свои контролы сам.
    let hosting = NSHostingView(rootView: AnyView(shot.view))
    hosting.frame = CGRect(x: 0, y: 0, width: shot.width, height: shot.height ?? 100)

    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: shot.width, height: shot.height ?? 100),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    window.appearance = appearance
    window.contentView = hosting
    window.isReleasedWhenClosed = false
    // Ни orderFront, ни makeKey: окно нужно только как среда рисования.
    // Фокус чужого приложения прибор не трогает - то же правило, что у HUD.
    // Кадр уезжает далеко за пределы любого экрана, поэтому окно физически
    // невидимо, но SwiftUI считает его живым и строит дерево вьюх. Без этого
    // снимок выходил ПУСТЫМ: дерево не успевало собраться ни разу.
    window.setFrameOrigin(CGPoint(x: -30000, y: -30000))
    window.orderBack(nil)
    hosting.layoutSubtreeIfNeeded()
    // Дерево SwiftUI собирается на обороте цикла событий, а не в этом кадре.
    for _ in 0..<3 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    hosting.layoutSubtreeIfNeeded()

    // Высота по содержимому меряется ПОСЛЕ того, как дерево собралось.
    let size: CGSize
    if let fixed = shot.height {
        size = CGSize(width: shot.width, height: fixed)
    } else {
        let fitting = hosting.fittingSize
        size = CGSize(width: shot.width, height: max(40, fitting.height.rounded()))
        hosting.frame = CGRect(origin: .zero, size: size)
        window.setContentSize(size)
        hosting.layoutSubtreeIfNeeded()
    }
    window.displayIfNeeded()

    let pixelWidth = Int((size.width * scale).rounded())
    let pixelHeight = Int((size.height * scale).rounded())
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
    ) else { return nil }
    bitmap.size = size
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    window.orderOut(nil)
    window.contentView = nil

    // Подложку панели рисует NSPanel, которого вне экрана нет: снимок выходит
    // белым текстом по прозрачному, а прозрачность глаз читает как светлое.
    // Поэтому кадр кладётся на непрозрачный фон темы - тот же, что даёт окно.
    guard let opaque = uiShotOnOpaqueBackdrop(bitmap,
                                              size: size,
                                              pixels: CGSize(width: pixelWidth, height: pixelHeight),
                                              appearance: appearance) else { return nil }
    // Прибор врёт раньше кода: пустой кадр надо ловить здесь, а не глазами через
    // тридцать снимков. Одноцветный снимок поверхности - это отказ прибора.
    guard !uiShotIsBlank(opaque) else { return nil }
    return opaque.representation(using: .png, properties: [:])
}

/// Кладёт прозрачный кадр на непрозрачный фон окна выбранной темы.
@MainActor
private func uiShotOnOpaqueBackdrop(_ source: NSBitmapImageRep,
                                    size: CGSize,
                                    pixels: CGSize,
                                    appearance: NSAppearance?) -> NSBitmapImageRep? {
    guard let output = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixels.width),
        pixelsHigh: Int(pixels.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    // Размер в точках ставится ДО создания контекста: иначе контекст живёт в
    // пикселях, и заливка ложится в четверть кадра.
    output.size = size
    guard let context = NSGraphicsContext(bitmapImageRep: output) else { return nil }

    let isDark = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    var backdrop = isDark
        ? NSColor(calibratedWhite: 0.13, alpha: 1)
        : NSColor(calibratedWhite: 0.93, alpha: 1)
    appearance?.performAsCurrentDrawingAppearance {
        if let resolved = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) {
            backdrop = resolved
        }
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let rect = CGRect(origin: .zero, size: size)
    backdrop.withAlphaComponent(1).setFill()
    NSBezierPath(rect: rect).fill()
    source.draw(in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return output
}

/// Одноцветный кадр. Настоящая поверхность несёт текст и разделители, поэтому
/// два разных цвета в ней есть всегда.
private func uiShotIsBlank(_ bitmap: NSBitmapImageRep) -> Bool {
    guard let first = bitmap.colorAt(x: 0, y: 0) else { return true }
    let stepX = max(1, bitmap.pixelsWide / 64)
    let stepY = max(1, bitmap.pixelsHigh / 64)
    var y = 0
    while y < bitmap.pixelsHigh {
        var x = 0
        while x < bitmap.pixelsWide {
            if let color = bitmap.colorAt(x: x, y: y), color != first { return false }
            x += stepX
        }
        y += stepY
    }
    return true
}

@MainActor
private func uiSurfaceShots(appDelegate: AppDelegate) -> [UISurfaceShot] {
    var shots: [UISurfaceShot] = []

    // Меню строки меню. Ширина - та же, что в MenuContentView (300 pt),
    // высота с запасом: панель растёт по содержимому.
    for (name, state) in uiShotMenuStates() {
        shots.append(UISurfaceShot(name: "menu-\(name)",
                                   width: 300,
                                   height: nil,
                                   view: AnyView(MenuContentView(state: state, appDelegate: appDelegate))))
    }

    // Настройки. Форма длинная, поэтому снимок один и высокий: разрезать его
    // по секциям может глаз, а вот шов между секциями на разрезанном снимке
    // уже не увидеть.
    shots.append(UISurfaceShot(name: "settings",
                               width: 680,
                               height: nil,
                               view: AnyView(IrizSettingsView(preview: true))))

    // История: список, пустой список и спасение текста.
    for kind in DictationHistoryShotKind.allCases {
        shots.append(UISurfaceShot(name: "history-\(kind.rawValue)",
                                   width: 620,
                                   height: 520,
                                   view: dictationHistoryShotView(kind)))
    }

    return shots
}

/// Состояния меню, которые обязаны попасть в приёмку: рабочее, аварийное и
/// пауза. Аварийное - потому что именно оно ломает вёрстку первой строкой.
@MainActor
private func uiShotMenuStates() -> [(String, MenuState)] {
    func base() -> MenuState {
        let state = MenuState()
        state.accessibilityOK = true
        state.inputMonitoringOK = true
        state.microphoneOK = true
        state.layouts = [
            .init(id: "ru", name: "Русская", isCurrent: true),
            .init(id: "abc", name: "ABC", isCurrent: false),
        ]
        state.currentLayoutID = "ru"
        state.currentLayoutName = "Русская"
        state.mode = .fixing
        state.todayAutoswitches = 128
        state.todayUndos = 4
        state.dictationState = .ready
        return state
    }

    let normal = base()

    let alarm = base()
    alarm.accessibilityOK = false
    alarm.mark = MarkState(mode: .fixing, alarm: .noPermission)

    let paused = base()
    paused.mode = .paused
    paused.mark = MarkState(mode: .paused, alarm: .none)

    // Тап отвалился при выданных разрешениях: своя строка, своя причина. Без
    // снимка это состояние никто не увидит до первой настоящей поломки.
    let tapDead = base()
    tapDead.inputTapOK = false
    tapDead.mark = MarkState(mode: .fixing, alarm: .noPermission)

    return [("normal", normal), ("alarm", alarm), ("paused", paused), ("tap-dead", tapDead)]
}
