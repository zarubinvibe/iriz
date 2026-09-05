// Одно окно настроек на продукт и на прибор.
//
// Прибор, который строит СВОЁ окно, меряет не то, что видит владелец. У
// прошлого прибора было 700x760 и свой набор флагов вместо 980x720 продукта, и
// четыре круга подряд он подтверждал стекло, которого в живом окне не было.
// Расхождение чинится не внимательностью, а тем, что окно собирается ЗДЕСЬ и
// больше нигде: у прибора нет своей копии, которой можно разойтись.
import AppKit
import IrizCore
import IrizSettings
import SwiftUI

@MainActor
func makeIrizSettingsWindow(preview: Bool = false, page: SettingsPage = .keys) -> NSWindow {
    let window = NSWindow(
        // Окно шире прежнего: слева боковик со страницами, справа сама
        // страница. В 700 pt на две колонки не помещалось ничего.
        contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
        // `.resizable` обязателен: содержимое формы выше 772 pt, и без
        // изменения размера владелец обречён скроллить в тесном окне на
        // большом экране. `.fullSizeContentView` пускает содержимое ПОД строку
        // заголовка: без него окно с прозрачным заголовком даёт пустую полосу,
        // в которой висят три кнопки и больше ничего.
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.title = "Настройки \(IRIZ_NAME)"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    // Прозрачность окна - условие существования стекла: непрозрачное окно
    // подставляет стеклу собственную серую плиту, и оно сэмплирует её.
    window.isOpaque = false
    window.backgroundColor = .clear
    // Своей маски по скруглению здесь НЕТ, и это не упущение.
    //
    // Прошлая версия ставила cornerRadius 16 на contentView, который через
    // десять строк заменялся hosting view: код был мёртвым с первого дня.
    // Углы всё это время резала сама система - окно `.titled` с
    // `.fullSizeContentView` сохраняет системную рамку. Замер по кадру дал
    // радиус около 27 pt при зашитых 16, то есть своя маска ещё и врала бы.
    window.contentMinSize = NSSize(width: 900, height: 620)
    window.contentView = NSHostingView(rootView: IrizSettingsView(preview: preview, page: page))
    window.isReleasedWhenClosed = false  // иначе закрытие окна уронит приложение
    return window
}
