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

        // Страницы настроек, на которые ссылается витрина. Раньше их снимали
        // руками, и к 07.09.2026 они отстали на все правки владельца: на кадре
        // словаря замен не было ни кнопки добавления сверху, ни выровненных
        // столбцов, ни отметки о сохранении. Кадр, который никто не
        // пересобирает, устаревает первым.
        if language == .ru {
            for (page, name) in docSettingsPages() {
                let window = makeIrizSettingsWindow(preview: true, page: page)
                let url = directory.appendingPathComponent("page-\(name).png")
                try captureWindowLive(window, kind: .gradient, dark: false, to: url)
                window.close()
                written.append(url)
            }
        }

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

    // Плашка снимается ТЕМ ЖЕ прогоном. Раньше её кадры копировали руками, и
    // они отстали на день: витрина обновлялась одной командой, а четыре кадра
    // плашки - нет. Владелец 07.09.2026 показал два из них: на одном плашка
    // сломана, на другом её вовсе не видно.
    //
    // В витрину идут ТЁМНЫЕ формы. На светлой подложке стекло почти не читается
    // - остаётся контур и кнопки, и на странице знакомства это выглядело как
    // отсутствие плашки. Тёмная показывает то, чем плашка является.
    if #available(macOS 26.0, *) {
        written.append(contentsOf: try captureDocPlateShots(to: directory))
    }
    return written
}

/// Кадры плашки для витрины: снимаем весь набор, оставляем нужные четыре.
@available(macOS 26.0, *)
@MainActor
private func captureDocPlateShots(to directory: URL) throws -> [URL] {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("iriz-doc-plate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    _ = try captureDictationHUDPlateScenes(to: temp)

    var written: [URL] = []
    for name in ["plate-resting-dark", "plate-hover-dark",
                 "plate-listening-dark", "plate-open-text-dark"] {
        let from = temp.appendingPathComponent("\(name).png")
        let to = directory.appendingPathComponent("\(name).png")
        guard FileManager.default.fileExists(atPath: from.path) else {
            throw NSError(domain: "iriz.docshots", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "Кадр плашки \(name) не снялся."])
        }
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.copyItem(at: from, to: to)
        written.append(to)
    }
    return written
}

/// Страницы настроек для витрины. Только по-русски: витрина ссылается на них
/// из русского, английского и китайского текста одним и тем же файлом, и три
/// копии одной страницы весили бы втрое без нового знания.
@MainActor
private func docSettingsPages() -> [(SettingsPage, String)] {
    [(.dictation, "dictation"), (.dictionary, "dictionary"), (.files, "files"),
     (.history, "history"), (.meetings, "meetings")]
}

/// Поверхности, которые обязаны попасть в витрину на каждом языке.
@MainActor
private func docShots(appDelegate: AppDelegate) -> [DocShot] {
    [
        // Высота - потолок, а не размер: окно ужимается до содержимого после
        // раскладки. Раньше здесь стояло жёсткое число, и меню занимало треть
        // кадра, а две трети были пустой подложкой.
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
    // Мерить до раскладки нельзя: `fittingSize` тогда возвращает высоту без
    // выложенных шрифтов и низ кадра срезается. Раскладку заставляем пройти, а
    // заданную высоту трактуем как потолок - кадр по содержимому, не по числу.
    host.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height ?? 2000))
    host.layoutSubtreeIfNeeded()
    let fitting = host.fittingSize
    let vysota = min(height ?? .greatestFiniteMagnitude, max(120, fitting.height))
    let size = CGSize(width: width, height: vysota)
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
