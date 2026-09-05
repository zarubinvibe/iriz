// Основано на SuperDictate (MIT, © 2026 Richard Courtman), коммит 83dd7e4.
// Автомат горячей клавиши: hold vs toggle, подавление событий, Escape-отмена,
// альтернативное завершение «+ Enter», хоткей истории. Чистая логика, ноль UI.
import CoreGraphics
import Foundation

enum HotkeyTransitionAction: Equatable, Sendable {
    case press
    case release
    case pressPrompt
    case pressTranslation
    case releaseTranslation
    case releasePrompt
    case releaseAlternate
    case cancel
    case showHistory
    /// Toggle mode: the press was suppressed because the app is busy
    /// (transcription in flight). Does NOT flip toggle state. Lets the
    /// app play feedback so the user knows the press was received.
    case rejectedBusyPress
}

struct HotkeyTransitionResult: Equatable, Sendable {
    let suppress: Bool
    let actions: [HotkeyTransitionAction]

    static let pass = HotkeyTransitionResult(suppress: false, actions: [])
    static let suppressOnly = HotkeyTransitionResult(suppress: true, actions: [])
}

enum HotkeyShortcutEdge: Equatable {
    case press
    case release
    case suppress
    case pass
}

struct HotkeyShortcutResult: Equatable {
    let edge: HotkeyShortcutEdge
    let suppress: Bool

    static let pass = HotkeyShortcutResult(edge: .pass, suppress: false)
    static let suppressOnly = HotkeyShortcutResult(edge: .suppress, suppress: true)

    static func press(suppress: Bool) -> HotkeyShortcutResult {
        HotkeyShortcutResult(edge: .press, suppress: suppress)
    }

    static func release(suppress: Bool) -> HotkeyShortcutResult {
        HotkeyShortcutResult(edge: .release, suppress: suppress)
    }
}

struct HotkeyShortcutState {
    private var primaryModifierDown = false
    private var shortcutDown = false

    var isEngaged: Bool { primaryModifierDown || shortcutDown }

    mutating func reset() {
        primaryModifierDown = false
        shortcutDown = false
    }

    mutating func consume(_ event: HotkeyEventSnapshot,
                          shortcut: HotkeyChoice) -> HotkeyShortcutResult {
        if !shortcut.isModifier {
            guard event.keycode == shortcut.keycode else { return .pass }
            if event.typeRawValue == CGEventType.keyDown.rawValue {
                guard !event.isAutoRepeat else { return shortcutDown ? .suppressOnly : .pass }
                let modifiers = event.flags.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
                guard modifiers == shortcut.requiredModifiers else { return .pass }
                shortcutDown = true
                return .press(suppress: true)
            }
            if event.typeRawValue == CGEventType.keyUp.rawValue, shortcutDown {
                shortcutDown = false
                return .release(suppress: true)
            }
            return .pass
        }

        guard event.typeRawValue == CGEventType.flagsChanged.rawValue,
              let primaryMask = shortcut.modifierFlag else {
            return .pass
        }

        let eventModifier = MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == event.keycode })
        let isRequiredModifierEvent = eventModifier?.modifierFlag.map {
            shortcut.requiredModifiers.contains($0)
        } ?? false
        let isRelevant = event.keycode == shortcut.keycode || isRequiredModifierEvent
        guard isRelevant else { return .pass }

        if event.keycode == shortcut.keycode {
            if primaryModifierDown {
                primaryModifierDown = false
            } else if event.flags.contains(primaryMask) {
                primaryModifierDown = true
            }
        }

        let expectedModifiers = shortcut.requiredModifiers.union(primaryMask)
        let requirementsMet = event.flags.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
            == expectedModifiers
        let isNowDown = primaryModifierDown && requirementsMet
        if isNowDown, !shortcutDown {
            shortcutDown = true
            // Modifier-only chords are observed rather than consumed so
            // incomplete prefixes such as Shift keep working in the frontmost
            // app. A single-modifier shortcut remains fully intercepted.
            return .press(suppress: shortcut.requiredModifiers.isEmpty)
        }
        if shortcutDown, !isNowDown {
            shortcutDown = false
            return .release(suppress: shortcut.requiredModifiers.isEmpty)
        }
        if shortcutDown, shortcut.requiredModifiers.isEmpty {
            return .suppressOnly
        }
        return .pass
    }
}

struct HotkeyTransitionState {
    private enum RecordingRoute {
        case translation
        case standard
        case prompt
    }

    private var standardShortcutState = HotkeyShortcutState()
    private var enterShortcutState = HotkeyShortcutState()
    private var historyShortcutState = HotkeyShortcutState()
    private var promptShortcutState = HotkeyShortcutState()
    private var translationShortcutState = HotkeyShortcutState()
    private var toggleActive = false
    private var promptToggleActive = false
    private var activeRecordingRoute: RecordingRoute?
    private var suppressEscapeKeyUp = false

    mutating func resetAll() {
        standardShortcutState.reset()
        enterShortcutState.reset()
        historyShortcutState.reset()
        promptShortcutState.reset()
        translationShortcutState.reset()
        resetToggleState()
        suppressEscapeKeyUp = false
    }

    mutating func resetToggleState() {
        toggleActive = false
        promptToggleActive = false
        activeRecordingRoute = nil
    }

    /// `canStartRecording` mirrors the app-side guard on handlePress
    /// (ready, not recording, not busy, not terminating). Toggle mode
    /// consults it before claiming either recording route.
    mutating func transition(
        for event: HotkeyEventSnapshot,
        hotkey: HotkeyChoice,
        enterHotkey: HotkeyChoice = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                                 modifiers: .maskAlternate),
        alternateCompletionEnabled: Bool = true,
        historyHotkey: HotkeyChoice = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                                   modifiers: .maskShift),
        promptHotkey: HotkeyChoice = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                                  modifiers: .maskControl),
        promptHotkeyEnabled: Bool = false,
        translationHotkey: HotkeyChoice = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                                       modifiers: .maskShift),
        translationHotkeyEnabled: Bool = false,
        triggerMode: TriggerMode,
        isRecording: Bool,
        canStartRecording: Bool = true
    ) -> HotkeyTransitionResult {
        if event.keycode == ESCAPE_KEYCODE {
            return transitionEscape(for: event, isRecording: isRecording)
        }

        if let history = transitionHistoryShortcut(for: event,
                                                    isRecording: isRecording,
                                                    historyHotkey: historyHotkey) {
            return history
        }

        if alternateCompletionEnabled,
           !hotkeyIsModifierPrefix(hotkey, of: enterHotkey) {
            if let completion = transitionEnterShortcut(for: event,
                                                        isRecording: isRecording,
                                                        enterHotkey: enterHotkey) {
                return completion
            }
        }

        if promptHotkeyEnabled {
            if let prompt = transitionPromptShortcut(for: event,
                                                      isRecording: isRecording,
                                                      canStartRecording: canStartRecording,
                                                      promptHotkey: promptHotkey,
                                                      triggerMode: triggerMode) {
                return prompt
            }
        }

        // Перевод стоит ПОСЛЕ промпта и до обычной диктовки. Порядок не
        // случайный: у всех трёх режимов одна базовая клавиша и разные
        // модификаторы, и разбирать их надо от самого частного к общему,
        // иначе диктовка перехватит сочетание с модификатором себе.
        if translationHotkeyEnabled {
            if let translation = transitionTranslationShortcut(
                for: event,
                isRecording: isRecording,
                canStartRecording: canStartRecording,
                translationHotkey: translationHotkey,
                triggerMode: triggerMode
            ) {
                return translation
            }
        }

        let shortcutResult = standardShortcutState.consume(event, shortcut: hotkey)

        switch triggerMode {
        case .hold:
            switch shortcutResult.edge {
            case .press:
                guard !isRecording,
                      activeRecordingRoute == nil else {
                    return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                                  actions: [.rejectedBusyPress])
                }
                activeRecordingRoute = .standard
                return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                              actions: [.press])
            case .release:
                guard activeRecordingRoute == .standard else {
                    return shortcutResult.suppress ? .suppressOnly : .pass
                }
                activeRecordingRoute = nil
                return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                              actions: [.release])
            case .suppress:
                return .suppressOnly
            case .pass:
                return .pass
            }
        case .toggle:
            // Toggle mode: every press flips between "start recording"
            // and "stop recording". Releases are no-ops.
            guard shortcutResult.edge != .pass else {
                return shortcutResult.suppress ? .suppressOnly : .pass
            }
            guard shortcutResult.edge == .press else {
                return shortcutResult.suppress ? .suppressOnly : .pass
            }
            if toggleActive {
                toggleActive = false
                if activeRecordingRoute == .standard {
                    activeRecordingRoute = nil
                }
                return HotkeyTransitionResult(suppress: shortcutResult.suppress, actions: [.release])
            }
            // A press the app will reject (model loading, a
            // transcription in flight, terminating) must not flip the
            // toggle. Otherwise the rejected press strands
            // toggleActive at true, the NEXT press emits a .release
            // the app discards, and only the third press records —
            // with zero feedback in between. Same gate-callback
            // pattern Escape uses via isRecording.
            // .rejectedBusyPress lets the app play feedback without
            // flipping toggle state — handlePress() is never reached
            // in toggle mode because the state machine gates it here.
            guard !isRecording,
                  activeRecordingRoute == nil,
                  canStartRecording else {
                return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                              actions: [.rejectedBusyPress])
            }
            toggleActive = true
            activeRecordingRoute = .standard
            return HotkeyTransitionResult(suppress: shortcutResult.suppress, actions: [.press])
        }
    }

    private mutating func transitionPromptShortcut(
        for event: HotkeyEventSnapshot,
        isRecording: Bool,
        canStartRecording: Bool,
        promptHotkey: HotkeyChoice,
        triggerMode: TriggerMode
    ) -> HotkeyTransitionResult? {
        let shortcutResult = promptShortcutState.consume(event, shortcut: promptHotkey)
        guard shortcutResult.edge != .pass else {
            return shortcutResult.suppress ? .suppressOnly : nil
        }

        switch triggerMode {
        case .hold:
            switch shortcutResult.edge {
            case .press:
                guard !isRecording,
                      activeRecordingRoute == nil else {
                    return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                                  actions: [.rejectedBusyPress])
                }
                activeRecordingRoute = .prompt
                return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                              actions: [.pressPrompt])
            case .release:
                guard activeRecordingRoute == .prompt else {
                    return shortcutResult.suppress ? .suppressOnly : nil
                }
                activeRecordingRoute = nil
                return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                              actions: [.releasePrompt])
            case .suppress:
                return .suppressOnly
            case .pass:
                return nil
            }
        case .toggle:
            guard shortcutResult.edge == .press else {
                return shortcutResult.suppress ? .suppressOnly : nil
            }
            if promptToggleActive {
                promptToggleActive = false
                if activeRecordingRoute == .prompt {
                    activeRecordingRoute = nil
                }
                return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                              actions: [.releasePrompt])
            }
            guard !isRecording,
                  activeRecordingRoute == nil,
                  canStartRecording else {
                return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                              actions: [.rejectedBusyPress])
            }
            promptToggleActive = true
            activeRecordingRoute = .prompt
            return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                          actions: [.pressPrompt])
        }
    }

    private mutating func transitionTranslationShortcut(
        for event: HotkeyEventSnapshot,
        isRecording: Bool,
        canStartRecording: Bool,
        translationHotkey: HotkeyChoice,
        triggerMode: TriggerMode
    ) -> HotkeyTransitionResult? {
        let shortcutResult = translationShortcutState.consume(event, shortcut: translationHotkey)
        guard shortcutResult.edge != .pass else {
            return shortcutResult.suppress ? .suppressOnly : nil
        }

        switch triggerMode {
        case .hold:
            switch shortcutResult.edge {
            case .press:
                guard !isRecording,
                      activeRecordingRoute == nil else {
                    return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                                  actions: [.rejectedBusyPress])
                }
                activeRecordingRoute = .translation
                return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                              actions: [.pressTranslation])
            case .release:
                guard activeRecordingRoute == .translation else {
                    return shortcutResult.suppress ? .suppressOnly : nil
                }
                activeRecordingRoute = nil
                return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                              actions: [.releaseTranslation])
            case .suppress:
                return .suppressOnly
            case .pass:
                return nil
            }
        case .toggle:
            guard shortcutResult.edge == .press else {
                return shortcutResult.suppress ? .suppressOnly : nil
            }
            if promptToggleActive {
                promptToggleActive = false
                if activeRecordingRoute == .translation {
                    activeRecordingRoute = nil
                }
                return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                              actions: [.releaseTranslation])
            }
            guard !isRecording,
                  activeRecordingRoute == nil,
                  canStartRecording else {
                return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                              actions: [.rejectedBusyPress])
            }
            promptToggleActive = true
            activeRecordingRoute = .translation
            return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                          actions: [.pressTranslation])
        }
    }

    private mutating func transitionHistoryShortcut(
        for event: HotkeyEventSnapshot,
        isRecording: Bool,
        historyHotkey: HotkeyChoice
    ) -> HotkeyTransitionResult? {
        let shortcutResult = historyShortcutState.consume(event, shortcut: historyHotkey)
        switch shortcutResult.edge {
        case .press:
            standardShortcutState.reset()
            enterShortcutState.reset()
            promptShortcutState.reset()
        translationShortcutState.reset()
            if !isRecording {
                resetToggleState()
            }
            return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                          actions: [.showHistory])
        case .release, .suppress:
            return shortcutResult.suppress ? .suppressOnly : nil
        case .pass:
            return nil
        }
    }

    private mutating func transitionEnterShortcut(
        for event: HotkeyEventSnapshot,
        isRecording: Bool,
        enterHotkey: HotkeyChoice
    ) -> HotkeyTransitionResult? {
        guard isRecording || enterShortcutState.isEngaged else { return nil }
        let shortcutResult = enterShortcutState.consume(event, shortcut: enterHotkey)
        switch shortcutResult.edge {
        case .press where isRecording:
            guard activeRecordingRoute != .prompt else {
                return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                              actions: [.rejectedBusyPress])
            }
            standardShortcutState.reset()
            promptShortcutState.reset()
        translationShortcutState.reset()
            toggleActive = false
            activeRecordingRoute = nil
            return HotkeyTransitionResult(suppress: shortcutResult.suppress,
                                          actions: [.releaseAlternate])
        case .press, .release, .suppress:
            return shortcutResult.suppress ? .suppressOnly : nil
        case .pass:
            return nil
        }
    }

    private mutating func transitionEscape(
        for event: HotkeyEventSnapshot,
        isRecording: Bool
    ) -> HotkeyTransitionResult {
        if event.typeRawValue == CGEventType.keyDown.rawValue {
            if event.isAutoRepeat, suppressEscapeKeyUp {
                return .suppressOnly
            }
            guard isRecording else { return .pass }
            suppressEscapeKeyUp = true
            resetToggleState()
            return event.isAutoRepeat
                ? .suppressOnly
                : HotkeyTransitionResult(suppress: true, actions: [.cancel])
        }

        if event.typeRawValue == CGEventType.keyUp.rawValue, suppressEscapeKeyUp {
            suppressEscapeKeyUp = false
            return .suppressOnly
        }

        return .pass
    }
}
