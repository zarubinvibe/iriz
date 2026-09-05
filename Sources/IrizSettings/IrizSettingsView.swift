import IrizCore
import AppKit
import SwiftUI
import IrizDictate
import IrizInput
import IrizPrompt
import UniformTypeIdentifiers

/// Ширина кнопки сочетания. Одна на все строки: прежде таблетка тянулась по
/// длине текста, и правая кромка формы шла зубцами.
private let HOTKEY_BUTTON_WIDTH: CGFloat = 150
/// Ширина колонки с корзиной в словаре замен - под неё резервируется место
/// в строке подписей, иначе шапка съезжает относительно полей.
private let CORRECTION_TRASH_WIDTH: CGFloat = 22

/// Стеклянные плиты секций вместо системных непрозрачных.
///
/// Отдельным модификатором, а не строкой в теле: правило одно на все секции, и
/// повторить его девять раз значит однажды забыть в десятой.
/// Одна плита стекла. Тот же материал, что у секций формы: два разных стекла
/// в одном окне разъезжаются по виду, а глубина стекла в этом окне ровно одна.
struct GlassPlate: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
        } else {
            content.background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}

struct GlassSectionPlates: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // `.interactive()` - живое стекло: оно откликается на указатель
            // движением самой линзы, а не подсветкой поверх. Анимацию ведёт
            // система по положению курсора, а не наш таймер.
            //
            // `.regular`, а не `.clear`. Прозрачное стекло поверх прозрачного
            // окна пропускало чужой текст насквозь: настройки открывают ПОВЕРХ
            // работы, и на кадре 05.09.2026 сквозь плиту читался чужой чат, а
            // своё - нет. Матовость, на которую владелец жаловался раньше,
            // приходила от ДВУХ слоёв стекла по глубине; здесь слой один, под
            // ним вуаль, и прозрачность видна по краям и в движении линзы.
            content.listRowBackground(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
            )
        } else {
            // На младших системах стекла нет. Полупрозрачный материал - честное
            // приближение; подделывать стекло заливкой значит соврать про то,
            // чего система не умеет.
            content.listRowBackground(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}

@MainActor
public struct IrizSettingsView: View {
    @StateObject private var model: SettingsModel
    @State private var recorder: HotkeyRecorderController?
    @State private var showResetConfirmation = false
    @State private var statusMessage: String?
    @State private var transferMessage: String?
    @State private var transferFailed = false
    @State private var appProfileMessage: String?
    @State private var page: SettingsPage = .keys
    @State private var diskEntries: [DiskUsageEntry] = []
    @State private var diskCounting = false

    public init(preview: Bool = false) {
        _model = StateObject(wrappedValue: SettingsModel(preview: preview))
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { item in
                // Значков в боковике нет намеренно. Готовые системные глифы -
                // чужой набор, а свой рисуется отдельной работой; строка без
                // значка честнее строки с заимствованным.
                Text(item.title).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                pageBody
                footerBar
            }
            // Вуаль кладётся ИМЕННО на правую колонку. Фон под самим
            // NavigationSplitView до неё не доходит: колонки рисуют себя сами,
            // и правая оставалась насквозь прозрачной - сквозь пустое место
            // под формой читалось чужое окно.
            .background(settingsGlassBackdrop)
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(settingsGlassBackdrop)
        .navigationTitle("Настройки \(IRIZ_NAME)")
        .alert("Сбросить настройки?", isPresented: $showResetConfirmation) {
            Button("Сбросить", role: .destructive) {
                statusMessage = model.resetToFactoryDefaults() ? "Заводские настройки восстановлены." : nil
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все сочетания, параметры, замены и заготовки вернутся к заводским. Отменить это действие нельзя - выгрузите словарь в файл, если он вам дорог.")
        }
    }

    /// Содержимое одной страницы. Секции остались теми же: резалась портянка,
    /// а не переписывались настройки.
    @ViewBuilder
    private var pageBody: some View {
        Form {
            switch page {
            case .keys: hotkeysSection
            case .layout: layoutSection
            case .dictation: behaviorSection
            case .plate: appearanceSection
            case .dictionary: correctionsSection
            case .snippets: snippetsSection
            case .prompt:
                promptModeSection
                promptGuidanceSection
                appProfilesSection
            case .transfer: transferSection
            case .disk: diskSection
            }
        }
        .formStyle(.grouped)
        // Плиты секций - стекло. Владелец: «всё должно быть прозрачным Liquid
        // Glass, не однотонное, а прозрачное во всех элементах дизайна».
        // Системная плита `.grouped` рисуется непрозрачной, и её приходится
        // снимать явно: `.scrollContentBackground(.hidden)` убирает только фон
        // прокрутки, но не подложки под каждой секцией.
        .modifier(GlassSectionPlates())
        // Своя подложка формы убирается: под ней стекло, и серая плита формы
        // закрыла бы ровно то, ради чего стекло и заводилось.
        .scrollContentBackground(.hidden)
    }

    /// Строка внизу окна: что не так и две кнопки. Живёт на КАЖДОЙ странице -
    /// кнопка сохранения, спрятанная на одной из девяти, находится случайно.
    private var footerBar: some View {
        HStack(spacing: 12) {
            if let message = model.validationMessage,
               !message.contains("Конфликт"), !message.contains("macOS") {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Ошибка настроек: \(message)")
            } else if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(statusMessage)
            }

            Spacer()

            Button("Сбросить к заводским", role: .destructive) {
                showResetConfirmation = true
            }
            .accessibilityLabel("Сбросить все настройки к заводским")

            Button("Сохранить") {
                statusMessage = model.save() ? "Настройки сохранены." : nil
            }
            // Стекло и здесь: сплошная акцентная заливка была единственным
            // непрозрачным пятном в окне, а владелец просил прозрачное во
            // ВСЕХ элементах. Заметность даёт `prominent`, а не заливка.
            .modifier(GlassProminentButton())
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSave)
            .accessibilityLabel("Сохранить настройки")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Своя плита под строкой: без неё кнопки висят прямо над тем, что за
        // окном, и читаются как чужие.
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .modifier(GlassPlate())
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    /// Кнопка на стекле там, где стекло есть.
    ///
    /// Отдельным модификатором, а не `.buttonStyle(.glass)` по месту вызова:
    /// стиль доступен только с macOS 26, а порог сборки - 14, и проверка
    /// доступности в двадцати местах превратилась бы в двадцать шансов
    /// разъехаться.
    /// Заметная кнопка на стекле. `.glassProminent` - тот же материал, но
    /// выделенный: прозрачность остаётся, а главное действие всё равно видно.
    struct GlassProminentButton: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.borderedProminent)
            }
        }
    }

    struct GlassButton: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.buttonStyle(.glass)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }

    /// Подложка окна: Liquid Glass во всю площадь.
    ///
    /// На macOS младше 26 остаётся системный фон окна - тот же приём, что уже
    /// применён для плашки записи: стекло берётся настоящее там, где оно есть,
    /// и не имитируется там, где его нет.
    @ViewBuilder
    private var settingsGlassBackdrop: some View {
        // Вуаль, а не второе стекло. История места такая.
        //
        // Сначала здесь лежал сплошной слой `.regular` во всё окно, и из-за
        // него всё остальное выходило матовым: стекло на стекле складывается.
        // Владелец сказал прямо: «мне нужно прозрачное». Слой убрали совсем, и
        // окно стало по-настоящему прозрачным.
        //
        // Но прозрачное насквозь окно читается только на спокойных обоях. На
        // чужом окне с текстом - а настройки открывают поверх работы - сквозь
        // плиты просвечивал чужой текст, и своё читать было нельзя. Снято
        // кадром 05.09.2026.
        //
        // Вуаль решает это, не возвращая матовость: она не стекло, слоёв
        // стекла по глубине по-прежнему один - плиты. Прозрачность остаётся,
        // но фон за ней приглушён, и буквы своего окна выигрывают у чужих.
        Color(nsColor: .windowBackgroundColor)
            .opacity(0.82)
            .ignoresSafeArea()
    }

    // MARK: - Кирпичи вида

    /// Заголовок секции: символ SF плюс имя. У Apple в настройках символ несёт
    /// секцию - он и есть то, за что глаз цепляется, пробегая длинную форму.
    /// Без него десять секций читались одинаковым серым списком.
    private func sectionHeader(_ spec: SettingsSectionSpec) -> some View {
        Label {
            Text(spec.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        } icon: {
            // Акцент только на СИМВОЛЕ: заливки нет, текст остаётся системным.
            // Цвет тут усиливает смысл, уже сказанный символом и именем, и
            // единственным носителем смысла не является.
            Image(systemName: spec.symbol)
                .foregroundStyle(Color.familyAccent(spec.accent))
        }
        .accessibilityLabel(spec.title)
    }

    /// Длинное пояснение прячется за раскрывашку.
    ///
    /// Текст владельца НЕ выброшен и не сокращён - он остаётся дословно. Но
    /// семь серых абзацев по три-пять строк каждый занимали в окне больше
    /// места, чем сами настройки, и форма читалась документом, а не панелью
    /// управления. Пояснение обязано быть доступно и не обязано быть открыто.
    @ViewBuilder
    private func settingsNote<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        DisclosureGroup {
            content()
        } label: {
            Text("Подробнее")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Подробное пояснение к секции")
    }

    /// Сочетание ОДНОЙ нотацией - глифами, как их печатает сама macOS.
    /// `HotkeyChoice.name` говорит по-английски («Option + Right Command»),
    /// и в русском окне это была третья нотация подряд. `MenuKeys` уже собрал
    /// русскую: он же питает меню строки меню, и две поверхности обязаны
    /// называть одну клавишу одинаково.
    private func hotkeyLabel(_ action: HotkeyAction) -> String {
        guard let binding = model.hotkeys[action] else { return "Записать" }
        return MenuKeys.russianKeyName(binding.choice)
    }

    private var promptModeSection: some View {
        Section {
            Toggle("Включить дополнительный промпт-режим", isOn: $model.promptModeEnabled)
                .toggleStyle(.switch)
                .accessibilityLabel("Включить промпт-режим")

            Picker("Агент", selection: $model.promptAgentID) {
                ForEach(PromptAgentCatalog.identifiers, id: \.self) { id in
                    Text(agentTitle(id)).tag(id)
                }
            }
            .accessibilityLabel("Агент, который собирает промпт")

            // Цена выбора стоит рядом с выбором и меняется вместе с ним.
            Label(model.agentDestinationTitle,
                  systemImage: model.agentKeepsDataLocal ? "lock.fill" : "arrow.up.right.circle.fill")
                .foregroundStyle(model.agentKeepsDataLocal ? Color.green : Color.orange)
                .accessibilityLabel("Куда уходят данные: \(model.agentDestinationTitle)")

            if let note = model.agentAdapter.configurationNote {
                Label(note, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Важно про этого агента: \(note)")
            }

            LabeledContent("Путь к CLI") {
                TextField(model.agentAdapter.executableName.isEmpty ? "Полный путь" : "Автопоиск",
                          text: agentPathBinding)
                    .labelsHidden()
                    .frame(minWidth: 280)
                    .accessibilityLabel("Путь к исполняемому файлу агента")
            }

            if let path = model.detectedAgentPath {
                Label("Найден: \(path)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Агент найден. \(path)")
            } else {
                Label("Не найден", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(model.promptModeEnabled ? Color.red : Color.secondary)
                    .accessibilityLabel("Агент не найден")
            }

            if model.agentAdapter.requiresModel {
                LabeledContent("Модель") {
                    TextField("например, qwen2.5-coder:7b", text: $model.agentModel)
                        .labelsHidden()
                        .frame(minWidth: 280)
                        .accessibilityLabel("Модель локального агента")
                }
            }

            if model.promptAgentID == PromptAgentCatalog.customID {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Аргументы — по одному в строке")
                    TextEditor(text: $model.agentCustomArguments)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 72)
                        .accessibilityLabel("Аргументы своего CLI, по одному в строке")
                    Text("Подстановки: {prompt} — текст промпта отдельным аргументом. Без {prompt} промпт уходит в стандартный ввод. Командная строка не собирается из строк, поэтому кавычки не нужны.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Подстановка {prompt} передаёт текст отдельным аргументом. Без неё промпт уходит в стандартный ввод. Кавычки не нужны")
                }
            }

            Picker("Распознаватель", selection: $model.speechEngine) {
                ForEach(SpeechModelProfile.allCases, id: \.self) { profile in
                    Text(profile.shortName).tag(profile)
                }
            }
            .accessibilityLabel("Какой движок распознавания речи использовать")

            settingsNote {
                Text("Parakeet быстрее в 11-15 раз, но транслитерирует английские термины внутри русской фразы: git rebase слышится как «гид репейс». Whisper large-v3 берет их латиницей (19 процентов ошибок на смешанной речи против 44), зато надиктовка в полминуты ждет расшифровки около 16 секунд. Оба считают на этом Маке, наружу не уходит ничего.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Picker("Исполнитель промпта", selection: $model.promptRecipient) {
                ForEach(PromptRecipientProfile.allCases, id: \.self) { profile in
                    Text(recipientTitle(profile)).tag(profile)
                }
            }
            .accessibilityLabel("Исполнитель готового промпта по умолчанию")

            settingsNote {
                Text("Этот режим необязателен. Промпт собирает выбранный агент, а профиль готовит текст для того, кто будет промпт исполнять. Пустое поле пути включает автопоиск. Обычная диктовка работает локально всегда; расшифровку наружу отдаёт только промпт-режим и только выбранному агенту. Ollama — единственный вариант, который не отправляет ничего: он считает на этом Маке. Готовый промпт вставляется без отправки, а качество проверяется здесь же — утверждение без дословной опоры на надиктовку отклоняется независимо от того, какой агент его сочинил.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Промпт-режим необязателен. Промпт собирает выбранный агент, профиль готовит текст для исполнителя. Пустое поле пути включает автопоиск. Обычная диктовка всегда локальна. Расшифровку отдаёт только промпт-режим и только выбранному агенту. Ollama считает на этом Маке и не отправляет ничего. Готовый промпт вставляется без отправки, а утверждение без дословной опоры на надиктовку отклоняется независимо от агента")
            }
        } header: {
            sectionHeader(.promptMode)
        }
    }

    /// Профиль под приложение, в котором идёт диктовка. Смотрим ТОЛЬКО на то,
    /// какое приложение спереди, — ни окна, ни поля, ни текста чужой программы.
    /// Свои инструкции и примеры промпт-режима.
    ///
    /// Секция появляется только при ВКЛЮЧЁННОМ промпт-режиме: настройка
    /// выключенной функции - это обещание без исполнения, а на нём проект
    /// горел четырежды.
    ///
    /// Обычная диктовка этого не видит вовсе и остаётся дословной: подсказка
    /// живёт только на дорожке сборки промпта.
    @ViewBuilder
    private var promptGuidanceSection: some View {
        if model.promptModeEnabled {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Чего вы хотите от формы промпта")
                    TextEditor(text: $model.promptGuidanceInstructions)
                        .font(.system(.body))
                        .frame(minHeight: 72)
                        .accessibilityLabel("Свои инструкции для промпт-режима")
                    Text("До \(PROMPT_GUIDANCE_INSTRUCTIONS_MAX) символов. Это предпочтение по ФОРМЕ, "
                         + "а не право выдумывать факты: запреты контракта сильнее.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(model.promptGuidanceExamples.indices), id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Пример \(index + 1)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button(role: .destructive) {
                                model.removePromptExample(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Удалить пример \(index + 1)")
                        }
                        TextField("Как сказано вслух", text: promptExampleSpoken(at: index))
                            .labelsHidden()
                            .accessibilityLabel("Пример \(index + 1): как сказано вслух")
                        TextField("Какой промпт нужен", text: promptExampleWanted(at: index))
                            .labelsHidden()
                            .accessibilityLabel("Пример \(index + 1): какой промпт нужен")
                    }
                }

                if model.promptGuidanceExamples.count < PROMPT_GUIDANCE_EXAMPLES_MAX {
                    Button("Добавить пример", systemImage: "plus") {
                        model.addPromptExample()
                    }
                    .accessibilityLabel("Добавить пример для промпт-режима")
                } else {
                    Text("Примеров хватит: больше \(PROMPT_GUIDANCE_EXAMPLES_MAX) уже не учат форме, а диктуют содержание.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                sectionHeader(.promptGuidance)
            }
        }
    }

    private func promptExampleSpoken(at index: Int) -> Binding<String> {
        Binding(
            get: { model.promptGuidanceExamples.indices.contains(index)
                ? model.promptGuidanceExamples[index].spoken : "" },
            set: { model.updatePromptExample(at: index, spoken: $0) }
        )
    }

    private func promptExampleWanted(at index: Int) -> Binding<String> {
        Binding(
            get: { model.promptGuidanceExamples.indices.contains(index)
                ? model.promptGuidanceExamples[index].wanted : "" },
            set: { model.updatePromptExample(at: index, wanted: $0) }
        )
    }

    private var appProfilesSection: some View {
        Section {
            if model.appProfiles.isEmpty {
                Text("Список пуст — промпт для любого приложения собирается по профилю выше.")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Список приложений пуст, работает профиль по умолчанию")
            }

            ForEach(Array(model.appProfiles.indices), id: \.self) { index in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(applicationTitle(model.appProfiles[index].bundleID))
                        Text(model.appProfiles[index].bundleID)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Picker("", selection: appProfileBinding(at: index)) {
                        ForEach(PromptRecipientProfile.allCases, id: \.self) { profile in
                            Text(recipientTitle(profile)).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .accessibilityLabel("Профиль для приложения \(applicationTitle(model.appProfiles[index].bundleID))")
                    Button(role: .destructive) {
                        appProfileMessage = nil
                        model.removeAppProfile(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Убрать приложение \(applicationTitle(model.appProfiles[index].bundleID)) из списка")
                }
            }

            Button("Добавить приложение…", systemImage: "plus") {
                chooseApplication()
            }
            .accessibilityLabel("Выбрать приложение и назначить ему профиль")

            if let appProfileMessage {
                Label(appProfileMessage, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(appProfileMessage)
            }

            settingsNote {
                Text("Диктуете в редактор кода — промпт собирается для Codex, диктуете в почту — универсальный. \(IRIZ_NAME) смотрит только на то, какое приложение сейчас спереди: ни окно, ни поле, ни текст чужой программы не читаются. Приложение спрашивается один раз, в момент нажатия, и сразу забывается — на диск и в журнал уходит выбранный профиль, а не имя программы. Приложений, которых нет в списке, это не касается: им достаётся профиль по умолчанию.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Профиль выбирается по приложению, которое спереди в момент нажатия. Окно, поле и текст чужой программы не читаются. Приложение спрашивается один раз и сразу забывается: на диск и в журнал уходит профиль, а не имя программы. Приложениям вне списка достаётся профиль по умолчанию")
            }
        } header: {
            sectionHeader(.appProfiles)
        }
    }

    /// Имя приложения показываем, но не храним: в настройках лежит только
    /// идентификатор, а человеческое имя каждый раз спрашивается у системы.
    /// Программу могли удалить — тогда честнее показать идентификатор, чем
    /// пустую строку.
    private func applicationTitle(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.isEmpty ? bundleID : name
    }

    private func recipientTitle(_ profile: PromptRecipientProfile) -> String {
        switch profile {
        case .codex: "Codex"
        case .generic: "Универсальный"
        }
    }

    private func appProfileBinding(at index: Int) -> Binding<PromptRecipientProfile> {
        Binding(
            get: {
                model.appProfiles.indices.contains(index)
                    ? model.appProfiles[index].profile
                    : model.promptRecipient
            },
            set: { model.updateAppProfile(at: index, profile: $0) }
        )
    }

    /// Идентификатор приложения владелец искать не должен: выбирается обычный
    /// файл программы, идентификатор читается из её же бандла.
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Выберите приложение"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            appProfileMessage = "У этой программы нет идентификатора — привязать профиль не к чему."
            return
        }

        switch model.addAppProfile(bundleID: bundleID, profile: model.promptRecipient) {
        case .added:
            appProfileMessage = "Добавлено. Выберите профиль и нажмите «Сохранить»."
        case .updated:
            appProfileMessage = "Эта программа уже была в списке — строка одна, профиль в ней и меняйте."
        case .invalidBundleID:
            appProfileMessage = "Идентификатор этой программы разобрать не удалось."
        case .listFull:
            appProfileMessage = "В списке уже \(PromptAppProfileMap.maximumEntries) программ — уберите лишние."
        }
    }

    private var agentPathBinding: Binding<String> {
        Binding(get: { model.agentPath }, set: { model.agentPath = $0 })
    }

    /// Цена выбора видна прямо в списке, а не только после выбора.
    private func agentTitle(_ id: String) -> String {
        guard let adapter = PromptAgentCatalog.adapter(id: id) else { return id }
        return "\(adapter.displayName) — \(adapter.destination.shortTitle)"
    }

    private var appearanceSection: some View {
        Section {
            // Размер выбирается КЛИКОМ ПО ПЛАШКЕ, а не из списка слов. Слова
            // владельца: «не маленькая, большая, средняя, а прям можно кликать».
            // Плашки настоящие: их рисуют те же классы, что рисуют живую.
            VStack(alignment: .leading, spacing: 6) {
                Text("Размер плашки")
                    .font(.callout)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(DictationHUDSizeChoice.allCases, id: \.self) { choice in
                        HUDPreviewChoice(value: choice,
                                         selection: $model.hudSize,
                                         title: choice.title,
                                         size: choice,
                                         palette: model.wavePalette)
                    }
                }
            }
            .accessibilityLabel("Размер плашки записи")

            VStack(alignment: .leading, spacing: 6) {
                Text("Как выглядит волна")
                    .font(.callout)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(DictationHUDWavePalette.allCases, id: \.self) { palette in
                        HUDPreviewChoice(value: palette,
                                         selection: $model.wavePalette,
                                         title: dictationHUDWavePaletteTitle(palette),
                                         size: model.hudSize,
                                         palette: palette)
                    }
                }
            }
            .accessibilityLabel("Как выглядит волна на плашке записи")

            settingsNote {
                Text("Переливы — три тона вокруг цвета режима. Спокойная — те же тона, но разлёт вдвое уже. Монохром — без переливов вовсе. Цвет режима палитра не меняет: обычная диктовка остаётся тёплой, промпт — холодным, иначе по плашке было бы не видно, что именно записывается.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Переливы: три тона вокруг цвета режима. Спокойная: те же тона, разлёт вдвое уже. Монохром: без переливов. Цвет режима палитра не меняет — диктовка остаётся тёплой, промпт холодным")
            }
        } header: {
            sectionHeader(.appearance)
        }
    }

    private var hotkeysSection: some View {
        Section {
            ForEach(HotkeyAction.allCases) { action in
                LabeledContent(action.title) {
                    Button(hotkeyLabel(action)) {
                        startRecording(for: action)
                    }
                    .modifier(GlassButton())
                    // Одна ширина на все кнопки: правая кромка была рваной,
                    // потому что таблетка тянулась по длине текста, а тексты
                    // разной длины. Кромка - это и есть то, что глаз читает
                    // как «сделано аккуратно».
                    .frame(width: HOTKEY_BUTTON_WIDTH)
                    .accessibilityLabel("\(action.title): \(hotkeyLabel(action)). Записать новое сочетание")
                }
            }

            if let message = model.validationMessage,
               message.contains("Конфликт") || message.contains("macOS") || message.contains("раскладка") {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Ошибка сочетаний: \(message)")
            }

            // Две сноски подряд были про одно и то же - когда сочетание
            // начинает работать. Осталась одна.
            Text("Сочетание применяется сразу после сохранения. Отмена переключения — то же сочетание конвертации ещё раз.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Сочетание применяется сразу после сохранения. Отмена переключения - то же сочетание конвертации ещё раз")
        } header: {
            sectionHeader(.hotkeys)
        }
    }

    private var layoutSection: some View {
        Section {
            // Выбор стоял ДВАЖДЫ: три радиокнопки в строку, а под ними те же три
            // пункта заголовком и описанием. Описание нужно, дубль выбора - нет,
            // поэтому объяснение переехало под сам выбор и говорит про ВЫБРАННЫЙ
            // режим. Три абзаца про три режима сразу читатель всё равно не
            // сравнивает: он выбирает один.
            Picker("Режим раскладки", selection: $model.layoutMode) {
                ForEach(LayoutMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityLabel("Режим раскладки")

            Text(model.layoutMode.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Что делает режим \(model.layoutMode.title): \(model.layoutMode.explanation)")
        } header: {
            sectionHeader(.layout)
        }
    }

    private var behaviorSection: some View {
        Section {
            LabeledContent("Задержка Enter") {
                HStack(spacing: 6) {
                    // labelsHidden обязателен: в Form(.grouped) заголовок TextField
                    // рисуется ВТОРЫМ ярлыком рядом с ярлыком LabeledContent и
                    // сминается в вертикальный столбик из букв на ширине 72 pt.
                    TextField("", text: $model.enterDelayText)
                        .labelsHidden()
                        .frame(width: 72)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Задержка Enter в миллисекундах")
                    Text("мс").foregroundStyle(.secondary)
                }
            }

            Picker("После вставки", selection: $model.pasteSuffix) {
                Text("Пробел").tag(PasteSuffix.appendSpace)
                Text("Ничего").tag(PasteSuffix.none)
                Text("Перевод строки").tag(PasteSuffix.appendNewline)
            }
            .accessibilityLabel("Суффикс после вставки")

            Toggle("Запускать при входе в систему", isOn: $model.launchAtLogin)
                .toggleStyle(.switch)
                .accessibilityLabel("Запускать \(IRIZ_NAME) при входе в систему")

            Toggle("Показывать окно, если текст никуда не вставился",
                   isOn: $model.rescueWindowEnabled)
                .toggleStyle(.switch)
                .accessibilityLabel("Показывать окно с текстом, когда вставка не удалась")

            settingsNote {
                Text("Вставка не дошла до поля — \(IRIZ_NAME) поднимает окно с готовым текстом: скопировать или вставить ещё раз, Esc — закрыть. Когда сработал запасной прямой ввод, окна не будет: там текст, скорее всего, уже в поле, и предлагать вставить его второй раз опаснее, чем промолчать.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Если вставка не дошла до поля, \(IRIZ_NAME) показывает окно с готовым текстом: скопировать или вставить ещё раз, Esc закрывает. При запасном прямом вводе окно не поднимается: текст скорее всего уже в поле")
            }
        } header: {
            sectionHeader(.behavior)
        }
    }

    private var correctionsSection: some View {
        Section {
            if model.corrections.isEmpty {
                Text("Замен пока нет.")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Словарь замен пуст")
            } else {
                // Подписи колонок ОДИН раз. Прежде каждая строка несла свои две:
                // на четырнадцати заменах это двадцать восемь повторов «Как
                // распозналось» и «На что менять», из-за которых сами слова
                // владельца терялись в служебном тексте.
                HStack(spacing: 8) {
                    Text("Как распозналось")
                    Spacer(minLength: 8)
                    Text("На что менять")
                    Spacer().frame(width: CORRECTION_TRASH_WIDTH)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            }

            ForEach(Array(model.corrections.indices), id: \.self) { index in
                HStack(spacing: 8) {
                    TextField("Как распозналось", text: correctionSource(at: index))
                        .labelsHidden()
                        .accessibilityLabel("Как распозналось, замена \(index + 1)")
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("На что менять", text: correctionReplacement(at: index))
                        .labelsHidden()
                        .accessibilityLabel("На что менять, замена \(index + 1)")
                    Button(role: .destructive) {
                        model.removeCorrection(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Удалить замену \(index + 1)")
                }
            }

            Button("Добавить замену", systemImage: "plus") {
                model.addCorrection()
            }
            .accessibilityLabel("Добавить пару в словарь замен")
        } header: {
            sectionHeader(.corrections)
        }
    }

    /// Редактор заготовок стоит рядом со словарём и намеренно на него не
    /// похож: у замены две короткие строки, у заготовки — фраза и блок текста.
    private var snippetsSection: some View {
        Section {
            if model.snippets.isEmpty {
                Text("Заготовок пока нет.")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Список заготовок пуст")
            }

            ForEach(Array(model.snippets.indices), id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Что произносится", text: snippetTrigger(at: index))
                            .accessibilityLabel("Фраза заготовки \(index + 1)")
                        Button(role: .destructive) {
                            model.removeSnippet(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Удалить заготовку \(index + 1)")
                    }
                    TextEditor(text: snippetBody(at: index))
                        .frame(minHeight: 72)
                        .accessibilityLabel("Текст заготовки \(index + 1)")
                }
                .padding(.vertical, 2)
            }

            Button("Добавить заготовку", systemImage: "plus") {
                model.addSnippet()
            }
            .accessibilityLabel("Добавить заготовку")

            settingsNote {
                Text("Произнесённая фраза заменяется сохранённым текстом — так вставляются шапки, реквизиты и стандартные формулировки. Совпадение точное и по границам слова: «иск» внутри «иска» не сработает, регистр значения не имеет. Заготовки и словарь замен подставляются одним проходом, поэтому текст заготовки словарь уже не переписывает. Сырая расшифровка на диске остаётся нетронутой, а промпт-режим заготовок не видит вовсе.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Произнесённая фраза заменяется сохранённым текстом: шапки, реквизиты, стандартные формулировки. Совпадение точное и по границам слова, регистр не важен. Заготовки и словарь подставляются одним проходом, текст заготовки словарь не переписывает. Сырая расшифровка на диске не меняется, промпт-режим заготовок не видит")
            }
        } header: {
            sectionHeader(.snippets)
        }
    }

    private var transferSection: some View {
        Section {
            HStack {
                Button("Экспортировать…", systemImage: "square.and.arrow.up") {
                    exportDictionary()
                }
                .accessibilityLabel("Экспортировать словарь и заготовки в файл")

                Button("Импортировать…", systemImage: "square.and.arrow.down") {
                    importDictionary()
                }
                .accessibilityLabel("Импортировать словарь и заготовки из файла")
            }

            if let transferMessage {
                Label(transferMessage, systemImage: transferFailed
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill")
                    .foregroundStyle(transferFailed ? Color.red : Color.secondary)
                    .accessibilityLabel(transferMessage)
            }

            settingsNote {
                Text("Файл — обычный JSON, его можно открыть и поправить руками. Это единственная копия словаря: всё остальное живёт в настройках системы и исчезает вместе с ними. При импорте совпавшие по фразе записи берутся из файла, а те, которых в файле нет, остаются на месте — импорт ничего не удаляет. Негодный файл отклоняется целиком, с номером испорченной записи: половина восстановленного словаря хуже честного отказа. Импортированное попадает в настройки после кнопки «Сохранить».")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Файл — обычный JSON, его можно поправить руками. Это единственная копия словаря. При импорте совпавшие по фразе записи берутся из файла, остальные остаются на месте, импорт ничего не удаляет. Негодный файл отклоняется целиком, с номером испорченной записи. Импортированное попадает в настройки после кнопки Сохранить")
            }
        } header: {
            sectionHeader(.transfer)
        }
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.title = "Экспорт словаря и заготовок"
        panel.nameFieldStringValue = DictionaryTransfer.suggestedFileName
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try model.exportedDictionaryData().write(to: url, options: .atomic)
            transferFailed = false
            transferMessage = "Выгружено в \(url.lastPathComponent)."
        } catch {
            transferFailed = true
            transferMessage = "Не удалось записать файл: \(error.localizedDescription)"
        }
    }

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.title = "Импорт словаря и заготовок"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let summary = try model.importDictionaryData(data)
            transferFailed = false
            transferMessage = summary + " Нажмите «Сохранить», чтобы записать."
        } catch let error as DictionaryTransferError {
            transferFailed = true
            transferMessage = error.message
        } catch {
            transferFailed = true
            transferMessage = "Файл не удалось прочитать: \(error.localizedDescription)"
        }
    }

    /// Страница «место на диске». Считается по требованию: обход тысяч папок
    /// с надиктовками стоит секунды, и делать его на каждом открытии окна
    /// настроек незачем.
    private var diskSection: some View {
        Section {
            if diskEntries.isEmpty {
                Text(diskCounting
                     ? "Считаю…"
                     : "Пока ничего не занято: ни модели, ни надиктовок на диске нет.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(diskEntries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            Text(entry.note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(diskUsageSizeText(entry.bytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Показать") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                        .modifier(GlassButton())
                    }
                }
                HStack {
                    Text("Всего")
                    Spacer()
                    Text(diskUsageSizeText(diskEntries.reduce(0) { $0 + $1.bytes }))
                        .monospacedDigit()
                }
                .font(.system(size: 13, weight: .semibold))
            }

            Text("Удалить отсюда нельзя намеренно: в этих каталогах лежат ваши надиктовки, "
                 + "а кнопка «очистить», нажатая не глядя, стоит дороже сэкономленного "
                 + "гигабайта. Чистка живёт там, где видно, что именно чистишь, - в окне истории.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Место на диске")
        }
        .task(id: page) {
            guard page == .disk, diskEntries.isEmpty, !diskCounting else { return }
            diskCounting = true
            let found = await Task.detached(priority: .utility) { diskUsageEntries() }.value
            diskEntries = found
            diskCounting = false
        }
    }

    private func startRecording(for action: HotkeyAction) {
        let controller = HotkeyRecorderController()
        recorder = controller
        controller.present(actionTitle: action.title) { choice in
            if let choice { model.setHotkey(choice, for: action) }
            recorder = nil
        }
    }

    private func correctionSource(at index: Int) -> Binding<String> {
        Binding(
            get: { model.corrections.indices.contains(index) ? model.corrections[index].source : "" },
            set: { model.updateCorrection(at: index, source: $0) }
        )
    }

    private func correctionReplacement(at index: Int) -> Binding<String> {
        Binding(
            get: { model.corrections.indices.contains(index) ? model.corrections[index].replacement : "" },
            set: { model.updateCorrection(at: index, replacement: $0) }
        )
    }

    private func snippetTrigger(at index: Int) -> Binding<String> {
        Binding(
            get: { model.snippets.indices.contains(index) ? model.snippets[index].trigger : "" },
            set: { model.updateSnippet(at: index, trigger: $0) }
        )
    }

    private func snippetBody(at index: Int) -> Binding<String> {
        Binding(
            get: { model.snippets.indices.contains(index) ? model.snippets[index].body : "" },
            set: { model.updateSnippet(at: index, body: $0) }
        )
    }
}

/// Страницы окна настроек.
///
/// Окно было одной формой из одиннадцати секций - владелец назвал её «огромной
/// портянкой», и это точное слово: найти в ней словарь замен можно было только
/// прокруткой мимо всего остального. Порядок страниц - от того, чем пользуются
/// каждый день, к тому, что трогают раз в жизни.
public enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case keys
    case layout
    case dictation
    case plate
    case dictionary
    case snippets
    case prompt
    case transfer
    case disk

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keys: return "Клавиши"
        case .layout: return "Раскладка"
        case .dictation: return "Диктовка"
        case .plate: return "Плашка"
        case .dictionary: return "Словарь замен"
        case .snippets: return "Заготовки"
        case .prompt: return "Промпт-режим"
        case .transfer: return "Перенос"
        case .disk: return "Место на диске"
        }
    }
}
