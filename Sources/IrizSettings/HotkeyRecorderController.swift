// Основано на SuperDictate (MIT, © 2026 Richard Courtman), строки 3865–4150.
import AppKit
import CoreGraphics
import IrizDictate

@MainActor
public final class HotkeyRecorderController: NSObject, NSWindowDelegate {
    public override init() { super.init() }

    private var panel: NSPanel?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var completion: ((HotkeyChoice?) -> Void)?
    private var accumulatedFlags: CGEventFlags = []
    private var lastPressedModifier: CGKeyCode?
    private var isFinishing = false

    public func present(actionTitle: String, completion: @escaping (HotkeyChoice?) -> Void) {
        finish(with: nil, notify: false)
        self.completion = completion

        let panel = makePanel(actionTitle: actionTitle)
        self.panel = panel
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        if !startEventTap() {
            startLocalMonitor()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard !isFinishing else { return }
        finish(with: nil)
    }

    @objc private func cancelRecording() {
        finish(with: nil)
    }

    private func makePanel(actionTitle: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Новое сочетание"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let title = NSTextField(labelWithString: actionTitle)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.alignment = .center
        title.setAccessibilityLabel("Действие: \(actionTitle)")

        let prompt = NSTextField(labelWithString: "Нажмите нужное сочетание")
        prompt.font = .systemFont(ofSize: 18, weight: .medium)
        prompt.alignment = .center
        prompt.setAccessibilityLabel("Нажмите нужное сочетание клавиш")

        let hint = NSTextField(labelWithString: "Escape отменяет запись")
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center

        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelRecording))
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityLabel("Отменить запись сочетания")

        let stack = NSStackView(views: [title, prompt, hint, cancel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor),
        ])
        return panel
    }

    private func startEventTap() -> Bool {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<HotkeyRecorderController>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated {
                        if let tap = controller.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    }
                    return nil
                }

                let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
                MainActor.assumeIsolated {
                    controller.consume(type: type, keycode: keycode, flags: flags)
                }
                return nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func startLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self else { return nil }
            let type: CGEventType = event.type == .keyDown ? .keyDown : .flagsChanged
            self.consume(type: type, keycode: event.keyCode, flags: Self.cgFlags(from: event.modifierFlags))
            return nil
        }
    }

    private func consume(type: CGEventType, keycode: CGKeyCode, flags: CGEventFlags) {
        if type == .keyDown {
            if keycode == ESCAPE_KEYCODE {
                finish(with: nil)
                return
            }
            guard let choice = recordableHotkeyChoice(forKeycode: keycode, modifiers: flags),
                  !choice.isModifier else {
                NSSound.beep()
                return
            }
            finish(with: choice)
            return
        }

        guard type == .flagsChanged,
              let modifier = recordableHotkeyChoice(forKeycode: keycode),
              modifier.isModifier else { return }

        let normalized = flags.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        if modifier.modifierFlag.map(normalized.contains) == true {
            lastPressedModifier = keycode
            accumulatedFlags.formUnion(normalized)
            return
        }

        accumulatedFlags.formUnion(normalized)
        guard normalized.isEmpty, let primary = lastPressedModifier else { return }
        guard let choice = recordableHotkeyChoice(forKeycode: primary, modifiers: accumulatedFlags) else {
            NSSound.beep()
            return
        }
        finish(with: choice)
    }

    private func finish(with choice: HotkeyChoice?, notify: Bool = true) {
        guard !isFinishing else { return }
        isFinishing = true

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }

        let completion = self.completion
        self.completion = nil
        accumulatedFlags = []
        lastPressedModifier = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        isFinishing = false
        if notify { completion?(choice) }
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.function) { result.insert(.maskSecondaryFn) }
        return result
    }
}
