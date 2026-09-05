// Живой снимок окна настроек.
//
// Офскрин для стекла невозможен по построению: Liquid Glass сэмплирует то, что
// позади ОКНА, а в битмапе позади ничего нет. Ровно это уже поймано пробой на
// плашке записи. Окно настроек теперь тоже на стекле, значит и снимать его надо
// живым - поднять на экран поверх известной подложки и захватить область.
import AppKit
import SwiftUI
import IrizSettings

@MainActor
func captureSettingsWindowLive(to directory: URL) throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    guard let screen = NSScreen.main else {
        throw NSError(domain: "iriz.uilive", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Экрана нет."])
    }

    let size = CGSize(width: 700, height: 760)
    let origin = CGPoint(x: screen.frame.minX + 200, y: screen.frame.minY + 160)
    var written: [URL] = []

    for dark in [true, false] {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        // Подложка: имитирует то, что лежит под окном. Без неё стеклу нечего
        // преломлять, и кадр соврёт про прозрачность.
        let backdrop = NSWindow(contentRect: CGRect(x: origin.x - 60, y: origin.y - 60,
                                                    width: size.width + 120,
                                                    height: size.height + 120),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = .normal
        backdrop.appearance = appearance
        let backdropView = NSView(frame: CGRect(origin: .zero, size: backdrop.frame.size))
        backdropView.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = backdropView.bounds
        gradient.colors = dark
            ? [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.20, alpha: 1).cgColor,
               NSColor(calibratedRed: 0.16, green: 0.10, blue: 0.14, alpha: 1).cgColor]
            : [NSColor(calibratedRed: 0.83, green: 0.87, blue: 0.93, alpha: 1).cgColor,
               NSColor(calibratedRed: 0.93, green: 0.89, blue: 0.84, alpha: 1).cgColor]
        backdropView.layer?.addSublayer(gradient)
        backdrop.contentView = backdropView
        backdrop.orderFrontRegardless()

        let window = NSWindow(contentRect: CGRect(origin: origin, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: IrizSettingsView(preview: true))
        window.orderFrontRegardless()

        RunLoop.current.run(until: Date().addingTimeInterval(0.9))

        let top = screen.frame.maxY - origin.y - size.height
        let rect = "\(Int(origin.x)),\(Int(top)),\(Int(size.width)),\(Int(size.height))"
        let url = directory.appendingPathComponent("settings-live-\(dark ? "dark" : "light").png")
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
        written.append(url)
    }
    return written
}
