import AppKit
import SwiftUI

/// Клавиши, которые панель обязана обработать сама.
enum MenuPanelKey {
    case escape
    case up
    case down
    case activate

    /// Модификаторы игнорируем: ⌘↓ и ⌥Esc — не навигация по меню, их не наше дело.
    init?(event: NSEvent) {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .isSubset(of: [.numericPad, .function]) else { return nil }
        switch event.keyCode {
        case 53: self = .escape
        case 126: self = .up
        case 125: self = .down
        case 36, 76, 49: self = .activate   // Return, Enter, Space
        default: return nil
        }
    }
}

/// Мост «SwiftUI-панель ↔ AppKit» для MenuBarExtra в стиле `.window`.
///
/// NSMenu давал даром закрытие по Esc, навигацию стрелками и клавиатурный фокус.
/// Панель не даёт ничего из этого: содержимое рисуется обычной вьюхой в NSPanel.
/// Здесь эта цена и выплачивается — иначе меню стало бы мышиным, а это регресс
/// доступности, а не редизайн.
@MainActor
final class MenuPanelChrome {
    /// Обработчик ставит вьюха: только она знает свой порядок пунктов.
    /// Возврат `true` = событие съедено, дальше по цепочке не идёт.
    var onKey: ((MenuPanelKey) -> Bool)?

    private weak var panel: NSWindow?
    private var keyMonitor: Any?

    func attach(_ window: NSWindow?) {
        panel = window
        // Панель принадлежит SwiftUI, и close() не должен её освобождать:
        // иначе следующий клик по знаку строки меню открывал бы труп.
        window?.isReleasedWhenClosed = false
    }

    /// Панель показана: забираем клавиатуру и вешаем локальный монитор.
    /// `makeKey` без активации приложения: LSUIElement-панель — nonactivating,
    /// она умеет быть ключевой, не отнимая фокус у приложения, где владелец
    /// набирает текст. Отнимать его ради меню было бы хуже болезни.
    func didAppear() {
        panel?.makeKey()
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Через границу изоляции переносим Bool, а не NSEvent: он не Sendable.
            guard let key = MenuPanelKey(event: event) else { return event }
            let consumed = MainActor.assumeIsolated { self?.onKey?(key) ?? false }
            return consumed ? nil : event
        }
    }

    func didDisappear() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func close() {
        panel?.close()
    }
}

/// Даёт вьюхе доступ к NSPanel, в котором SwiftUI её показал: без окна нет ни
/// ключевого статуса, ни закрытия по Esc.
struct MenuPanelAnchor: NSViewRepresentable {
    let chrome: MenuPanelChrome

    func makeNSView(context: Context) -> NSView { AnchorView(chrome: chrome) }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AnchorView: NSView {
        private let chrome: MenuPanelChrome

        init(chrome: MenuPanelChrome) {
            self.chrome = chrome
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("панель из xib не поднимается") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            chrome.attach(window)
        }
    }
}
