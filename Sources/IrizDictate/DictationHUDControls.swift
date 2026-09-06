// Управление прямо с плашки: язык и быстрые переходы.
//
// Владелец: «я ещё про фичи с переключением языка, сворачиванием и
// разворачиванием плашки». Первое здесь.
//
// ПОЧЕМУ ЯЗЫК ЖИВЁТ НА ПЛАШКЕ, А НЕ ТОЛЬКО В НАСТРОЙКАХ.
//
// Язык меняют в тот момент, когда собираются говорить на другом - то есть за
// секунду до нажатия клавиши. Идти за этим в настройки значит бросить мысль,
// открыть окно, найти страницу и вернуться. Плашка уже под курсором и уже
// говорит о диктовке; ей это решение и принадлежит.
//
// Меню правой кнопкой, а не левой: левая занята перетаскиванием плашки, и
// отбирать её у жеста, которым владелец двигает плашку каждый день, нельзя.
import AppKit

/// Что плашка умеет попросить у приложения.
///
/// Одной структурой, а не пятью замыканиями в конструкторе: набор будет расти
/// (владелец назвал ещё сворачивание), и каждый новый пункт иначе означал бы
/// правку четырёх слоёв протяжки.
public struct DictationHUDControls: Sendable {
    public var currentLanguage: @MainActor () -> DictationLanguage
    public var setLanguage: @MainActor (DictationLanguage) -> Void
    public var currentSize: @MainActor () -> DictationHUDSizeChoice
    public var setSize: @MainActor (DictationHUDSizeChoice) -> Void
    public var openSettings: @MainActor () -> Void
    public var openHistory: @MainActor () -> Void
    /// Начать или закончить запись прямо с плашки. Кнопка, ради которой её и
    /// открывают: до неё запись начиналась только клавишей.
    public var toggleRecording: @MainActor () -> Void
    /// Идёт ли запись сейчас. Нужен кнопке: она обязана называться «закончить»
    /// ровно тогда, когда закончить и правда можно.
    public var isRecording: @MainActor () -> Bool
    /// Начать запись для промпта прямо с плашки.
    public var startPrompt: @MainActor () -> Void
    /// Начать запись для перевода прямо с плашки.
    public var startTranslation: @MainActor () -> Void

    public init(currentLanguage: @escaping @MainActor () -> DictationLanguage,
                setLanguage: @escaping @MainActor (DictationLanguage) -> Void,
                currentSize: @escaping @MainActor () -> DictationHUDSizeChoice = { .medium },
                setSize: @escaping @MainActor (DictationHUDSizeChoice) -> Void = { _ in },
                openSettings: @escaping @MainActor () -> Void,
                openHistory: @escaping @MainActor () -> Void,
                toggleRecording: @escaping @MainActor () -> Void = {},
                isRecording: @escaping @MainActor () -> Bool = { false },
                startPrompt: @escaping @MainActor () -> Void = {},
                startTranslation: @escaping @MainActor () -> Void = {}) {
        self.currentLanguage = currentLanguage
        self.setLanguage = setLanguage
        self.currentSize = currentSize
        self.setSize = setSize
        self.openSettings = openSettings
        self.openHistory = openHistory
        self.toggleRecording = toggleRecording
        self.isRecording = isRecording
        self.startPrompt = startPrompt
        self.startTranslation = startTranslation
    }
}

/// Языки в меню плашки.
///
/// Не все, которые знает распознаватель: список из четырнадцати строк под
/// курсором - это не выбор, а поиск. Здесь те, на которых владелец говорит, и
/// «определять самому» первым пунктом.
public let dictationHUDMenuLanguages: [DictationLanguage] = [.auto, .russian, .english]

/// Как язык называется в меню.
public func dictationLanguageMenuTitle(_ language: DictationLanguage) -> String {
    switch language {
    case .auto: return "Определять самому"
    case .russian: return "Русский"
    case .english: return "Английский"
    case .spanish: return "Испанский"
    case .french: return "Французский"
    case .german: return "Немецкий"
    case .italian: return "Итальянский"
    case .portuguese: return "Португальский"
    case .romanian: return "Румынский"
    case .polish: return "Польский"
    case .czech: return "Чешский"
    case .slovak: return "Словацкий"
    case .slovenian: return "Словенский"
    case .croatian: return "Хорватский"
    case .bosnian: return "Боснийский"
    case .ukrainian: return "Украинский"
    case .belarusian: return "Белорусский"
    case .bulgarian: return "Болгарский"
    case .serbian: return "Сербский"
    }
}

/// Меню плашки. Собирается чистой функцией, чтобы состав пунктов проверялся
/// пробой без окна и без мыши.
@MainActor
public func makeDictationHUDMenu(controls: DictationHUDControls) -> NSMenu {
    let menu = NSMenu()
    let current = controls.currentLanguage()

    let languageItem = NSMenuItem(title: "Язык распознавания", action: nil, keyEquivalent: "")
    let languageMenu = NSMenu()
    for language in dictationHUDMenuLanguages {
        let item = NSMenuItem(title: dictationLanguageMenuTitle(language),
                              action: #selector(DictationHUDMenuTarget.pick(_:)),
                              keyEquivalent: "")
        // Галочка на текущем: меню без отметки заставляет владельца помнить, на
        // чём он остановился, а он открывает его как раз потому, что не помнит.
        item.state = language == current ? .on : .off
        item.representedObject = language.rawValue
        item.target = DictationHUDMenuTarget.shared
        languageMenu.addItem(item)
    }
    languageItem.submenu = languageMenu
    menu.addItem(languageItem)

    // Свернуть и развернуть. Что именно значит «свернуть», владелец не уточнил,
    // и решение принято здесь: это переключение размера плашки, а не её
    // исчезновение. Плашка - единственный признак того, что запись идёт;
    // прятать её целиком значит сделать состояние записи невидимым, а этого он
    // как раз добивался обратного, прося цвет для встречи.
    let size = controls.currentSize()
    let sizeItem = NSMenuItem(
        title: size == .small ? "Развернуть плашку" : "Свернуть плашку",
        action: #selector(DictationHUDMenuTarget.toggleSize),
        keyEquivalent: ""
    )
    sizeItem.target = DictationHUDMenuTarget.shared
    menu.addItem(sizeItem)

    menu.addItem(.separator())

    let history = NSMenuItem(title: "История надиктовок",
                             action: #selector(DictationHUDMenuTarget.history),
                             keyEquivalent: "")
    history.target = DictationHUDMenuTarget.shared
    menu.addItem(history)

    let settings = NSMenuItem(title: "Настройки…",
                              action: #selector(DictationHUDMenuTarget.settings),
                              keyEquivalent: "")
    settings.target = DictationHUDMenuTarget.shared
    menu.addItem(settings)

    DictationHUDMenuTarget.shared.controls = controls
    return menu
}

/// Приёмник действий меню.
///
/// Отдельным объектом, потому что `NSMenuItem.target` держит СЛАБУЮ ссылку: у
/// замыкания, привязанного к пункту, не было бы владельца, и меню молча
/// перестало бы отвечать после первой же уборки памяти.
@MainActor
public final class DictationHUDMenuTarget: NSObject {
    public static let shared = DictationHUDMenuTarget()
    var controls: DictationHUDControls?

    @objc func pick(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = DictationLanguage(rawValue: raw) else { return }
        controls?.setLanguage(language)
    }

    /// Свернуть или развернуть. Развёрнутое состояние - средний размер, а не
    /// большой: большой владелец выбирает сам и терять его на сворачивании он
    /// не просил.
    @objc func toggleSize() {
        guard let controls else { return }
        controls.setSize(controls.currentSize() == .small ? .medium : .small)
    }

    @objc func history() { controls?.openHistory() }
    @objc func settings() { controls?.openSettings() }
}
