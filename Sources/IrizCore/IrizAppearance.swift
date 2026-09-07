// Тема интерфейса: системная или выбранная руками.
//
// Почему выбор, а не только системная. Владелец 07.09.2026: «необходимо
// выбирать тёмный вариант, если это возможно. То есть тёмную тему тоже и
// светлую можно выбирать в настройках». Довод тот же, что у языка: человек
// держит macOS на автопереключении по времени суток, а конкретное окно хочет
// видеть всегда одинаковым — и наоборот.
//
// Плашки это НЕ касается. Она висит поверх чужого окна и берёт системный вид:
// навязать ей тёмное стекло на светлом столе значит поставить чёрный прямоугольник
// посреди чужой работы.
import AppKit

/// Ключ выбора темы. В том же домене, что и остальные настройки.
public let IRIZ_APPEARANCE_KEY = "ru.iriz.interfaceAppearance"

public enum IrizAppearanceChoice: String, CaseIterable, Sendable {
    /// Как в системе. Заводское значение.
    case auto
    case light
    case dark

    /// Имя для списка. По-русски: продукт написан по-русски, перевод берётся
    /// таблицей, как и всё остальное.
    public var title: String {
        switch self {
        case .auto: return L("appearance.auto", "Как в системе")
        case .light: return L("appearance.light", "Светлая")
        case .dark: return L("appearance.dark", "Тёмная")
        }
    }

    /// Вид AppKit, который надо навязать. `nil` — не навязывать ничего.
    public var appearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

public func irizAppearanceChoice(defaults: UserDefaults = .standard) -> IrizAppearanceChoice {
    guard let raw = defaults.string(forKey: IRIZ_APPEARANCE_KEY),
          let choice = IrizAppearanceChoice(rawValue: raw) else { return .auto }
    return choice
}

public func setIrizAppearanceChoice(_ choice: IrizAppearanceChoice,
                                    defaults: UserDefaults = .standard) {
    defaults.set(choice.rawValue, forKey: IRIZ_APPEARANCE_KEY)
}

/// Применить выбор ко всему приложению.
///
/// Ставится на `NSApp`, а не на каждое окно: окон у продукта четыре, и держать
/// в каждом свою копию правила значит однажды забыть одно из них. Плашка при
/// этом свой вид задаёт сама и системного не теряет.
@MainActor
public func applyIrizAppearance(defaults: UserDefaults = .standard) {
    NSApp?.appearance = irizAppearanceChoice(defaults: defaults).appearance
}
