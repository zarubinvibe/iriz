// Основано на SuperDictate (MIT, © 2026 Richard Courtman), коммит 83dd7e4.
// CGEventTap на keyDown/keyUp/flagsChanged, гоняет события через автомат
// хоткея и зовёт колбэки приложения. Уже развязан с UI — точка стыковки.
import CoreGraphics
import Foundation

@MainActor
final class HotkeyListener {

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var transitionState = HotkeyTransitionState()

    /// User's current hotkey.
    var hotkey: HotkeyChoice = hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE)
    var enterHotkey: HotkeyChoice = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                                 modifiers: .maskAlternate)
    var alternateCompletionEnabled = true
    var historyHotkey: HotkeyChoice = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                                   modifiers: .maskShift)
    var promptHotkey: HotkeyChoice = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                                  modifiers: .maskControl)
    var promptHotkeyEnabled = false
    var translationHotkey = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE, modifiers: .maskShift)
    var translationHotkeyEnabled = false
    var triggerMode: TriggerMode = .toggle

    /// onPress fires when a recording should start (press in hold mode,
    /// or first press in toggle mode). onRelease fires when it should
    /// stop (release in hold mode, or second press in toggle mode).
    /// onCancel fires for Escape while a recording is active.
    var onPress: (() -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    var onPromptPress: (() -> Void)?
    var onTranslationPress: (() -> Void)?
    var onTranslationRelease: ((TimeInterval) -> Void)?
    var onPromptRelease: ((TimeInterval) -> Void)?
    var onReleaseAlternate: ((TimeInterval) -> Void)?
    var onCancel: (() -> Void)?
    var onShowHistory: (() -> Void)?
    /// Toggle mode: a press arrived while the app is busy (transcription
    /// in flight). The toggle did NOT flip. Play feedback so the user
    /// knows the press was received but rejected.
    var onRejectedBusyPress: (() -> Void)?
    var isRecordingActive: (() -> Bool)?
    /// Asks the app whether a new recording would actually start if
    /// onPress fired right now (ready, idle, not transcribing, not
    /// terminating). Toggle mode uses it so a press the app would
    /// silently discard doesn't flip the toggle state and leave the
    /// next press emitting a swallowed .release. nil (or no callback
    /// installed) is treated as "would start".
    var canStartRecording: (() -> Bool)?

    @discardableResult
    func start() -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<HotkeyListener>.fromOpaque(userInfo).takeUnretainedValue()
                let snapshot = HotkeyEventSnapshot(
                    typeRawValue: type.rawValue,
                    keycode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                    flagsRawValue: event.flags.rawValue,
                    isAutoRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                )
                let shouldSuppress = MainActor.assumeIsolated {
                    listener.handleTapCallback(snapshot)
                }
                return shouldSuppress ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: opaqueSelf
        ) else {
            log("HotkeyListener: CGEvent.tapCreate failed — Input Monitoring permission missing?")
            return false
        }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("HotkeyListener: tap active (watching \(hotkey.name))")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        transitionState.resetAll()
    }

    /// Replace the current hotkey choice. Safe to call at runtime —
    /// the tap stays bound, only the per-event filter changes.
    func setHotkey(_ choice: HotkeyChoice) {
        guard choice != hotkey else { return }
        self.hotkey = choice
        self.transitionState.resetAll()
        log("HotkeyListener: hotkey changed → \(choice.name)")
    }

    func setEnterHotkey(_ choice: HotkeyChoice) {
        guard choice != enterHotkey else { return }
        enterHotkey = choice
        transitionState.resetAll()
        log("HotkeyListener: alternate completion hotkey changed → \(choice.name)")
    }

    func setAlternateCompletionEnabled(_ enabled: Bool) {
        guard enabled != alternateCompletionEnabled else { return }
        alternateCompletionEnabled = enabled
        transitionState.resetAll()
        log("HotkeyListener: alternate completion → \(enabled ? "enabled" : "disabled")")
    }

    func setHistoryHotkey(_ choice: HotkeyChoice) {
        guard choice != historyHotkey else { return }
        historyHotkey = choice
        transitionState.resetAll()
        log("HotkeyListener: history hotkey changed → \(choice.name)")
    }

    func setPromptHotkey(_ choice: HotkeyChoice) {
        guard choice != promptHotkey else { return }
        promptHotkey = choice
        transitionState.resetAll()
        log("HotkeyListener: prompt hotkey changed → \(choice.name)")
    }

    func setTranslationHotkey(_ choice: HotkeyChoice) {
        guard choice != translationHotkey else { return }
        translationHotkey = choice
        transitionState.resetAll()
        log("HotkeyListener: translation hotkey changed → \(choice.name)")
    }

    func setTranslationHotkeyEnabled(_ enabled: Bool) {
        guard enabled != translationHotkeyEnabled else { return }
        translationHotkeyEnabled = enabled
        transitionState.resetAll()
        log("HotkeyListener: translation hotkey → \(enabled ? "enabled" : "disabled")")
    }

    func setPromptHotkeyEnabled(_ enabled: Bool) {
        guard enabled != promptHotkeyEnabled else { return }
        promptHotkeyEnabled = enabled
        transitionState.resetAll()
        log("HotkeyListener: prompt hotkey → \(enabled ? "enabled" : "disabled")")
    }

    func setTriggerMode(_ mode: TriggerMode) {
        guard mode != triggerMode else { return }
        // Reset toggle state when switching modes so we don't get
        // stuck in mid-toggle from a previous session.
        transitionState.resetToggleState()
        triggerMode = mode
        log("HotkeyListener: trigger mode → \(mode.rawValue)")
    }

    private func handleTapCallback(_ event: HotkeyEventSnapshot) -> Bool {
        if event.typeRawValue == CGEventType.tapDisabledByTimeout.rawValue
            || event.typeRawValue == CGEventType.tapDisabledByUserInput.rawValue {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                log("HotkeyListener: event tap re-enabled after \(event.typeRawValue)")
            }
            return false
        }

        let result = transitionState.transition(for: event,
                                                hotkey: hotkey,
                                                enterHotkey: enterHotkey,
                                                alternateCompletionEnabled: alternateCompletionEnabled,
                                                historyHotkey: historyHotkey,
                                                promptHotkey: promptHotkey,
                                                promptHotkeyEnabled: promptHotkeyEnabled,
                                                translationHotkey: translationHotkey,
                                                translationHotkeyEnabled: translationHotkeyEnabled,
                                                triggerMode: triggerMode,
                                                isRecording: isRecordingActive?() ?? false,
                                                canStartRecording: canStartRecording?() ?? true)
        dispatchHotkeyActions(result.actions)
        return result.suppress
    }

    private func dispatchHotkeyActions(_ actions: [HotkeyTransitionAction]) {
        guard !actions.isEmpty else { return }
        let detectedAt = ProcessInfo.processInfo.systemUptime

        Task { @MainActor [weak self] in
            self?.performHotkeyActions(actions, detectedAt: detectedAt)
        }
    }

    private func performHotkeyActions(_ actions: [HotkeyTransitionAction], detectedAt: TimeInterval) {
        for action in actions {
            switch action {
            case .press: onPress?()
            case .release: onRelease?(detectedAt)
            case .pressPrompt: onPromptPress?()
            case .pressTranslation: onTranslationPress?()
            case .releaseTranslation: onTranslationRelease?(detectedAt)
            case .releasePrompt: onPromptRelease?(detectedAt)
            case .releaseAlternate: onReleaseAlternate?(detectedAt)
            case .cancel: onCancel?()
            case .showHistory: onShowHistory?()
            case .rejectedBusyPress: onRejectedBusyPress?()
            }
        }
    }

    /// Called when the recording stops via a path other than the
    /// hotkey (auto-release at max duration, app quitting, Escape) so
    /// neither toggle route ends up offset by one.
    func resetToggleState() {
        transitionState.resetToggleState()
    }
}
