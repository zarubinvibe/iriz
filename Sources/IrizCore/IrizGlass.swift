// Стекло окна iriz. Всё стекло продукта описано здесь и больше нигде.
//
// Написано заново после четырёх неудачных заходов. Каждый провал стоит того,
// чтобы быть названным: он и есть правило, которое иначе нарушат снова.
//
//   1. Стекло поверх непрозрачного окна    -> матовая плита, «где Liquid Glass?»
//   2. Цвет и прозрачность без размытия     -> дырка: сквозь окно виден ЧУЖОЙ
//                                              текст резко, не читается ничего
//   3. Один NSVisualEffectView               -> размывает, но матовый, без блика
//   4. `.glassEffect(.clear)` как весь фон  -> опять дырка: `.clear` НЕ размывает
//
// Отсюда состав. Размытие и глянец - разные вещи, и ни одна из них по
// отдельности не даёт Liquid Glass:
//
//   размытие  берёт то, что ЗА окном, и превращает в фон  -> NSVisualEffectView
//   глянец    даёт блик и преломление по кромке           -> .glassEffect
//   читаемость даёт матовая плита ПОД строкой              -> .thinMaterial
//
// Порядок слоёв снизу вверх, и он не переставляется:
//
//   окно (прозрачное, обрезано по скруглению)
//   +-- IrizGlassBackdrop .... размытие + Олимп + глянец   весь фон
//       +-- три области стекла .. боковик и низ плотнее, страница прозрачнее
//           +-- плита ........ матовая, под буквами        строки формы
//
// «Прозрачное на прозрачном даёт более плотный фон» - слова владельца и
// одновременно устройство панелей: панель не красится, она накладывается.
import AppKit
import SwiftUI

// MARK: - Дно окна

/// Фон всего окна: размыто, прозрачно, глянцево.
public struct IrizGlassBackdrop: View {
    /// Габариты плавающих плит. Держатся здесь, потому что по ним же считает
    /// отступ содержимого: разъехавшись, плита начнёт резать текст.
    public static let footerHeight: CGFloat = 56
    public static let sidebarWidth: CGFloat = 200
    /// Зазор между плитой и кромкой окна. Плита ПЛАВАЕТ, а не приклеена: без
    /// зазора она читается как приваренная колонка, и скругление углов теряет
    /// смысл.
    public static let plateInset: CGFloat = 10
    public static let plateRadius: CGFloat = 16

    public init() {}

    public var body: some View {
        // Фон окна - прозрачное стекло с ПРЕЛОМЛЕНИЕМ.
        //
        // Владелец увидел этот эффект на плитах и решил, что место ему здесь:
        // «то, что у плашек сейчас, идеально для фона основного». Логика
        // сходится: искажение принадлежит окну целиком, а плиты отличаются от
        // него уже плотностью, а не наличием эффекта.
        //
        // Здесь по очереди стояли матовый материал, стекло с глянцем сверху,
        // NSGlassEffectView и размытый Олимп поверх всего. Гора убрана по
        // решению владельца: она соревновалась с содержимым за внимание.
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(.clear, in: .rect(cornerRadius: 0))
                .ignoresSafeArea()
        } else {
            IrizBackdropBlur(material: .hudWindow).ignoresSafeArea()
        }
    }
}

/// Плавающая плита: боковик и нижняя полоса.
///
/// Владелец назвал форму точно: плиты идут ПОВЕРХ содержимого и со
/// скруглёнными углами. Это и есть форма Liquid Glass - панель не встык к
/// кромке окна, а отдельная поверхность, под которой содержимое продолжается.
///
/// `.regular`, а не `.clear`: под меню и кнопками нужна правка светимости
/// подложки, иначе текст плиты ложится прямо на то, что просвечивает сквозь
/// окно, и читается через раз.
public struct IrizFloatingPlate: View {
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        if #available(macOS 26.0, *) {
            // Плотность даёт ЗАЛИВКА ПОД стеклом, а не тон в нём.
            //
            // Замер: тон `.clear`-стекла с 0.20 до 0.42 сдвинул пропускание
            // плиты с 0.418 до 0.420, то есть ни на что. Тон красит блик, а не
            // толщу. Владелец же просил ровно толщу: «в два раза меньше
            // светопроницаемости, они не читаемы на белом фоне».
            //
            // Заливка стоит СОСЕДОМ под стеклом, а не модификатором `.opacity`
            // на нём: opacity на стекле схлопывает преломление (правило G04).
            ZStack {
                RoundedRectangle(cornerRadius: IrizGlassBackdrop.plateRadius,
                                 style: .continuous)
                    .fill(scheme == .dark
                          ? Color.black.opacity(0.30)
                          : Color.white.opacity(0.34))
                // `.regular`, а не `.clear`: владелец просил плиты МАТОВЫМ
                // стеклом, потому что на белом фоне текст на прозрачном не
                // читается. `.regular` правит светимость подложки ради
                // читаемости - ровно та работа, которая тут нужна.
                //
                // Фон окна при этом остаётся `.clear`: он не несёт текста, и
                // прозрачность с преломлением там принята владельцем.
                RoundedRectangle(cornerRadius: IrizGlassBackdrop.plateRadius,
                                 style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular,
                                 in: .rect(cornerRadius: IrizGlassBackdrop.plateRadius))
            }
        } else {
            RoundedRectangle(cornerRadius: IrizGlassBackdrop.plateRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }
}

/// Настоящее стекло macOS 26.
///
/// До этого дно окна собиралось из `NSVisualEffectView` плюс `.glassEffect`
/// сверху. Картинка выходила похожей, но материал - это НЕ Liquid Glass: он не
/// участвует в сэмплировании стекла, поэтому всё, что клалось поверх него,
/// преломлять было нечего. Отсюда и плоская капсула выбора, и глянец,
/// выродившийся в волосок по кромке.
///
/// `NSGlassEffectView` - тот самый примитив. Своего содержимого ему не даём:
/// здесь он работает подложкой целого окна, а интерфейс живёт выше по стопке.
public struct IrizGlassSurface: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 0
            return glass
        }
        // До 26 стекла в системе нет вовсе, и подделывать его нечестно:
        // остаётся честное матовое размытие.
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {}
}

/// Панель поверх дна: боковик, нижняя полоса.
///
/// Своего цвета нет. Плотность даёт наложение: тонкий материал поверх оконного
/// стекла читается плотнее стекла, и панель отделяется от содержимого без
/// единой линии.
// MARK: - Составные части


/// Размытие того, что ЗА окном.
///
/// `behindWindow` обязателен. `withinWindow` размывает содержимое самого окна, и
/// панель становится мутным пятном поверх своей же формы вместо окна в мир.
struct IrizBackdropBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // `.active`, а не следование фокусу: иначе стекло превращается в плоскую
        // заливку ровно тогда, когда окно неактивно - то есть на каждом кадре,
        // снятом со стороны.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}


/// Оправа поля ввода на стекле.
///
/// Системные `.roundedBorder` и `.squareBorder` рисуются непрозрачной коробкой:
/// в стеклянном окне поле читается как дырка в поверхности. Своя оправа - то же
/// стекло, что у плит, только тоньше, чтобы поле оставалось полем, а не второй
/// плитой поверх первой.
public struct IrizSearchFieldPlate: View {
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if #available(macOS 26.0, *) {
            ZStack {
                shape.fill(scheme == .dark
                           ? Color.black.opacity(0.22)
                           : Color.white.opacity(0.24))
                shape.fill(.clear).glassEffect(.clear, in: .rect(cornerRadius: 8))
                shape.stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}
