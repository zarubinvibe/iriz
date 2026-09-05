// Основано на RuSwitcher (MIT, © 2025 Rashns), коммит 8c45253.
import AppKit
import CoreGraphics
import Foundation
import IrizCore

/// Маркер для симулированных событий — KeyboardMonitor их игнорирует
let kRuSwitcherEventMarker: Int64 = 0x52555300

/// Одно нажатие в буфере конверсии. Для обычного локального ввода известен keyCode
/// (char == nil). Для ввода, проброшенного через удалённый стол, Apple Screen Sharing
/// шлёт keyCode 0 + сам символ — тогда char != nil, и конверсия идёт по символу,
/// а не по бесполезному keyCode 0 (именно keyCode 0 рождал «фффффф»).
public struct TypedKey {
    public let keyCode: UInt16
    public let shift: Bool
    public let caps: Bool
    public var char: Character? = nil
}

/// Выделенная очередь для файлового I/O лога — чтобы запись на диск не блокировала
/// поток обработки событий (event tap висит на главном run loop, а лог пишется
/// для каждого нажатия при включённом debug).
private let rsLogQueue = DispatchQueue(label: "ru.smltlk.log")

public func rslog(_ msg: String) {
    // Thread-safe: читаем UserDefaults напрямую (без MainActor)
    guard UserDefaults.standard.bool(forKey: "ru.smltlk.debugLog") else { return }

    let line = "\(Date()): \(msg)\n"
    rsLogQueue.async {
        let logDir = NSHomeDirectory() + "/Library/Logs"
        let path = logDir + "/smltlk.log"

        // Создаём директорию если нет
        if !FileManager.default.fileExists(atPath: logDir) {
            try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            // Ротация: если > 5MB — обрезаем
            if handle.offsetInFile > 5_000_000 {
                handle.truncateFile(atOffset: 0)
                handle.write("--- Log rotated ---\n".data(using: .utf8)!)
            }
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }
}

/// Конфигурация клавиши-триггера (читается из настроек, кэшируется в KeyboardMonitor).
struct TriggerConfig {
    enum Kind {
        case modifier(mask: CGEventFlags, left: UInt16, right: UInt16)
        /// Комбо из двух модификаторов (например ⌘+⇧). Детект по флагам: оба зажаты без
        /// посторонних → отпущены все без клавиш между. Сторона (left/right) не важна.
        case combo(CGEventFlags, CGEventFlags)
        case capsLock
    }
    let kind: Kind
    let rightOnly: Bool
    let doubleTap: Bool

    var isCapsLock: Bool { if case .capsLock = kind { return true } else { return false } }

    static func current() -> TriggerConfig {
        let s = SettingsManager.shared
        return parse(key: s.triggerKey, rightOnly: s.triggerRightOnly, doubleTap: s.triggerDoubleTap)
    }

    /// issue #14: конфиг хоткея чистого переключения раскладки. nil — выключен.
    /// Совпадение с триггером конверсии игнорируем (иначе один тап делал бы оба действия).
    /// Белый список обязателен: parse() маппит неизвестные строки в Option — рукописный
    /// мусор в defaults дублировал бы дефолтный триггер (ревью-находка).
    static func switchHotkey() -> TriggerConfig? {
        let known: Set<String> = ["option", "command", "control", "shift",
                                  "command+shift", "control+shift", "command+option", "control+option"]
        let s = SettingsManager.shared
        let key = s.switchHotkey
        guard known.contains(key), key != s.triggerKey else { return nil }
        return parse(key: key, rightOnly: s.switchRightOnly, doubleTap: s.switchDoubleTap)
    }

    static func parse(key: String, rightOnly: Bool, doubleTap: Bool) -> TriggerConfig {
        let kind: Kind
        switch key {
        case "command": kind = .modifier(mask: .maskCommand, left: KC.leftCommand, right: KC.rightCommand)
        case "control": kind = .modifier(mask: .maskControl, left: KC.leftControl, right: KC.rightControl)
        case "shift":   kind = .modifier(mask: .maskShift,   left: KC.leftShift,   right: KC.rightShift)
        // Комбо двух модификаторов (issue #12: привычный по Windows стиль Alt+Shift и т.п.).
        case "command+shift":  kind = .combo(.maskCommand, .maskShift)
        case "control+shift":  kind = .combo(.maskControl, .maskShift)
        case "command+option": kind = .combo(.maskCommand, .maskAlternate)
        case "control+option": kind = .combo(.maskControl, .maskAlternate)
        // ТЕХДОЛГ: нативный Caps Lock убран из UI (нестабилен — HID-дебаунс/тоггл,
        // нужен HID-драйвер уровня Karabiner). Код consume-пути оставлен на будущее.
        case "capsLock": kind = .capsLock
        default:        kind = .modifier(mask: .maskAlternate, left: KC.leftOption, right: KC.rightOption)
        }
        return TriggerConfig(kind: kind, rightOnly: rightOnly, doubleTap: doubleTap)
    }
}

public final class KeyboardMonitor: @unchecked Sendable {
    public init() {}

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Длина текущего набираемого слова
    private(set) var currentWordLength = 0
    /// Длина слова до последнего пробела
    private(set) var wordBeforeBoundaryLength = 0
    /// Сколько пробелов после слова (только пробелы, не enter/стрелки)
    public private(set) var boundaryCount = 0
    /// Были ли реальные нажатия после последней конвертации?
    private(set) var keysTypedSinceConversion = true

    /// Нажатия набираемого слова — для движка перепечатки (без буфера обмена)
    public private(set) var currentWordKeys: [TypedKey] = []
    /// Нажатия слова перед последней границей-пробелом
    public private(set) var prevWordKeys: [TypedKey] = []
    /// Фронтмост-приложение на момент границы слова — чтобы авто-путь не перепечатал
    /// в другое поле, если фокус уехал (Cmd-Tab/Spotlight) без клика/Tab.
    public private(set) var prevWordBundleID: String?
    private var onAltTap: (() -> Void)?
    private var onAltReconvert: (() -> Void)?
    /// Авто-конвертация: вызывается (async) на границе слова, когда включён autoConvert.
    public var onWordBoundary: (() -> Void)?
    /// Счётчик набранных слов (агрегаты для counters.json): дёргается на КАЖДОЙ
    /// границе слова независимо от autoConvert. Только факт слова, без содержимого.
    public var onWordCounted: (() -> Void)?

    // Конфиг триггера (кэш; обновляется в start/reconfigure)
    private var triggerConfig = TriggerConfig.current()
    /// issue #14: второй хоткей — чистое переключение раскладки (nil = выключен).
    private var switchConfig = TriggerConfig.switchHotkey()
    private var switchArmed = false
    private var switchPressTime: Date?
    private var switchLastTapTime: Date?   // для double-tap хоткея смены
    /// Колбэк чистого переключения раскладки (issue #14). Ставится из AppDelegate.
    public var onSwitchHotkey: (() -> Void)?
    /// Система отключила наш тап (таймаут обработчика или ввод пользователя).
    /// Аргумент - удалось ли включить его обратно.
    ///
    /// Молчать тут нельзя: тап отвалился - раскладка перестала исправляться, и
    /// узнать об этом владелец мог только тем, что «перестало работать».
    /// Знак строки меню - единственное место, где это видно сразу.
    public var onTapHealthChanged: ((Bool) -> Void)?

    // Детект соло-тапа модификатора
    private var triggerArmed = false
    private var triggerPressTime: Date?
    // Для двойного тапа
    private var lastTapTime: Date?
    private let tapWindow: TimeInterval = 0.4
    // issue #21: окно «тапа» для КОМБО из двух модификаторов. Намеренно большое: аккорд
    // из двух клавиш держат заметно дольше флика одной (0.4с было слишком узко). Но верхний
    // потолок оставлен — иначе комбо срабатывало бы и на «случайное» долгое удержание
    // модификаторов во время скролла/жеста (эти события не сбрасывают armed — их нет в маске
    // event tap'а). 2с покрывает любой намеренный тап и отсекает попутные удержания.
    private let comboTapWindow: TimeInterval = 2.0

    public func start(
        onAltTap: @escaping () -> Void,
        onAltReconvert: @escaping () -> Void
    ) -> Bool {
        self.onAltTap = onAltTap
        self.onAltReconvert = onAltReconvert

        let precheck = CGPreflightListenEventAccess()
        rslog("Preflight check = \(precheck)")
        if !precheck {
            rslog("Requesting access...")
            CGRequestListenEventAccess()
        }

        triggerConfig = TriggerConfig.current()
        switchConfig = TriggerConfig.switchHotkey()
        rslog("Attempting to create event tap... (trigger=\(SettingsManager.shared.triggerKey) switch=\(SettingsManager.shared.switchHotkey.isEmpty ? "off" : SettingsManager.shared.switchHotkey) capsLock=\(triggerConfig.isCapsLock))")
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)

        // Caps Lock требует активного tap (consume), чтобы подавить переключение
        // регистра. Для модификаторов оставляем listenOnly — не вмешиваемся в ввод.
        let options: CGEventTapOptions = triggerConfig.isCapsLock ? .defaultTap : .listenOnly

        // Тап всегда на HID-уровне: режим удалённого стола удалён.
        let tapLocation: CGEventTapLocation = .cghidEventTap

        guard let tap = CGEvent.tapCreate(
            tap: tapLocation,
            place: .tailAppendEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: keyboardCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            rslog("FAILED to create event tap - no permission")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        rslog("Event tap created and enabled successfully")
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Перезапускает tap с актуальным конфигом триггера. Нужен при смене настройки —
    /// особенно при переключении на/с Caps Lock, т.к. меняется режим tap (consume).
    @discardableResult
    public func reconfigure() -> Bool {
        guard let t = onAltTap, let r = onAltReconvert else { return false }
        rslog("Reconfiguring trigger…")
        stop()
        return start(onAltTap: t, onAltReconvert: r)
    }

    public func markConverted() {
        currentWordLength = 0
        wordBeforeBoundaryLength = 0
        boundaryCount = 0
        currentWordKeys = []
        prevWordKeys = []
        keysTypedSinceConversion = false
    }

    private func fullReset() {
        currentWordLength = 0
        wordBeforeBoundaryLength = 0
        boundaryCount = 0
        currentWordKeys = []
        prevWordKeys = []
    }

    /// Завершилось слово на пробеле — счётчик слов дёргаем всегда (агрегаты
    /// counters.json), авто-путь — только когда включён autoConvert
    /// (async, чтобы не блокировать доставку текущего события).
    private func fireWordBoundary() {
        let counted = onWordCounted
        let cb = onWordBoundary
        DispatchQueue.main.async {
            counted?()
            if SettingsManager.shared.autoConvert { cb?() }
        }
    }

    /// Сброс буфера при клике мышью — иначе backspace перепечатки сотрёт не то
    /// (курсор мог уехать в другое место).
    fileprivate func resetBuffersOnClick() {
        triggerArmed = false
        switchArmed = false
        lastTapTime = nil
        switchLastTapTime = nil
        keysTypedSinceConversion = true
        fullReset()
    }

    // MARK: - Event Handling

    fileprivate func handleKeyDown(keyCode: UInt16, flags: CGEventFlags) {
        triggerArmed = false
        switchArmed = false   // issue #14: клавиша между модификаторами = шорткат, не хоткей
        lastTapTime = nil
        switchLastTapTime = nil
        keysTypedSinceConversion = true

        // Структурные клавиши обрабатываем ВСЕГДА, даже если в flags остался
        // «грязный» модификатор (stale .maskAlternate и т.п.) — иначе счётчик
        // слова не сбрасывается и конвертация захватывает лишние символы.

        // Пробел — единственная граница через которую можно вернуться
        if keyCode == KC.space {
            if currentWordLength > 0 {
                wordBeforeBoundaryLength = currentWordLength
                boundaryCount = 1
                prevWordKeys = currentWordKeys
                prevWordBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                fireWordBoundary()
            } else {
                boundaryCount += 1
            }
            currentWordLength = 0
            currentWordKeys = []
            return
        }

        // Enter, Tab — полный сброс
        if keyCode == KC.enter || keyCode == KC.tab {
            fullReset()
            return
        }

        // Стрелки (Left…Up) — полный сброс
        if keyCode >= KC.left && keyCode <= KC.up {
            fullReset()
            return
        }

        // Backspace
        if keyCode == KC.backspace {
            if currentWordLength > 0 {
                currentWordLength -= 1
                if !currentWordKeys.isEmpty { currentWordKeys.removeLast() }
            } else {
                fullReset()
            }
            return
        }

        // (Cmd+A, Cmd+C, Cmd+X и т.п.) могло изменить выделение — сбрасываем наш буфер.
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        if !modifiers.isEmpty {
            fullReset()
            return
        }

        if DynamicKeyMapping.isPrintableKeycode(keyCode) {
            currentWordKeys.append(TypedKey(keyCode: keyCode, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift)))
            currentWordLength += 1
            wordBeforeBoundaryLength = 0
            boundaryCount = 0
            prevWordKeys = []
        } else {
            // Esc, F-клавиши, и т.д. — полный сброс
            fullReset()
        }
    }

    /// Возвращает true, если событие надо «съесть» (только Caps Lock в consume-режиме).
    fileprivate func handleFlagsChanged(flags: CGEventFlags, keyCode: UInt16) -> Bool {
        handleSwitchFlags(flags: flags, keyCode: keyCode)   // issue #14: второй хоткей
        switch triggerConfig.kind {
        case .capsLock:
            guard keyCode == KC.capsLock else { return false }
            // Caps Lock шлёт одно событие на нажатие. Используем как тап и съедаем,
            // чтобы не переключался регистр.
            registerTap()
            return true

        case let .modifier(mask, left, right):
            let accepted: Set<UInt16> = triggerConfig.rightOnly ? [right] : [left, right]
            let allMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            let otherMods = allMods.subtracting(mask)

            if flags.contains(mask) {
                // нажатие: армим только если это нужная клавиша и нет других модификаторов
                if accepted.contains(keyCode) && flags.intersection(otherMods).isEmpty {
                    triggerArmed = true
                    triggerPressTime = Date()
                } else {
                    triggerArmed = false  // не та сторона / комбо
                }
            } else {
                // отпускание: соло-тап нужной клавиши, быстро и без клавиш между
                if triggerArmed, accepted.contains(keyCode), let t = triggerPressTime,
                   Date().timeIntervalSince(t) < tapWindow {
                    registerTap()
                }
                triggerArmed = false
                triggerPressTime = nil
            }
            return false

        case let .combo(maskA, maskB):
            let both: CGEventFlags = [maskA, maskB]
            let allMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            let others = allMods.subtracting(both)
            if !flags.intersection(others).isEmpty {
                triggerArmed = false                 // зажат посторонний модификатор — не наш триггер
            } else if flags.contains(both) {
                triggerArmed = true                  // ровно оба нужных, без посторонних → армим
                triggerPressTime = Date()
            } else if flags.intersection(allMods).isEmpty {
                // всё отпущено: комбо, если был армлен и без клавиш между (triggerArmed это
                // гарантирует). Окно расширено 0.4→2с (comboTapWindow, issue #21), но потолок
                // сохранён — не срабатывать на попутное удержание во время скролла/жеста.
                if triggerArmed, let t = triggerPressTime, Date().timeIntervalSince(t) < comboTapWindow {
                    registerTap()
                }
                triggerArmed = false
                triggerPressTime = nil
            }
            // частичное состояние (зажат один из двух) — ждём, ничего не трогаем
            return false
        }
    }

    /// issue #14: параллельная машина второго хоткея — чистое переключение раскладки.
    /// Зеркалит триггерную логику; Caps Lock не поддерживается, сторона (left/right) не
    /// различается, одиночный/двойной тап — как у триггера (switchDoubleTap). Разоружается
    /// на keyDown/клике вместе с триггером — Ctrl+Shift+P и подобные не переключают.
    private func handleSwitchFlags(flags: CGEventFlags, keyCode: UInt16) {
        guard let cfg = switchConfig else { return }
        let allMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        switch cfg.kind {
        case .capsLock:
            return
        case let .modifier(mask, left, right):
            let accepted: Set<UInt16> = cfg.rightOnly ? [right] : [left, right]
            let otherMods = allMods.subtracting(mask)
            if flags.contains(mask) {
                if accepted.contains(keyCode) && flags.intersection(otherMods).isEmpty {
                    switchArmed = true
                    switchPressTime = Date()
                } else {
                    switchArmed = false
                }
            } else {
                if switchArmed, accepted.contains(keyCode), let t = switchPressTime,
                   Date().timeIntervalSince(t) < tapWindow {
                    registerSwitchTap()
                }
                switchArmed = false
                switchPressTime = nil
            }
        case let .combo(maskA, maskB):
            let both: CGEventFlags = [maskA, maskB]
            let others = allMods.subtracting(both)
            if !flags.intersection(others).isEmpty {
                switchArmed = false
            } else if flags.contains(both) {
                switchArmed = true
                switchPressTime = Date()
            } else if flags.intersection(allMods).isEmpty {
                // issue #21: окно расширено 0.4→2с (comboTapWindow) — аккорд держат дольше
                // флика, но потолок оставлен, чтобы не срабатывать на попутное удержание
                // во время скролла/жеста (не сбрасывают switchArmed).
                if switchArmed, let t = switchPressTime, Date().timeIntervalSince(t) < comboTapWindow {
                    registerSwitchTap()
                }
                switchArmed = false
                switchPressTime = nil
            }
        }
    }

    /// Учитывает одиночный/двойной тап хоткея смены (зеркало registerTap).
    private func registerSwitchTap() {
        if switchConfig?.doubleTap == true {
            if let last = switchLastTapTime, Date().timeIntervalSince(last) < tapWindow {
                switchLastTapTime = nil
                fireSwitch()
            } else {
                switchLastTapTime = Date()  // ждём второй тап
            }
        } else {
            fireSwitch()
        }
    }

    private func fireSwitch() {
        rslog("switch hotkey: fire")
        DispatchQueue.main.async { [weak self] in self?.onSwitchHotkey?() }
    }

    /// Учитывает одиночный/двойной тап и запускает конвертацию.
    private func registerTap() {
        if triggerConfig.doubleTap {
            if let last = lastTapTime, Date().timeIntervalSince(last) < tapWindow {
                lastTapTime = nil
                fireConversion()
            } else {
                lastTapTime = Date()  // ждём второй тап
            }
        } else {
            fireConversion()
        }
    }

    private func fireConversion() {
        if !keysTypedSinceConversion {
            rslog("trigger: RECONVERT")
            DispatchQueue.main.async { [weak self] in self?.onAltReconvert?() }
        } else {
            rslog("trigger: CONVERT")
            DispatchQueue.main.async { [weak self] in self?.onAltTap?() }
        }
    }
}

// MARK: - C Callback

private func keyboardCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            var alive = false
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                // Включили - НЕ значит включилось. Прежде код считал попытку
                // успехом и молчал: если тап не поднялся, приложение тихо
                // переставало исправлять раскладку, и владелец узнавал об этом
                // только тем, что «перестало работать».
                alive = CGEvent.tapIsEnabled(tap: tap)
            }
            rslog("event tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabled: \(alive)")
            let notify = monitor.onTapHealthChanged
            DispatchQueue.main.async { notify?(alive) }
        }
        return Unmanaged.passRetained(event)
    }

    // Игнорируем собственные симулированные события по маркеру
    if event.getIntegerValueField(.eventSourceUserData) == kRuSwitcherEventMarker {
        return Unmanaged.passRetained(event)
    }

    guard let userInfo else {
        return Unmanaged.passRetained(event)
    }

    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .keyDown {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        monitor.handleKeyDown(keyCode: keyCode, flags: event.flags)
    } else if type == .flagsChanged {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if monitor.handleFlagsChanged(flags: event.flags, keyCode: keyCode) {
            return nil  // съедаем Caps Lock, чтобы не переключался регистр
        }
    } else if type == .leftMouseDown || type == .rightMouseDown {
        monitor.resetBuffersOnClick()
    }

    return Unmanaged.passRetained(event)
}
