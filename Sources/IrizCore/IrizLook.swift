// Канон вида: одни и те же решения на все окна продукта.
//
// Вынесено сюда и сделано ПУБЛИЧНЫМ по итогу разбора. Раньше эта пятёрка жила
// внутри окна настроек и была недоступна остальным модулям, поэтому окно
// истории завело свою подсветку строки, меню строки меню - вторую, а превью
// плашки - третью. Расхождение не в невнимательности: канон физически нельзя
// было применить, и каждый экран честно выдумывал своё.
//
// Правило простое: ни одно окно продукта не заводит своей кривой, своего
// радиуса, своего способа подсветки и своего приглушённого цвета.
import AppKit
import SwiftUI

// MARK: - Цвет

/// Приглушённый текст, который всё ещё читается.
///
/// Системный `.secondary` рассчитан на НЕПРОЗРАЧНУЮ подложку. У нас сквозь
/// плиту видно что угодно, и разбор намерил на нём контраст 2,84 у строки
/// состояния и 3,32 у мелкой сноски при пороге 4,5.
public let IRIZ_SUBTLE = Color.primary.opacity(0.78)

/// Тон выбранной капсулы. Смешанный ЦВЕТ, а не accent с прозрачностью:
/// `opacity` на стекле схлопывает преломление (правило G04 линтера).
public let IRIZ_SELECTION_TINT = Color(nsColor: NSColor.controlAccentColor.blended(
    withFraction: 0.45, of: .windowBackgroundColor) ?? .controlAccentColor)

/// Радиус подсветки строки. Один на продукт: в окне истории он был 8, в меню
/// строки меню 5, в превью плашки 14.
public let IRIZ_SELECTION_RADIUS: CGFloat = 9

// MARK: - Движение

public extension Animation {
    /// Вход и смена содержимого. Сильный ease-out: движение начинается сразу и
    /// гаснет к концу, поэтому 200 мс ощущаются быстрее, чем 200 мс любой
    /// встроенной кривой. `ease-in` в продукте запрещён - он тормозит ровно
    /// тот первый кадр, на который смотрит человек.
    static let irizEaseOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)

    /// Короткий отклик: нажатие, наведение, появление подсказки.
    static let irizQuick = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)

    /// Переезд поверхности. Пружина, а не кривая: стекло едет как вещь, с
    /// весом. Отскок нулевой - меню не должно играть.
    static let irizMove = Animation.snappy(duration: 0.28)
}

/// Нажатие. Без отклика кнопка кажется картинкой: нажал, ничего не шевельнулось.
/// 0.97 - предел, за которым сжатие уже видно как трюк.
public struct IrizPressStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.irizQuick, value: configuration.isPressed)
    }
}

// MARK: - Подсветка выбранного

/// Капсула выбранной строки: тонированное стекло, которое ПЕРЕЕЗЖАЕТ.
///
/// Так сделаны вкладки часов на iOS: стекло не гаснет на старом месте и не
/// зажигается на новом, оно едет. Держится на одном `glassEffectID` для всех
/// строк - система видит одну капсулу, сменившую место, а не две разные.
///
/// Тон, а не заливка: сквозь цвет видно подложку, и выбранная строка остаётся
/// частью той же поверхности. Заливка `Color.accentColor` с белым текстом,
/// которая стояла в окне истории, давала контраст 4,02 при пороге 4,5.
public struct IrizSelection: ViewModifier {
    let selected: Bool
    let namespace: Namespace.ID
    let group: String

    public init(selected: Bool, namespace: Namespace.ID, group: String = "selection") {
        self.selected = selected
        self.namespace = namespace
        self.group = group
    }

    public func body(content: Content) -> some View {
        if selected, #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(IRIZ_SELECTION_TINT).interactive(),
                    in: .rect(cornerRadius: IRIZ_SELECTION_RADIUS)
                )
                .glassEffectID(group, in: namespace)
        } else if selected {
            content.background(
                RoundedRectangle(cornerRadius: IRIZ_SELECTION_RADIUS, style: .continuous)
                    .fill(Color.accentColor)
                    .matchedGeometryEffect(id: group, in: namespace)
            )
        } else {
            content
        }
    }
}

public extension View {
    /// Подсветка выбранной строки по канону продукта.
    func irizSelected(_ selected: Bool, in namespace: Namespace.ID,
                      group: String = "selection") -> some View {
        modifier(IrizSelection(selected: selected, namespace: namespace, group: group))
    }
}

// MARK: - Уважение к настройке «уменьшить движение»

/// Система гасит СВОЮ анимацию, но `withAnimation` и `.animation` она не
/// трогает. Гейт приходится ставить руками в каждом месте движения.
///
/// Читается из AppKit, а не из окружения SwiftUI: справочник скилла прямо
/// указывает `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` для
/// AppKit-стороны, и так гейт доступен из любого места без протяжки
/// `@Environment` через каждое окно.
///
/// Цена решения названа: значение читается на отрисовке, поэтому переключение
/// настройки применяется к уже открытому окну не мгновенно, а на следующей
/// перерисовке. Для настройки, которую меняют раз в жизни, это допустимо.
public var irizReduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

/// Анимация или ничего, по настройке доступности.
public func irizAnimation(_ animation: Animation) -> Animation? {
    irizReduceMotion ? nil : animation
}
