// Тесты разбора keycode+модификаторов и автомата хоткея.
// Источник кейсов: self-тесты донора (main.swift ~19861–19964) + граничные
// случаи, важные для toggle-режима владельца (голый правый Cmd).
import CoreGraphics
import Foundation
import Testing

@testable import IrizDictate

// MARK: - Разбор keycode + модификаторов

@Suite("HotkeyChoice parsing")
struct HotkeyParsingTests {
    @Test func rightCommandIsModifierChoice() {
        let choice = recordableHotkeyChoice(forKeycode: 54)
        #expect(choice != nil)
        #expect(choice?.keycode == 54)
        #expect(choice?.isModifier == true)
        #expect(choice?.modifierFlag == .maskCommand)
        #expect(choice?.requiredModifiers.isEmpty == true)
    }

    @Test func modifierChoiceSubtractsOwnFlag() {
        // Option + правый Cmd: собственный флаг Cmd вычитается из required.
        let choice = recordableHotkeyChoice(forKeycode: 54, modifiers: .maskAlternate)
        #expect(choice?.isModifier == true)
        #expect(choice?.requiredModifiers == .maskAlternate)
    }

    @Test func escapeIsNotRecordable() {
        #expect(recordableHotkeyChoice(forKeycode: ESCAPE_KEYCODE) == nil)
    }

    @Test func keycodeAbove255IsNotRecordable() {
        #expect(recordableHotkeyChoice(forKeycode: 256) == nil)
    }

    @Test func plainLetterGetsNameAndModifiers() {
        let choice = recordableHotkeyChoice(forKeycode: 0, modifiers: [.maskCommand, .maskShift])
        #expect(choice?.isModifier == false)
        #expect(choice?.name == "⇧⌘A")
        #expect(choice?.requiredModifiers == [.maskCommand, .maskShift])
    }

    @Test func foreignModifierBitsAreMaskedOut() {
        // CapsLock и прочие биты вне HOTKEY_SHORTCUT_MODIFIER_MASK отбрасываются.
        let choice = recordableHotkeyChoice(forKeycode: 0,
                                            modifiers: [.maskCommand, .maskAlphaShift])
        #expect(choice?.requiredModifiers == .maskCommand)
    }

    @Test func fallbackIsDefaultHotkey() {
        let choice = hotkeyChoice(forKeycode: ESCAPE_KEYCODE)
        #expect(choice.keycode == DEFAULT_HOTKEY_KEYCODE)
        #expect(choice.isModifier)
    }

    @Test func normalizedKeycodeFromNumber() {
        #expect(normalizedHotkeyKeycode(storedValue: NSNumber(value: 54)) == 54)
    }

    @Test func normalizedKeycodeFromString() {
        #expect(normalizedHotkeyKeycode(storedValue: " 54 ") == 54)
    }

    @Test func normalizedKeycodeRejectsGarbage() {
        #expect(normalizedHotkeyKeycode(storedValue: "abc") == nil)
        #expect(normalizedHotkeyKeycode(storedValue: NSNumber(value: -1)) == nil)
        #expect(normalizedHotkeyKeycode(storedValue: nil) == nil)
        // Escape запрещён как хоткей — мусор в настройках откатывается к дефолту.
        #expect(normalizedHotkeyKeycode(storedValue: NSNumber(value: 53)) == nil)
    }

    @Test func modifierPrefixDetection() {
        // «Префикс» — голый модификатор, который входит в составной хоткей
        // как ОБЯЗАТЕЛЬНЫЙ модификатор: голый Right Option — префикс для
        // Option + правый Cmd, и тогда альтернативное завершение глушится,
        // чтобы не конфликтовать с основным хоткеем.
        let rightOption = hotkeyChoice(forKeycode: 61)
        let optionRightCmd = hotkeyChoice(forKeycode: 54, modifiers: .maskAlternate)
        #expect(hotkeyIsModifierPrefix(rightOption, of: optionRightCmd))
        // А голый правый Cmd — НЕ префикс для Option + правый Cmd
        // (Command не входит в requiredModifiers аккорда) — оба хоткея живут.
        let rightCmd = hotkeyChoice(forKeycode: 54)
        #expect(!hotkeyIsModifierPrefix(rightCmd, of: optionRightCmd))
        #expect(!hotkeyIsModifierPrefix(rightCmd, of: rightCmd))
        let letter = hotkeyChoice(forKeycode: 0)
        #expect(!hotkeyIsModifierPrefix(letter, of: optionRightCmd))
    }
}

// MARK: - Автомат хоткея

@Suite("Hotkey transition automaton")
struct HotkeyAutomatonTests {
    private func flagsChanged(_ keycode: CGKeyCode, _ flags: CGEventFlags) -> HotkeyEventSnapshot {
        HotkeyEventSnapshot(typeRawValue: CGEventType.flagsChanged.rawValue,
                            keycode: keycode,
                            flagsRawValue: flags.rawValue,
                            isAutoRepeat: false)
    }

    private func keyEvent(_ type: CGEventType, _ keycode: CGKeyCode) -> HotkeyEventSnapshot {
        HotkeyEventSnapshot(typeRawValue: type.rawValue,
                            keycode: keycode,
                            flagsRawValue: 0,
                            isAutoRepeat: false)
    }

    private let rightCmd = hotkeyChoice(forKeycode: 54)
    private let promptHotkey = hotkeyChoice(forKeycode: 54, modifiers: .maskControl)

    private func promptPress(
        _ state: inout HotkeyTransitionState,
        triggerMode: TriggerMode,
        isRecording: Bool,
        enabled: Bool = true,
        canStartRecording: Bool = true,
        hotkey: HotkeyChoice? = nil
    ) -> HotkeyTransitionResult {
        let standardHotkey = hotkey ?? rightCmd
        _ = state.transition(for: flagsChanged(59, .maskControl),
                             hotkey: standardHotkey,
                             promptHotkey: promptHotkey,
                             promptHotkeyEnabled: enabled,
                             triggerMode: triggerMode,
                             isRecording: isRecording,
                             canStartRecording: canStartRecording)
        return state.transition(for: flagsChanged(54, [.maskControl, .maskCommand]),
                                hotkey: standardHotkey,
                                promptHotkey: promptHotkey,
                                promptHotkeyEnabled: enabled,
                                triggerMode: triggerMode,
                                isRecording: isRecording,
                                canStartRecording: canStartRecording)
    }

    private func promptRelease(
        _ state: inout HotkeyTransitionState,
        triggerMode: TriggerMode,
        isRecording: Bool,
        enabled: Bool = true,
        hotkey: HotkeyChoice? = nil
    ) -> HotkeyTransitionResult {
        let standardHotkey = hotkey ?? rightCmd
        let result = state.transition(for: flagsChanged(54, .maskControl),
                                      hotkey: standardHotkey,
                                      promptHotkey: promptHotkey,
                                      promptHotkeyEnabled: enabled,
                                      triggerMode: triggerMode,
                                      isRecording: isRecording)
        _ = state.transition(for: flagsChanged(59, []),
                             hotkey: standardHotkey,
                             promptHotkey: promptHotkey,
                             promptHotkeyEnabled: enabled,
                             triggerMode: triggerMode,
                             isRecording: isRecording)
        return result
    }

    @Test func toggleFirstPressStartsRecording() {
        var state = HotkeyTransitionState()
        let result = state.transition(for: flagsChanged(54, .maskCommand),
                                      hotkey: rightCmd,
                                      triggerMode: .toggle,
                                      isRecording: false)
        #expect(result.actions == [.press])
        #expect(result.suppress)
    }

    @Test func toggleReleaseIsNoOpButSuppressed() {
        var state = HotkeyTransitionState()
        _ = state.transition(for: flagsChanged(54, .maskCommand),
                             hotkey: rightCmd, triggerMode: .toggle, isRecording: false)
        let result = state.transition(for: flagsChanged(54, []),
                                      hotkey: rightCmd, triggerMode: .toggle, isRecording: true)
        #expect(result.actions.isEmpty)
        #expect(result.suppress)
    }

    @Test func toggleSecondPressStopsRecording() {
        var state = HotkeyTransitionState()
        _ = state.transition(for: flagsChanged(54, .maskCommand),
                             hotkey: rightCmd, triggerMode: .toggle, isRecording: false)
        _ = state.transition(for: flagsChanged(54, []),
                             hotkey: rightCmd, triggerMode: .toggle, isRecording: true)
        // Второе НАЖАТИЕ — это и есть стоп; отпускание после него — no-op.
        let secondPress = state.transition(for: flagsChanged(54, .maskCommand),
                                           hotkey: rightCmd, triggerMode: .toggle, isRecording: true)
        #expect(secondPress.actions == [.release])
        let keyUp = state.transition(for: flagsChanged(54, []),
                                     hotkey: rightCmd, triggerMode: .toggle, isRecording: false)
        #expect(keyUp.actions.isEmpty)
        #expect(keyUp.suppress)
    }

    @Test func busyPressRejectedWithoutFlippingToggle() {
        var state = HotkeyTransitionState()
        let rejected = state.transition(for: flagsChanged(54, .maskCommand),
                                        hotkey: rightCmd, triggerMode: .toggle,
                                        isRecording: false, canStartRecording: false)
        #expect(rejected.actions == [.rejectedBusyPress])
        // Toggle НЕ перевернулся: следующее нажатие — снова старт, а не стоп.
        _ = state.transition(for: flagsChanged(54, []),
                             hotkey: rightCmd, triggerMode: .toggle,
                             isRecording: false, canStartRecording: false)
        let next = state.transition(for: flagsChanged(54, .maskCommand),
                                    hotkey: rightCmd, triggerMode: .toggle,
                                    isRecording: false, canStartRecording: true)
        #expect(next.actions == [.press])
    }

    @Test func escapeCancelsOnlyWhileRecording() {
        var state = HotkeyTransitionState()
        let idle = state.transition(for: keyEvent(.keyDown, ESCAPE_KEYCODE),
                                    hotkey: rightCmd, triggerMode: .toggle, isRecording: false)
        #expect(idle == .pass)

        let cancel = state.transition(for: keyEvent(.keyDown, ESCAPE_KEYCODE),
                                      hotkey: rightCmd, triggerMode: .toggle, isRecording: true)
        #expect(cancel.actions == [.cancel])
        #expect(cancel.suppress)
        // KeyUp после подавленного Escape тоже подавляется.
        let keyUp = state.transition(for: keyEvent(.keyUp, ESCAPE_KEYCODE),
                                     hotkey: rightCmd, triggerMode: .toggle, isRecording: false)
        #expect(keyUp == .suppressOnly)
    }

    @Test func holdModePressAndRelease() {
        var state = HotkeyTransitionState()
        let press = state.transition(for: flagsChanged(54, .maskCommand),
                                     hotkey: rightCmd, triggerMode: .hold, isRecording: false)
        #expect(press.actions == [.press])
        let release = state.transition(for: flagsChanged(54, []),
                                       hotkey: rightCmd, triggerMode: .hold, isRecording: true)
        #expect(release.actions == [.release])
    }

    @Test func promptToggleStartsAndStopsPromptRoute() {
        var state = HotkeyTransitionState()
        let firstPress = promptPress(&state, triggerMode: .toggle, isRecording: false)
        #expect(firstPress.actions == [.pressPrompt])
        #expect(!firstPress.suppress)

        let firstRelease = promptRelease(&state, triggerMode: .toggle, isRecording: true)
        #expect(firstRelease == .pass)

        let secondPress = promptPress(&state, triggerMode: .toggle, isRecording: true)
        #expect(secondPress.actions == [.releasePrompt])
        #expect(!secondPress.suppress)
    }

    @Test func disabledPromptHotkeyPassesThrough() {
        var state = HotkeyTransitionState()
        let press = promptPress(&state,
                                triggerMode: .toggle,
                                isRecording: false,
                                enabled: false)
        let release = promptRelease(&state,
                                    triggerMode: .toggle,
                                    isRecording: false,
                                    enabled: false)
        #expect(press == .pass)
        #expect(release == .pass)
    }

    @Test func promptHoldPressAndReleaseUsePromptRoute() {
        var state = HotkeyTransitionState()
        let press = promptPress(&state, triggerMode: .hold, isRecording: false)
        let release = promptRelease(&state, triggerMode: .hold, isRecording: true)
        #expect(press.actions == [.pressPrompt])
        #expect(release.actions == [.releasePrompt])
    }

    @Test func promptPressCannotStealStandardRecording() {
        var state = HotkeyTransitionState()
        _ = state.transition(for: flagsChanged(54, .maskCommand),
                             hotkey: rightCmd, triggerMode: .toggle, isRecording: false)
        _ = state.transition(for: flagsChanged(54, []),
                             hotkey: rightCmd, triggerMode: .toggle, isRecording: true)

        let rejected = promptPress(&state, triggerMode: .toggle, isRecording: true)
        #expect(rejected.actions == [.rejectedBusyPress])
        _ = promptRelease(&state, triggerMode: .toggle, isRecording: true)

        let standardStop = state.transition(for: flagsChanged(54, .maskCommand),
                                            hotkey: rightCmd,
                                            promptHotkey: promptHotkey,
                                            promptHotkeyEnabled: true,
                                            triggerMode: .toggle,
                                            isRecording: true)
        #expect(standardStop.actions == [.release])
    }

    @Test func standardPressCannotStealPromptRecording() {
        var state = HotkeyTransitionState()
        _ = promptPress(&state, triggerMode: .toggle, isRecording: false)
        _ = promptRelease(&state, triggerMode: .toggle, isRecording: true)

        let rejected = state.transition(for: flagsChanged(54, .maskCommand),
                                        hotkey: rightCmd,
                                        promptHotkey: promptHotkey,
                                        promptHotkeyEnabled: true,
                                        triggerMode: .toggle,
                                        isRecording: true)
        #expect(rejected.actions == [.rejectedBusyPress])
        _ = state.transition(for: flagsChanged(54, []),
                             hotkey: rightCmd,
                             promptHotkey: promptHotkey,
                             promptHotkeyEnabled: true,
                             triggerMode: .toggle,
                             isRecording: true)

        let promptStop = promptPress(&state, triggerMode: .toggle, isRecording: true)
        #expect(promptStop.actions == [.releasePrompt])
    }

    @Test func rejectedPromptHoldReleaseDoesNotStopStandardRoute() {
        let f5 = hotkeyChoice(forKeycode: 96)
        var state = HotkeyTransitionState()
        let standardStart = state.transition(for: keyEvent(.keyDown, 96),
                                             hotkey: f5,
                                             promptHotkey: promptHotkey,
                                             promptHotkeyEnabled: true,
                                             triggerMode: .hold,
                                             isRecording: false)
        #expect(standardStart.actions == [.press])

        let rejected = promptPress(&state,
                                   triggerMode: .hold,
                                   isRecording: true,
                                   hotkey: f5)
        let rejectedRelease = promptRelease(&state,
                                            triggerMode: .hold,
                                            isRecording: true,
                                            hotkey: f5)
        #expect(rejected.actions == [.rejectedBusyPress])
        #expect(rejectedRelease.actions.isEmpty)

        let standardStop = state.transition(for: keyEvent(.keyUp, 96),
                                            hotkey: f5,
                                            promptHotkey: promptHotkey,
                                            promptHotkeyEnabled: true,
                                            triggerMode: .hold,
                                            isRecording: true)
        #expect(standardStop.actions == [.release])
    }

    @Test func alternateCompletionCannotStopPromptRecording() {
        var state = HotkeyTransitionState()
        _ = promptPress(&state, triggerMode: .toggle, isRecording: false)
        _ = promptRelease(&state, triggerMode: .toggle, isRecording: true)
        _ = state.transition(for: flagsChanged(61, .maskAlternate),
                             hotkey: rightCmd,
                             promptHotkey: promptHotkey,
                             promptHotkeyEnabled: true,
                             triggerMode: .toggle,
                             isRecording: true)
        let alternate = state.transition(for: flagsChanged(54, [.maskAlternate, .maskCommand]),
                                         hotkey: rightCmd,
                                         promptHotkey: promptHotkey,
                                         promptHotkeyEnabled: true,
                                         triggerMode: .toggle,
                                         isRecording: true)
        #expect(alternate.actions == [.rejectedBusyPress])
    }

    @Test func unrelatedKeyPassesThrough() {
        var state = HotkeyTransitionState()
        let result = state.transition(for: keyEvent(.keyDown, 0),
                                      hotkey: rightCmd, triggerMode: .toggle, isRecording: false)
        #expect(result == .pass)
    }

    @Test func resetToggleStateRealignsAfterExternalStop() {
        var state = HotkeyTransitionState()
        _ = state.transition(for: flagsChanged(54, .maskCommand),
                             hotkey: rightCmd, triggerMode: .toggle, isRecording: false)
        // Запись остановлена снаружи (Escape / максимальная длительность).
        state.resetToggleState()
        _ = state.transition(for: flagsChanged(54, []),
                             hotkey: rightCmd, triggerMode: .toggle, isRecording: false)
        let next = state.transition(for: flagsChanged(54, .maskCommand),
                                    hotkey: rightCmd, triggerMode: .toggle, isRecording: false)
        // Без сброса здесь был бы .release — смещение на одно нажатие навсегда.
        #expect(next.actions == [.press])
    }

    @Test func resetToggleStateRealignsPromptRoute() {
        var state = HotkeyTransitionState()
        _ = promptPress(&state, triggerMode: .toggle, isRecording: false)
        _ = promptRelease(&state, triggerMode: .toggle, isRecording: true)
        state.resetToggleState()

        let next = promptPress(&state, triggerMode: .toggle, isRecording: false)
        #expect(next.actions == [.pressPrompt])
    }

    @Test func escapeResetsPromptToggle() {
        var state = HotkeyTransitionState()
        _ = promptPress(&state, triggerMode: .toggle, isRecording: false)
        _ = promptRelease(&state, triggerMode: .toggle, isRecording: true)

        let escape = state.transition(for: keyEvent(.keyDown, ESCAPE_KEYCODE),
                                      hotkey: rightCmd,
                                      promptHotkey: promptHotkey,
                                      promptHotkeyEnabled: true,
                                      triggerMode: .toggle,
                                      isRecording: true)
        #expect(escape.actions == [.cancel])
        _ = state.transition(for: keyEvent(.keyUp, ESCAPE_KEYCODE),
                             hotkey: rightCmd,
                             promptHotkey: promptHotkey,
                             promptHotkeyEnabled: true,
                             triggerMode: .toggle,
                             isRecording: false)

        let next = promptPress(&state, triggerMode: .toggle, isRecording: false)
        #expect(next.actions == [.pressPrompt])
    }

    @Test func historyRouteStillWorksWithPromptEnabled() {
        let historyHotkey = hotkeyChoice(forKeycode: 54, modifiers: .maskShift)
        var state = HotkeyTransitionState()
        _ = state.transition(for: flagsChanged(56, .maskShift),
                             hotkey: rightCmd,
                             historyHotkey: historyHotkey,
                             promptHotkey: promptHotkey,
                             promptHotkeyEnabled: true,
                             triggerMode: .toggle,
                             isRecording: false)
        let history = state.transition(for: flagsChanged(54, [.maskShift, .maskCommand]),
                                       hotkey: rightCmd,
                                       historyHotkey: historyHotkey,
                                       promptHotkey: promptHotkey,
                                       promptHotkeyEnabled: true,
                                       triggerMode: .toggle,
                                       isRecording: false)
        #expect(history.actions == [.showHistory])
    }
}

// MARK: - Поведение завершения

@Suite("Completion behavior")
struct CompletionBehaviorTests {
    @Test func enterDecisionMatrix() {
        #expect(!shouldPressEnterAfterDictation(shortcut: .standard, primaryBehavior: .insert))
        #expect(shouldPressEnterAfterDictation(shortcut: .standard, primaryBehavior: .insertAndEnter))
        // Альтернативное завершение инвертирует основное поведение.
        #expect(shouldPressEnterAfterDictation(shortcut: .alternate, primaryBehavior: .insert))
        #expect(!shouldPressEnterAfterDictation(shortcut: .alternate, primaryBehavior: .insertAndEnter))
    }

    @Test func promptNeverPressesEnter() {
        for shortcut in [DictationReleaseShortcut.standard, .alternate] {
            for behavior in [DictationCompletionBehavior.insert, .insertAndEnter] {
                #expect(!shouldPressEnterAfterVoiceOutput(
                    purpose: .prompt,
                    shortcut: shortcut,
                    primaryBehavior: behavior
                ))
            }
        }
    }
}
