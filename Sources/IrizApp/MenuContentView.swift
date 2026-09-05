import AppKit
import SwiftUI
import IrizDictate
import IrizPrompt
import IrizSettings

/// Знак в строке меню — единственный носитель состояния (VISUAL_SPEC §2–4):
/// каретка + буква текущей раскладки, авария — «!» в слоте каретки.
/// Холст фиксированный 18×18 pt, поэтому соседи в строке меню не дёргаются.
struct MenuBarLabelView: View {
    @ObservedObject var state: MenuState

    var body: some View {
        Image(nsImage: IrizMark.statusImage(state: state.mark))
            .accessibilityLabel(Text(state.accessibilityLabel))
    }
}

/// Панель строки меню (MenuBarExtra, стиль `.window`).
///
/// ПОЧЕМУ ПАНЕЛЬ, А НЕ NSMenu. В стиле `.menu` SwiftUI строит настоящий NSMenu,
/// где `.font`, `.foregroundStyle` и `.padding` — пустышки, а из вьюх выживает
/// белый список. Иерархию там не построить в принципе: 10.08.2026 владелец
/// посмотрел на результат и забраковал вид. Спека §6 запрещала этот переход
/// «ради десяти пунктов»; пересмотр записан там же — вкус владельца старше замера.
///
/// Порядок продиктован тем, за чем сюда приходят: сначала состояние (крупно),
/// потом управление, потом клавиши — каждая рядом со своим действием, а не
/// справкой в конце.
@MainActor
struct MenuContentView: View {
    @ObservedObject var state: MenuState

    /// Куда уйдёт расшифровка у ВЫБРАННОГО сейчас агента. Правду знает адаптер;
    /// меню её только читает. Неизвестный агент честно говорит, что решает
    /// программа, а не молчит и не выдумывает адрес.
    private var promptDestinationTitle: String {
        let id = DictationSettings.shared.promptAgentID
        guard let adapter = PromptAgentCatalog.adapter(id: id) else {
            return PromptAgentDestination.unknown.title
        }
        return adapter.destination.title
    }
    let appDelegate: AppDelegate

    /// Куда ведёт стрелка вниз. Порядок совпадает с порядком на экране —
    /// иначе клавиатурная навигация читается как случайная.
    private enum FocusTarget: Hashable {
        case permissions, mode, layout, dictation, history, welcome, settings, quit
    }

    @State private var chrome = MenuPanelChrome()
    @State private var keys = MenuKeyHints(dictation: "", conversion: nil, prompt: nil, history: "")
    @FocusState private var focus: FocusTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let alarm = state.permissionAlarm {
                alarmRow(alarm)
                separator
            }

            hero
            separator

            caption("Режим")
            modePicker
            if let conversion = keys.conversion {
                legendRow("Исправить слово вручную", key: conversion)
            }
            separator

            caption("Раскладка")
            layoutPicker
            separator

            dictationBlock
            separator

            // Знакомство открывается ЗАНОВО. У соседей по классу к нему нет
            // пути назад, и это живая жалоба их пользователей: человек хочет
            // перечитать, что там было написано про разрешения, и не может.
            actionRow("Знакомство…", key: "", target: .welcome) {
                chrome.close()
                appDelegate.showWelcome()
            }

            actionRow("Настройки…", key: "⌘,", target: .settings) {
                chrome.close()
                appDelegate.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            actionRow("Выйти", key: "⌘Q", target: .quit) {
                appDelegate.quitApp()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .frame(width: 300, alignment: .leading)
        .background(MenuPanelAnchor(chrome: chrome))
        .onAppear { panelDidAppear() }
        .onDisappear { chrome.didDisappear() }
    }

    // MARK: - Блоки

    /// Состояние — первым и самым крупным. Два веса в одной строке: чем занято
    /// приложение (полужирный) и с какой раскладкой (обычный, приглушённый).
    private var hero: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                // Точка состояния: единственное цветное пятно в меню. Цвет тот
                // же, что у волны на плашке, - одно состояние обязано
                // называться одинаково на всех поверхностях.
                Circle()
                    .fill(Color(nsColor: state.stateColor))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(state.heroTitle).font(.system(size: 17, weight: .semibold))
                    + Text(state.heroDetail).font(.system(size: 17)).foregroundStyle(.secondary)
            }

            Text(state.statsLine)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 3)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.heroTitle)\(state.heroDetail). \(state.statsLine)")
    }

    private var modePicker: some View {
        Picker("Режим", selection: Binding(
            get: { state.mode },
            set: { appDelegate.setMode($0) }
        )) {
            ForEach(AppMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .focused($focus, equals: .mode)
        .accessibilityLabel("Режим работы")
        .padding(.horizontal, 6)
    }

    /// Сегменты помещаются, пока раскладок мало и имена коротки; иначе
    /// сегментированный переключатель режет имена, и «Русская — ПК» становится
    /// «Русск…». Тогда честнее выпадающий список.
    private var layoutPicker: some View {
        let picker = Picker("Раскладка", selection: Binding(
            get: { state.currentLayoutID },
            set: { appDelegate.selectLayout(id: $0) }
        )) {
            ForEach(state.layouts) { entry in
                Text(entry.name).tag(entry.id)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .focused($focus, equals: .layout)
        .accessibilityLabel("Раскладка клавиатуры")
        .padding(.horizontal, 6)

        let fitsSegments = state.layouts.count <= 3
            && state.layouts.reduce(0) { $0 + $1.name.count } <= 26

        return Group {
            if fitsSegments {
                picker.pickerStyle(.segmented)
            } else {
                picker.pickerStyle(.menu)
            }
        }
    }

    /// Вторая функция приложения. Справа либо клавиша (сработает), либо причина,
    /// по которой не сработает, — и тогда строка кликается и ведёт к починке.
    @ViewBuilder
    private var dictationBlock: some View {
        switch state.dictationHint {
        case .key:
            legendRow("Диктовка", key: keys.dictation, prominent: true)
        case .note(let note):
            legendRow("Диктовка", key: note, prominent: true)
        case .fault(let reason):
            actionRow("Диктовка", key: reason, target: .dictation) {
                chrome.close()
                appDelegate.recheckPermissions()
            }
        }

        // Промпт-режим не равен двум локальным функциям: он выключен по умолчанию,
        // и это единственная дорожка, по которой сказанное уходит с машины.
        // Поэтому — подпунктом, тише, и с прямо названным адресатом.
        if let prompt = keys.prompt {
            HStack(spacing: 8) {
                Text("Речь → промпт")
                Spacer(minLength: 8)
                Text(prompt).foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .padding(.top, 1)

            // Адресат берётся у ВЫБРАННОГО агента, а не печатается константой.
            // Здесь стояло «уходит в OpenAI» намертво: агентов пять, и строка
            // врала для четырёх, включая локальный Ollama, у которого ничего
            // никуда не уходит вовсе. Настройки рядом всё это время показывали
            // правду - врало только меню, то есть самое видное место.
            //
            // Про чужие данные приложение не имеет права ошибаться даже в
            // мелкой серой строке: это ровно то, ради чего продукт локальный.
            Text(promptDestinationTitle)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.leading, 18)
                .accessibilityLabel("Промпт-режим включён, \(promptDestinationTitle)")
        }

        // Окно истории — кликом, а не только по памяти о клавише. Пока строки
        // здесь не было, целая функция оставалась ненаходимой: хоткей знал
        // только тот, кто его сам себе настроил.
        actionRow("История надиктовок", key: keys.history, target: .history) {
            chrome.close()
            appDelegate.showDictationHistory()
        }
    }

    // MARK: - Кирпичи

    private var separator: some View {
        Divider()
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
    }

    /// Заголовок блока. Прежде он был `.tertiary` и на светлой теме почти
    /// не читался - блок выглядел началом ниоткуда. Вес и цвет подняты до
    /// `.secondary`, регистр разрежен: заголовок обязан отделять, а не
    /// прятаться.
    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.bottom, 5)
            .accessibilityHidden(true)
    }

    /// Клавиша стоит рядом со своим действием, а не в справке под меню.
    private func legendRow(_ title: String, key: String, prominent: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: prominent ? 13 : 11))
                .foregroundStyle(prominent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Spacer(minLength: 8)
            Text(key)
                .font(.system(size: prominent ? 13 : 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(key)")
    }

    private func alarmRow(_ title: String) -> some View {
        actionRow(title, key: nil, target: .permissions, alarm: true) {
            chrome.close()
            appDelegate.recheckPermissions()
        }
    }

    /// Строка-действие. Подсветку наведения и фокуса NSMenu рисовал сам —
    /// в панели её рисуем мы, иначе пункт не отличить от подписи.
    private func actionRow(
        _ title: String,
        key: String?,
        target: FocusTarget,
        alarm: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        MenuActionRow(title: title, key: key, alarm: alarm, action: action)
            .focused($focus, equals: target)
            .accessibilityLabel(key.map { "\(title), \($0)" } ?? title)
    }

    // MARK: - Клавиатура и жизненный цикл панели

    private func panelDidAppear() {
        keys = MenuKeys.current()
        focus = nil
        chrome.onKey = handle(key:)
        chrome.didAppear()
        // Счётчики и раскладка обновляются по таймеру раз в 2 с; открытие меню —
        // ровно тот момент, когда на них смотрят. Не в этом проходе отрисовки:
        // @Published нельзя менять посреди обновления вьюхи.
        DispatchQueue.main.async { appDelegate.refreshStatus() }
    }

    private func handle(key: MenuPanelKey) -> Bool {
        switch key {
        case .escape:
            chrome.close()
            return true
        case .down:
            moveFocus(by: 1)
            return true
        case .up:
            moveFocus(by: -1)
            return true
        case .activate:
            return activateFocused()
        }
    }

    /// Порядок обхода строится из того, что реально нарисовано: скрытая строка
    /// разрешений не должна ловить фокус.
    private var focusOrder: [FocusTarget] {
        var order: [FocusTarget] = []
        if state.permissionAlarm != nil { order.append(.permissions) }
        order.append(.mode)
        order.append(.layout)
        if case .fault = state.dictationHint { order.append(.dictation) }
        order += [.settings, .quit]
        return order
    }

    private func moveFocus(by step: Int) {
        let order = focusOrder
        guard !order.isEmpty else { return }
        guard let current = focus, let index = order.firstIndex(of: current) else {
            focus = step > 0 ? order.first : order.last
            return
        }
        let next = (index + step + order.count) % order.count
        focus = order[next]
    }

    /// Return/Space на пунктах-кнопках: сегментированные переключатели свои
    /// стрелки ← → обрабатывают сами, им активация не нужна.
    private func activateFocused() -> Bool {
        switch focus {
        case .permissions, .dictation:
            chrome.close()
            appDelegate.recheckPermissions()
            return true
        case .history:
            chrome.close()
            appDelegate.showDictationHistory()
            return true
        case .welcome:
            chrome.close()
            appDelegate.showWelcome()
            return true
        case .settings:
            chrome.close()
            appDelegate.openSettings()
            return true
        case .quit:
            appDelegate.quitApp()
            return true
        case .mode, .layout, nil:
            return false
        }
    }
}

/// Отдельный тип, потому что подсветка наведения — состояние строки, а не панели.
private struct MenuActionRow: View {
    let title: String
    let key: String?
    let alarm: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if alarm {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 13))
                    // Аварийная строка - единственная, которой разрешено занять
                    // две строки. Её работа в том, чтобы быть ПРОЧИТАННОЙ, а
                    // обрезанный хвост «отвалил…» не сообщает ничего. Поймано
                    // снимком поверхностей, а не глазами на живой поломке.
                    .lineLimit(alarm ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: alarm)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let key {
                    Text(key)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(highlight)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .onHover { hovering = $0 }
    }

    private var highlight: Color {
        if focused { return Color.primary.opacity(0.16) }
        return hovering ? Color.primary.opacity(0.09) : Color.clear
    }
}
