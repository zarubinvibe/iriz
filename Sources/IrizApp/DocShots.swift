// Кадры для витрины и знакомства: живые окна продукта, все на трёх языках.
//
// Требование владельца 06.09.2026, дословно: «все скриншоты надо добавлять на
// всех языках, то есть на русском, английском и китайском… прям каждый, каждый
// элемент должен подтверждаться какой-то картинкой».
//
// Почему прибором, а не руками. Кадр, снятый руками, устаревает первым: он не
// пересчитывается при правке вёрстки, не знает про третий язык и живёт ровно до
// следующего переименования кнопки. Здесь кадры собираются из ТЕХ ЖЕ видов,
// которыми живёт продукт, и пересобираются одной командой.
//
// Язык переключается настройкой, той же, которую владелец меняет в окне: другой
// дороги нет и быть не должно - прибор обязан снимать то, что увидит человек, а
// не свою параллельную сборку строк.
import AppKit
import IrizCore
import IrizDictate
import IrizSettings
import SwiftUI

/// Одна поверхность витрины: имя кадра и вид, который в него попадёт.
private struct DocShot {
    let name: String
    let width: CGFloat
    let height: CGFloat?
    let view: AnyView
}

/// Снять весь набор кадров для документации.
///
/// Тёмная тема снимается только для плашки и настроек: в остальных
/// поверхностях она не добавляет знания, а вес витрины утраивает.
@MainActor
func captureDocShots(to directory: URL, appDelegate: AppDelegate) throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
    let previous = irizLanguageChoice()
    defer { setIrizLanguageChoice(previous) }

    var written: [URL] = []
    for language in [IrizLanguage.ru, .en, .zh] {
        setIrizLanguageChoice(language)
        let tag = language.rawValue

        // Настройки: живое окно со стеклом, страница клавиш - её открывают первой.
        let settings = makeIrizSettingsWindow(preview: true, page: .keys)
        let settingsURL = directory.appendingPathComponent("settings-\(tag).png")
        try captureWindowLive(settings, kind: .gradient, dark: false, to: settingsURL)
        settings.close()
        written.append(settingsURL)

        // Остальные поверхности живут внутри панелей и своих окон не имеют.
        // Поднимаем их в окне того же устройства, что у настроек: прозрачном,
        // без заголовка - чтобы стекло сэмплировало подложку, а не серую плиту.
        for shot in docShots(appDelegate: appDelegate) {
            let window = makeDocWindow(width: shot.width, height: shot.height, view: shot.view)
            let url = directory.appendingPathComponent("\(shot.name)-\(tag).png")
            try captureWindowLive(window, kind: .gradient, dark: false, to: url)
            window.close()
            written.append(url)
        }
    }
    return written
}

/// Поверхности, которые обязаны попасть в витрину на каждом языке.
@MainActor
private func docShots(appDelegate: AppDelegate) -> [DocShot] {
    [
        // Высота задана, а не взята у `fittingSize`: она мерит содержимое ДО
        // раскладки шрифтов, и низ меню срезало на каждом кадре.
        DocShot(name: "menu", width: 300, height: 700,
                view: AnyView(MenuContentView(state: docMenuState(), appDelegate: appDelegate))),
        DocShot(name: "history", width: 620, height: 520,
                view: dictationHistoryShotView(.list)),
        DocShot(name: "rescue", width: 620, height: 520,
                view: dictationHistoryShotView(.rescue)),
        // Знакомство: единственная поверхность, которая переведена целиком.
        // Остальные пока показывают русский на любом выбранном языке - у них
        // нет ни одного вызова `L()`, и это честно названо в документации.
        DocShot(name: "firstrun", width: 620, height: 520,
                view: AnyView(FirstRunView(model: FirstRunModel()))),
    ]
}

/// Рабочее состояние меню: модель готова, история не пуста. Аварийные состояния
/// в витрину не идут - там показывают, как продукт работает, а не как ломается.
@MainActor
private func docMenuState() -> MenuState {
    let state = MenuState()
    state.accessibilityOK = true
    state.inputMonitoringOK = true
    state.microphoneOK = true
    state.layouts = [
        .init(id: "ru", name: "Русская", isCurrent: true),
        .init(id: "abc", name: "ABC", isCurrent: false),
    ]
    state.currentLayoutID = "ru"
    state.currentLayoutName = "Русская"
    state.mode = .fixing
    state.todayAutoswitches = 128
    state.todayUndos = 4
    state.dictationState = .ready
    return state
}

/// Окно под кадр: прозрачное, без заголовка, по размеру содержимого.
@MainActor
private func makeDocWindow(width: CGFloat, height: CGFloat?, view: AnyView) -> NSWindow {
    let host = NSHostingView(rootView: AnyView(
        view.background(IrizGlassBackdrop()).frame(width: width)
    ))
    let fitting = host.fittingSize
    let size = CGSize(width: width, height: height ?? max(120, fitting.height))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.borderless, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    host.frame = CGRect(origin: .zero, size: size)
    window.contentView = host
    return window
}
