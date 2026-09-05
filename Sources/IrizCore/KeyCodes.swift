// Основано на RuSwitcher (MIT, © 2025 Rashns), коммит 8c45253.
import Foundation

/// Виртуальные коды клавиш (macOS virtual key codes), используемые при разборе
/// ввода и симуляции нажатий. Раньше были разбросаны по коду «магическими» числами.
public enum KC {
    public static let letterA: UInt16 = 0   // Cmd+A — выделить всё
    public static let letterC: UInt16 = 8   // Cmd+C — копировать
    public static let letterV: UInt16 = 9   // Cmd+V — вставить
    public static let enter: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let backspace: UInt16 = 51
    public static let left: UInt16 = 123
    public static let right: UInt16 = 124
    public static let down: UInt16 = 125
    public static let up: UInt16 = 126

    // Модификаторы (для конфигурируемого триггера; различаем лево/право)
    public static let rightCommand: UInt16 = 54
    public static let leftCommand: UInt16 = 55
    public static let leftShift: UInt16 = 56
    public static let capsLock: UInt16 = 57
    public static let leftOption: UInt16 = 58
    public static let leftControl: UInt16 = 59
    public static let rightShift: UInt16 = 60
    public static let rightOption: UInt16 = 61
    public static let rightControl: UInt16 = 62
}
