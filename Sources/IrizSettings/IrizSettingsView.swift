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

/// Общий выбор страницы у окна и его содержимого. Переход не пересоздаёт
/// форму: несохранённые сочетания и очередь файлов остаются на месте.
@MainActor
public final class SettingsNavigation: ObservableObject {
    @Published public var page: SettingsPage

    public init(page: SettingsPage = .keys) {
        self.page = page
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
    @StateObject private var navigation: SettingsNavigation
    private var page: SettingsPage { navigation.page }
    @State private var languageChoice: IrizLanguage = irizLanguageChoice()
    @State private var appearanceChoice: IrizAppearanceChoice = irizAppearanceChoice()
    @StateObject private var files = SettingsFileTranscription()
    @State private var fileLanguage: DictationLanguage = .auto
    @State private var meetingQueue: [IrizDropItem] = []
    @State private var meetingBusy = false
    @State private var meetingStopping = false
    @State private var meetingResults: [MeetingArtifacts] = []
    @State private var meetingProgress: String?
    @State private var meetingReport: String?
    @State private var meetingFailed = false
    @State private var diskEntries: [DiskUsageEntry] = []
    @State private var diskCounting = false
    @StateObject private var historyModel: DictationHistoryModel
    private let isPreview: Bool
    private let openSpeechModelSetup: (() -> Void)?
    @Namespace private var sidebarGlass
    /// Система гасит свою анимацию, но не наш `withAnimation` - морф стекла
    /// приходится гейтить руками (правило M07 линтера).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(preview: Bool = false, page: SettingsPage = .keys,
                navigation: SettingsNavigation? = nil,
                openSpeechModelSetup: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: SettingsModel(preview: preview))
        _historyModel = StateObject(wrappedValue: DictationHistoryModel(preview: preview))
        isPreview = preview
        self.openSpeechModelSetup = openSpeechModelSetup
        _navigation = StateObject(wrappedValue: navigation ?? SettingsNavigation(page: page))
    }

    public var body: some View {
        glassScene
            .onAppear { model.refreshSpeechModelReadiness() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshSpeechModelReadiness()
            }
            .onReceive(NotificationCenter.default.publisher(for: speechModelDidInstallNotification)) { notification in
                guard !isPreview, let profile = notification.object as? SpeechModelProfile else { return }
                model.applyInstalledSpeechModel(profile)
            }
    }

    /// Общего `GlassEffectContainer` здесь НЕТ, и это измеренное решение.
    ///
    /// Линтер скилла требует контейнер на соседние стекла (правило G10), и по
    /// букве он прав: без общей области сэмплирования поверхности не видят
    /// друг друга. Но фон окна и плиты - не соседи, а слои: плита лежит НА
    /// фоне. Контейнер их объединил, и прибор показал цену сразу: пропускание
    /// боковика поднялось с 0.418 до 0.622 при фоне 0.678, то есть плита
    /// растворилась в фоне и разница между поверхностями пропала.
    ///
    /// Правило написано про соседние элементы одного слоя. Слои им не
    /// объединяют.
    @ViewBuilder
    private var glassScene: some View {
        sceneBody
    }

    private var sceneBody: some View {
        // Своя раскладка вместо NavigationSplitView, и это вынужденно.
        //
        // Колонка боковика у разделённого вида несёт СОБСТВЕННЫЙ непрозрачный
        // материал, и снять его нечем: он живёт в NSSplitViewItem ниже SwiftUI.
        // Прибор показал цену прямо: пропускание боковика 0.078 против 0.281 у
        // страницы в том же окне - колонка была глухой стеной внутри стекла.
        // Прошлая попытка гасить материал обходом дерева видов была и мёртвой,
        // и запрещённой: справочник Apple прямо велит не подкладывать свои фоны
        // под боковик разделённого вида. Значит разделённого вида здесь нет.
        //
        // Цена решения названа вслух: пропала системная кнопка сворачивания
        // боковика. Окно 980 pt, скрывать колонку не за чем.
        ZStack(alignment: .topLeading) {
            let inset = IrizGlassBackdrop.plateInset
            let leftGutter = IrizGlassBackdrop.sidebarWidth + inset * 2
            let bottomGutter = IrizGlassBackdrop.footerHeight + inset * 2

            // Плита содержимого. Владелец: «такая же плашка под текстом, то,
            // что в основном меню справа» - центральная часть живёт на своей
            // поверхности, как боковик и низ.
            // Плита по ВЫСОТЕ ТЕКСТА, а не во весь размер окна. Прокрутка
            // снята с самой формы и вынесена наружу: иначе форма растягивается
            // на всю доступную высоту, и под коротким списком остаётся
            // полплиты пустого стекла.
            ScrollView {
                pageBody
                    .scrollDisabled(true)
                    .fixedSize(horizontal: false, vertical: true)
                    // Страница не подменяется рывком: уходит прозрачностью и
                    // коротким сдвигом вниз. Сдвиг маленький (6 pt) - смысл в
                    // направлении, а не в поездке.
                    .id(page)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .animation(reduceMotion ? nil : Animation.irizEaseOut, value: page)
                    .background(IrizFloatingPlate())
            }
            .scrollContentBackground(.hidden)
            .padding(.leading, leftGutter)
            .padding(.trailing, inset)
            .padding(.top, inset)
            .padding(.bottom, bottomGutter)

            // Плавающий боковик.
            sidebar
                .frame(width: IrizGlassBackdrop.sidebarWidth)
                .background(IrizFloatingPlate())
                .padding(.leading, inset)
                .padding(.vertical, inset)

            // Плавающая нижняя полоса.
            VStack {
                Spacer()
                footerBar
                    .background(IrizFloatingPlate())
                    .padding(.leading, leftGutter)
                    .padding([.trailing, .bottom], inset)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(IrizGlassBackdrop())
        .navigationTitle("Настройки \(IRIZ_NAME)")
        .alert(L("settings.sbrositNastroyki", "Сбросить настройки?"), isPresented: $showResetConfirmation) {
            Button(L("settings.sbrosit", "Сбросить"), role: .destructive) {
                statusMessage = model.resetToFactoryDefaults() ? L("settings.zavodskieNastroykiVosstanovleny", "Заводские настройки восстановлены.") : nil
            }
            Button(L("settings.otmena", "Отмена"), role: .cancel) {}
        } message: {
            Text(L("settings.vseSochetaniyaParametryZameny", "Все сочетания, параметры, замены и заготовки вернутся к заводским. Отменить это действие нельзя - выгрузите словарь в файл, если он вам дорог."))
        }
    }

    /// Боковик со стеклянной капсулой выбора.
    ///
    /// Своя раскладка вместо `List`: системная подсветка - сплошная плашка, а
    /// нужна одна капсула стекла, которая ПЕРЕЕЗЖАЕТ с пункта на пункт. Так
    /// сделаны вкладки часов на iOS: стекло не гаснет и не зажигается заново,
    /// оно переносится, а по кромке идёт преломление.
    private var sidebar: some View {
        ScrollView {
            if #available(macOS 26.0, *) {
                // Контейнер обязателен: без него капсулам нечем переливаться
                // друг в друга, и каждая рисуется сама по себе.
                GlassEffectContainer(spacing: 6) { sidebarRows }
            } else {
                sidebarRows
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var sidebarRows: some View {
        VStack(spacing: 2) {
            ForEach(SettingsPage.allCases) { item in
                sidebarRow(item)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func sidebarRow(_ item: SettingsPage) -> some View {
        let selected = page == item
        Button {
            // Пружина, а не кривая: переезд стекла - движение вещи, и оно
            // должно доезжать с весом. Отскок маленький, иначе меню играет.
            // Пресет вместо магических чисел: `.snappy` и есть «доехать с весом,
            // без игры» (правило M02 линтера).
            withAnimation(reduceMotion ? nil : .irizMove) {
                navigation.page = item
            }
        } label: {
            Label {
                Text(item.title)
            } icon: {
                // Значки свои, из набора продукта: одна сетка, одна толщина
                // штриха, одно скругление. Разнобой видно раньше, чем сами
                // фигуры.
                IrizGlyphView(item.glyph, size: 16)
            }
            // Белый цвет подписи прибит был напрасно: на тонированном стекле
            // подложка просвечивает, и системный цвет остаётся читаемым.
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            // Стекло вешается НА строку, а не подкладывается фоном. Фоном оно
            // уходит в общий слой контейнера и закрывает собой текст: строка
            // исчезает, остаётся цветная капсула.
            .irizSelected(selected, in: sidebarGlass, group: "sidebar")
        }
        .buttonStyle(IrizPressStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Содержимое одной страницы. Секции остались теми же: резалась портянка,
    /// а не переписывались настройки.
    @ViewBuilder
    private var pageBody: some View {
        Form {
            switch page {
            case .history: historySection
            case .language: languageSection
            case .files: filesSection
            case .meetings: meetingsSection
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
        // Своя подложка формы убирается: под ней стекло, и серая плита формы
        // закрыла бы ровно то, ради чего стекло и заводилось.
        .scrollContentBackground(.hidden)
    }

    /// Строка внизу окна: что не так и две кнопки. Живёт на КАЖДОЙ странице -
    /// кнопка сохранения, спрятанная на одной из девяти, находится случайно.
    private var footerBar: some View {
        HStack(spacing: 12) {
            if let message = model.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel(Lf("settings.error.a11y", "Ошибка настроек: %@", message))
            } else if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(IRIZ_SUBTLE)
                    .accessibilityLabel(statusMessage)
            }

            Spacer()

            Button(L("settings.sbrositKZavodskim", "Сбросить к заводским"), role: .destructive) {
                showResetConfirmation = true
            }
            // Стекло и здесь: рядом со стеклянной «Сохранить» системная серая
            // таблетка читалась как чужая деталь из другого окна.
            .modifier(GlassButton())
            .accessibilityLabel(L("settings.sbrositVseNastroykiK", "Сбросить все настройки к заводским"))

            Button(L("settings.sohranit", "Сохранить")) {
                statusMessage = model.save() ? L("settings.nastroykiSohraneny", "Настройки сохранены.") : nil
            }
            // Стекло и здесь: сплошная акцентная заливка была единственным
            // непрозрачным пятном в окне, а владелец просил прозрачное во
            // ВСЕХ элементах. Заметность даёт `prominent`, а не заливка.
            .modifier(GlassProminentButton())
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSave)
            .accessibilityLabel(L("settings.sohranitNastroyki", "Сохранить настройки"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // Нижняя полоса - матовое стекло: под кнопками и текстом блик мешал бы
        // читать, а прозрачность при этом сохраняется.
        .frame(height: IrizGlassBackdrop.footerHeight)
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
                // `.glass` с тоном, а не `.glassProminent`. Prominent заливает
                // кнопку акцентом целиком, и в стеклянном окне она осталась
                // единственным глухим пятном - владелец назвал её «глухой
                // синей». Главной кнопку делает тон и вес подписи, а не заливка.
                // Тон тот же, что у капсулы выбора: смешанный с фоном акцент.
                // Чистый `Color.accentColor` даёт стеклу полную насыщенность, и
                // кнопка снова читается сплошной заливкой - владелец назвал
                // такую «глухой синей».
                // Тона нет вовсе. Замер кадром: и `.glassProminent`, и `.glass`
                // с тоном рисуют сплошную заливку - стекло под цветом не
                // читается ни при какой насыщенности. Владелец назвал такую
                // кнопку «глухой синей», а он просил прозрачное во всех
                // элементах.
                //
                // Главной кнопку теперь делает ВЕС подписи и то, что она ловит
                // Enter. Цветом главное больше не называется - в стеклянном
                // окне цвет и есть та самая глухая заплата.
                content
                    .buttonStyle(.glass)
                    .fontWeight(.semibold)
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
    // Указание Apple, от которого мы сознательно ушли:
    // «Reduce your use of custom backgrounds… Prefer to remove custom effects
    // and let the system determine the background appearance, especially for
    // split views, tab bars, and toolbars». Разделённый вид сам живёт в слое
    // Liquid Glass, и всё, что я подкладывал под него - вуаль, размытие,
    // сплошное стекло, - системе мешало. Три попытки прошли мимо именно так.

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
            Text(L("settings.podrobnee", "Подробнее"))
                .font(.footnote)
                .foregroundStyle(IRIZ_SUBTLE)
        }
        .accessibilityLabel(L("settings.podrobnoePoyasnenieKSekcii", "Подробное пояснение к секции"))
    }

    /// Сочетание ОДНОЙ нотацией - глифами, как их печатает сама macOS.
    /// `HotkeyChoice.name` говорит по-английски («Option + Right Command»),
    /// и в русском окне это была третья нотация подряд. `MenuKeys` уже собрал
    /// русскую: он же питает меню строки меню, и две поверхности обязаны
    /// называть одну клавишу одинаково.
    private func hotkeyLabel(_ action: HotkeyAction) -> String {
        guard let binding = model.hotkeys[action] else { return L("settings.zapisat", "Записать") }
        return MenuKeys.russianKeyName(binding.choice)
    }

    private var promptModeSection: some View {
        Section {
            Toggle(L("settings.vklyuchitDopolnitelnyyPromptRezh", "Включить дополнительный промпт-режим"), isOn: $model.promptModeEnabled)
                .toggleStyle(.switch)
                .accessibilityLabel(L("settings.vklyuchitPromptRezhim", "Включить промпт-режим"))

            Picker(L("settings.agent", "Агент"), selection: $model.promptAgentID) {
                ForEach(PromptAgentCatalog.identifiers, id: \.self) { id in
                    Text(agentTitle(id)).tag(id)
                }
            }
            .accessibilityLabel(L("settings.agentKotoryySobiraetPrompt", "Агент, который собирает промпт"))

            // Цена выбора стоит рядом с выбором и меняется вместе с ним.
            Label(model.agentDestinationTitle,
                  systemImage: model.agentKeepsDataLocal ? "lock.fill" : "arrow.up.right.circle.fill")
                .foregroundStyle(model.agentKeepsDataLocal ? Color.green : Color.orange)
                .accessibilityLabel(Lf("settings.dataDestination.a11y", "Куда уходят данные: %@", model.agentDestinationTitle))

            if let note = model.agentAdapter.configurationNote {
                Label(note, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(IRIZ_SUBTLE)
                    .accessibilityLabel(Lf("settings.agentNote.a11y", "Важно про этого агента: %@", note))
            }

            LabeledContent(L("settings.putKCli", "Путь к CLI")) {
                TextField(model.agentAdapter.executableName.isEmpty ? L("settings.polnyyPut", "Полный путь") : L("settings.avtopoisk", "Автопоиск"),
                          text: agentPathBinding)
                    .labelsHidden()
                    .frame(minWidth: 280)
                    .accessibilityLabel(L("settings.putKIspolnyaemomuFaylu", "Путь к исполняемому файлу агента"))
            }

            if let path = model.detectedAgentPath {
                Label(Lf("settings.agentFound", "Найден: %@", path), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(IRIZ_SUBTLE)
                    .textSelection(.enabled)
                    .accessibilityLabel(Lf("settings.agentFound.a11y", "Агент найден. %@", path))
            } else {
                Label(L("settings.neNayden", "Не найден"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(model.promptModeEnabled ? Color.red : Color.secondary)
                    .accessibilityLabel(L("settings.agentNeNayden", "Агент не найден"))
            }

            if model.agentAdapter.requiresModel {
                LabeledContent(L("settings.model", "Модель")) {
                    TextField(L("settings.naprimerQwen25Coder", "например, qwen2.5-coder:7b"), text: $model.agentModel)
                        .labelsHidden()
                        .frame(minWidth: 280)
                        .accessibilityLabel(L("settings.modelLokalnogoAgenta", "Модель локального агента"))
                }
            }

            if model.promptAgentID == PromptAgentCatalog.customID {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("settings.argumentyPoOdnomuV", "Аргументы — по одному в строке"))
                    TextEditor(text: $model.agentCustomArguments)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 72)
                        .accessibilityLabel(L("settings.argumentySvoegoCliPo", "Аргументы своего CLI, по одному в строке"))
                    Text(L("settings.podstanovkiPromptTekstPrompta", "Подстановки: {prompt} — текст промпта отдельным аргументом. Без {prompt} промпт уходит в стандартный ввод. Командная строка не собирается из строк, поэтому кавычки не нужны."))
                        .font(.footnote)
                        .foregroundStyle(IRIZ_SUBTLE)
                        .accessibilityLabel(L("settings.podstanovkaPromptPeredaetTekst", "Подстановка {prompt} передаёт текст отдельным аргументом. Без неё промпт уходит в стандартный ввод. Кавычки не нужны"))
                }
            }

            speechRecognitionControls

            settingsNote {
                Text(L("settings.parakeetBystreeV11", "Parakeet быстрее в 11-15 раз, но транслитерирует английские термины внутри русской фразы: git rebase слышится как «гид репейс». Whisper large-v3 берет их латиницей (19 процентов ошибок на смешанной речи против 44), зато надиктовка в полминуты ждет расшифровки около 16 секунд. Оба считают на этом Маке, наружу не уходит ничего."))
                    .font(.footnote)
                    .foregroundStyle(IRIZ_SUBTLE)
            }

            Picker(L("settings.ispolnitelPrompta", "Исполнитель промпта"), selection: $model.promptRecipient) {
                ForEach(PromptRecipientProfile.allCases, id: \.self) { profile in
                    Text(recipientTitle(profile)).tag(profile)
                }
            }
            .accessibilityLabel(L("settings.ispolnitelGotovogoPromptaPo", "Исполнитель готового промпта по умолчанию"))

            settingsNote {
                Text(L("settings.etotRezhimNeobyazatelenPrompt", "Этот режим необязателен. Промпт собирает выбранный агент, а профиль готовит текст для того, кто будет промпт исполнять. Пустое поле пути включает автопоиск. Обычная диктовка работает локально всегда; расшифровку наружу отдаёт только промпт-режим и только выбранному агенту. Ollama — единственный вариант, который не отправляет ничего: он считает на этом Маке. Готовый промпт вставляется без отправки, а качество проверяется здесь же — утверждение без дословной опоры на надиктовку отклоняется независимо от того, какой агент его сочинил."))
                    .font(.footnote)
                    .foregroundStyle(IRIZ_SUBTLE)
                    .accessibilityLabel(L("settings.promptRezhimNeobyazatelenPrompt", "Промпт-режим необязателен. Промпт собирает выбранный агент, профиль готовит текст для исполнителя. Пустое поле пути включает автопоиск. Обычная диктовка всегда локальна. Расшифровку отдаёт только промпт-режим и только выбранному агенту. Ollama считает на этом Маке и не отправляет ничего. Готовый промпт вставляется без отправки, а утверждение без дословной опоры на надиктовку отклоняется независимо от агента"))
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
                    Text(L("settings.chegoVyHotiteOt", "Чего вы хотите от формы промпта"))
                    TextEditor(text: $model.promptGuidanceInstructions)
                        .font(.system(.body))
                        .frame(minHeight: 72)
                        .accessibilityLabel(L("settings.svoiInstrukciiDlyaPrompt", "Свои инструкции для промпт-режима"))
                    Text(Lf("prompt.instructionsLimit",
                             "До %d символов. Это предпочтение по ФОРМЕ, а не право выдумывать факты: запреты контракта сильнее.",
                             PROMPT_GUIDANCE_INSTRUCTIONS_MAX))
                        .font(.footnote)
                        .foregroundStyle(IRIZ_SUBTLE)

                    // Готовые своды. Не «секретный промпт вендора»: у вендоров
                    // таких файлов нет. Это правила из их же документации по
                    // промпт-инжинирингу, сведённые в один абзац. Имя набора
                    // называет ИСТОЧНИК правил, и рядом стоит ссылка на него.
                    HStack(spacing: 8) {
                        Text(L("settings.gotovyeSvody", "Готовые своды:"))
                            .font(.footnote)
                            .foregroundStyle(IRIZ_SUBTLE)
                        ForEach(PromptGuidancePresets.all) { preset in
                            Button(preset.title) {
                                model.promptGuidanceInstructions = preset.instructions
                                statusMessage = L("settings.svodPodstavlenPravte",
                                                  "Свод подставлен. Правьте под себя и нажмите «Сохранить».")
                            }
                            .buttonStyle(.link)
                            .font(.footnote)
                            .help(preset.source)
                        }
                    }
                }

                ForEach(Array(model.promptGuidanceExamples.indices), id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(Lf("prompt.example", "Пример %d", index + 1))
                                .font(.callout)
                                .foregroundStyle(IRIZ_SUBTLE)
                            Spacer(minLength: 8)
                            Button(role: .destructive) {
                                model.removePromptExample(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Lf("prompt.example.delete.a11y", "Удалить пример %d", index + 1))
                        }
                        TextField(L("settings.kakSkazanoVsluh", "Как сказано вслух"), text: promptExampleSpoken(at: index))
                            .labelsHidden()
                            .accessibilityLabel(Lf("prompt.example.spoken.a11y", "Пример %d: как сказано вслух", index + 1))
                        TextField(L("settings.kakoyPromptNuzhen", "Какой промпт нужен"), text: promptExampleWanted(at: index))
                            .labelsHidden()
                            .accessibilityLabel(Lf("prompt.example.wanted.a11y", "Пример %d: какой промпт нужен", index + 1))
                    }
                }

                if model.promptGuidanceExamples.count < PROMPT_GUIDANCE_EXAMPLES_MAX {
                    Button(L("settings.dobavitPrimer", "Добавить пример"), systemImage: "plus") {
                        model.addPromptExample()
                    }
                    .accessibilityLabel(L("settings.dobavitPrimerDlyaPrompt", "Добавить пример для промпт-режима"))
                } else {
                    Text(Lf("prompt.examplesEnough", "Примеров хватит: больше %d уже не учат форме, а диктуют содержание.", PROMPT_GUIDANCE_EXAMPLES_MAX))
                        .font(.footnote)
                        .foregroundStyle(IRIZ_SUBTLE)
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
                Text(L("settings.spisokPustPromptDlya", "Список пуст — промпт для любого приложения собирается по профилю выше."))
                    .foregroundStyle(IRIZ_SUBTLE)
                    .accessibilityLabel(L("settings.spisokPrilozheniyPustRabotaet", "Список приложений пуст, работает профиль по умолчанию"))
            }

            ForEach(Array(model.appProfiles.indices), id: \.self) { index in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(applicationTitle(model.appProfiles[index].bundleID))
                        Text(model.appProfiles[index].bundleID)
                            .font(.footnote)
                            .foregroundStyle(IRIZ_SUBTLE)
                    }
                    Spacer(minLength: 8)
                    Picker("", selection: appProfileBinding(at: index)) {
                        ForEach(PromptRecipientProfile.allCases, id: \.self) { profile in
                            Text(recipientTitle(profile)).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .accessibilityLabel(Lf("prompt.appProfile.a11y", "Профиль для приложения %@", applicationTitle(model.appProfiles[index].bundleID)))
                    Button(role: .destructive) {
                        appProfileMessage = nil
                        model.removeAppProfile(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Lf("prompt.appProfile.remove.a11y", "Убрать приложение %@ из списка", applicationTitle(model.appProfiles[index].bundleID)))
                }
            }

            Button(L("settings.dobavitPrilozhenie", "Добавить приложение…"), systemImage: "plus") {
                chooseApplication()
            }
            .accessibilityLabel(L("settings.vybratPrilozhenieINaznachit", "Выбрать приложение и назначить ему профиль"))

            if let appProfileMessage {
                Label(appProfileMessage, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(IRIZ_SUBTLE)
                    .accessibilityLabel(appProfileMessage)
            }

            settingsNote {
                Text(Lf("prompt.appProfiles.explainer", "Диктуете в редактор кода — промпт собирается для Codex, диктуете в почту — универсальный. %@ смотрит только на то, какое приложение сейчас спереди: ни окно, ни поле, ни текст чужой программы не читаются. Приложение спрашивается один раз, в момент нажатия, и сразу забывается — на диск и в журнал уходит выбранный профиль, а не имя программы. Приложений, которых нет в списке, это не касается: им достаётся профиль по умолчанию.", IRIZ_NAME))
                    .font(.footnote)
                    .foregroundStyle(IRIZ_SUBTLE)
                    .accessibilityLabel(L("settings.profilVybiraetsyaPoPrilozheniyu", "Профиль выбирается по приложению, которое спереди в момент нажатия. Окно, поле и текст чужой программы не читаются. Приложение спрашивается один раз и сразу забывается: на диск и в журнал уходит профиль, а не имя программы. Приложениям вне списка достаётся профиль по умолчанию"))
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
        case .generic: L("settings.universalnyy", "Универсальный")
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
        panel.title = L("settings.vyberitePrilozhenie", "Выберите приложение")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            appProfileMessage = L("settings.uEtoyProgrammyNet", "У этой программы нет идентификатора — привязать профиль не к чему.")
            return
        }

        switch model.addAppProfile(bundleID: bundleID, profile: model.promptRecipient) {
        case .added:
            appProfileMessage = L("settings.dobavlenoVyberiteProfilI", "Добавлено. Выберите профиль и нажмите «Сохранить».")
        case .updated:
            appProfileMessage = L("settings.etaProgrammaUzheByla", "Эта программа уже была в списке — строка одна, профиль в ней и меняйте.")
        case .invalidBundleID:
            appProfileMessage = L("settings.identifikatorEtoyProgrammyRazobr", "Идентификатор этой программы разобрать не удалось.")
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
                Text(L("settings.razmerPlashki", "Размер плашки"))
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
            .accessibilityLabel(L("settings.razmerPlashkiZapisi", "Размер плашки записи"))

            VStack(alignment: .leading, spacing: 6) {
                Text(L("settings.kakVyglyaditVolna", "Как выглядит волна"))
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
            .accessibilityLabel(L("settings.kakVyglyaditVolnaNa", "Как выглядит волна на плашке записи"))

            Toggle(L("settings.napominaniyaNaPlashke", "Напоминания на плашке"),
                   isOn: $model.hudShowsHints)

            settingsNote {
                Text(L("settings.napominaniyaNapominayutKlavishu", "Напоминания называют клавишу, которой запись заканчивают, и Escape для отмены. Заводски выключены: клавишу, которую вы держите под пальцем, называть незачем, а слова закрывают собой волну — то, ради чего плашка и нужна. Включите на первые дни, если так спокойнее."))
                    .font(.footnote)
                    .foregroundStyle(IRIZ_SUBTLE)
            }

            settingsNote {
                Text(L("settings.perelivyTriTonaVokrug", "Переливы — три тона вокруг цвета режима. Спокойная — те же тона, но разлёт вдвое уже. Монохром — без переливов вовсе. Цвет режима палитра не меняет: обычная диктовка остаётся тёплой, промпт — холодным, иначе по плашке было бы не видно, что именно записывается."))
                    .font(.footnote)
                    .foregroundStyle(IRIZ_SUBTLE)
                    .accessibilityLabel(L("settings.perelivyTriTonaVokrug2", "Переливы: три тона вокруг цвета режима. Спокойная: те же тона, разлёт вдвое уже. Монохром: без переливов. Цвет режима палитра не меняет — диктовка остаётся тёплой, промпт холодным"))
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
                    .accessibilityLabel(Lf("keys.row.a11y", "%@: %@. Записать новое сочетание", action.title, hotkeyLabel(action)))
                }
            }

            if let message = model.validationMessage,
               message.contains(L("settings.konflikt", "Конфликт")) || message.contains("macOS") || message.contains(L("settings.raskladka", "раскладка")) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel(Lf("keys.error.a11y", "Ошибка сочетаний: %@", message))
            }

            // Две сноски подряд были про одно и то же - когда сочетание
            // начинает работать. Осталась одна.
            Text(L("settings.klikniPoSochetaniyuChtoby", "Кликни по сочетанию справа и нажми новое — оно запишется. Сочетание работает сразу после «Сохранить». Отмена переключения — то же сочетание конвертации ещё раз."))
                .font(.footnote)
                .foregroundStyle(IRIZ_SUBTLE)
                .accessibilityLabel(L("settings.sochetaniePrimenyaetsyaSrazuPosl2", "Сочетание применяется сразу после сохранения. Отмена переключения - то же сочетание конвертации ещё раз"))
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
            Picker(L("settings.rezhimRaskladki", "Режим раскладки"), selection: $model.layoutMode) {
                ForEach(LayoutMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityLabel(L("settings.rezhimRaskladki", "Режим раскладки"))

            Text(model.layoutMode.explanation)
                .font(.footnote)
                .foregroundStyle(IRIZ_SUBTLE)
                .accessibilityLabel(Lf("layout.mode.a11y", "Что делает режим %@: %@", model.layoutMode.title, model.layoutMode.explanation))
        } header: {
            sectionHeader(.layout)
        }
    }

    @ViewBuilder
    private var speechRecognitionControls: some View {
        Picker(L("settings.raspoznavatel", "Распознаватель"), selection: $model.speechEngine) {
            ForEach(SpeechModelProfile.allCases, id: \.self) { profile in
                Text(profile.shortName).tag(profile)
            }
        }
        .disabled(files.busy || meetingBusy)
        .accessibilityLabel(L("settings.kakoyDvizhokRaspoznavaniyaRechi", "Какой движок распознавания речи использовать"))
        VStack(alignment: .leading, spacing: 8) {
            Label(model.speechModelInstalled
                  ? Lf("settings.speechModelInstalled", "%@: модель установлена", model.speechEngine.shortName)
                  : Lf("settings.speechModelMissing", "%@: модель не установлена", model.speechEngine.shortName),
                  systemImage: model.speechModelInstalled ? "checkmark.circle" : "arrow.down.circle")
                .foregroundStyle(.primary)
            if !model.speechModelInstalled {
                Text(model.canUseInstalledParakeet
                     ? L("settings.parakeetAlreadyAvailable", "Parakeet уже установлен. Выбери его и сохрани настройки, чтобы использовать для диктовки.")
                     : L("settings.speechModelDownloadHelp", "Для распознавания нужна модель на этом Маке. Автоматически можно скачать только Parakeet: около 0,5 ГБ, один раз. После установки он станет выбранным распознавателем. Звук останется на устройстве."))
                    .font(.footnote)
                    .foregroundStyle(IRIZ_SUBTLE)
            }
            if !model.speechModelInstalled, model.canUseInstalledParakeet {
                Button(L("settings.selectInstalledParakeet", "Выбрать установленный Parakeet")) {
                    model.speechEngine = .multilingualV3
                }
                .modifier(GlassButton())
                .disabled(files.busy || meetingBusy)
            } else {
                Button(model.speechModelInstalled
                       ? L("settings.speechModelSetup", "Настроить распознавание…")
                       : L("settings.downloadParakeet", "Скачать модель Parakeet…")) {
                    openSpeechModelSetup?()
                }
                .modifier(GlassButton())
                .disabled(isPreview || openSpeechModelSetup == nil || files.busy || meetingBusy)
            }
        }
    }

    private var behaviorSection: some View {
        Section {
            speechRecognitionControls
            LabeledContent(L("settings.zaderzhkaEnter", "Задержка Enter")) {
                HStack(spacing: 6) {
                    // labelsHidden обязателен: в Form(.grouped) заголовок TextField
                    // рисуется ВТОРЫМ ярлыком рядом с ярлыком LabeledContent и
                    // сминается в вертикальный столбик из букв на ширине 72 pt.
                    TextField("", text: $model.enterDelayText)
                        .labelsHidden()
                        .frame(width: 72)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(L("settings.zaderzhkaEnterVMillisekundah", "Задержка Enter в миллисекундах"))
                    Text(L("settings.ms", "мс")).foregroundStyle(IRIZ_SUBTLE)
                }
            }

            Picker(L("settings.chistitRech", "Чистить речь"), selection: $model.speechCleanupMode) {
                ForEach(SpeechCleanupMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityLabel(L("settings.gdeChistitsyaRech", "Где чистится речь"))

            // Предупреждение показывается ДО отправки, а не после: оно и есть
            // то согласие, о котором говорил владелец. Живёт ровно там, где
            // текст уходит с машины, и приходит из самого режима - список
            // режимов и список предупреждений не могут разъехаться.
            if let warning = model.speechCleanupMode.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Lf("common.warning.a11y", "Предупреждение: %@", warning))
            }

            Picker(L("settings.posleVstavki", "После вставки"), selection: $model.pasteSuffix) {
                Text(L("settings.probel", "Пробел")).tag(PasteSuffix.appendSpace)
                Text(L("settings.nichego", "Ничего")).tag(PasteSuffix.none)
                Text(L("settings.perevodStroki", "Перевод строки")).tag(PasteSuffix.appendNewline)
            }
            .accessibilityLabel(L("settings.suffiksPosleVstavki", "Суффикс после вставки"))

            Toggle(L("settings.zapuskatPriVhodeV", "Запускать при входе в систему"), isOn: $model.launchAtLogin)
                .toggleStyle(.switch)
                .accessibilityLabel(Lf("settings.launchAtLogin.a11y", "Запускать %@ при входе в систему", IRIZ_NAME))

            Toggle(L("settings.pokazyvatOknoEsliTekst", "Показывать окно, если текст никуда не вставился"),
                   isOn: $model.rescueWindowEnabled)
                .toggleStyle(.switch)
                .accessibilityLabel(L("settings.pokazyvatOknoSTekstom", "Показывать окно с текстом, когда вставка не удалась"))

            settingsNote {
                Text(Lf("settings.rescue.explainer", "Вставка не дошла до поля — %@ поднимает окно с готовым текстом: скопировать или вставить ещё раз, Esc — закрыть. Когда сработал запасной прямой ввод, окна не будет: там текст, скорее всего, уже в поле, и предлагать вставить его второй раз опаснее, чем промолчать.", IRIZ_NAME))
                    .font(.footnote)
                    .foregroundStyle(IRIZ_SUBTLE)
                    .accessibilityLabel(Lf("settings.rescue.explainer.a11y", "Если вставка не дошла до поля, %@ показывает окно с готовым текстом: скопировать или вставить ещё раз, Esc закрывает. При запасном прямом вводе окно не поднимается: текст скорее всего уже в поле", IRIZ_NAME))
            }
        } header: {
            sectionHeader(.behavior)
        }
    }

    private var correctionsSection: some View {
        Section {
            // Кнопка СВЕРХУ. Владелец 07.09.2026: «необходимо добавить
            // возможность добавить замену сверху, чтобы была кнопка, а не
            // снизу. Иначе придётся всю портянку вниз мотать». Новая строка
            // тоже встаёт первой, так что кнопка и результат рядом.
            Button(L("settings.dobavitZamenu", "Добавить замену"), systemImage: "plus") {
                model.addCorrection()
            }
            .accessibilityLabel(L("settings.dobavitParuVSlovar", "Добавить пару в словарь замен"))

            if model.corrections.isEmpty {
                Text(L("settings.zamenPokaNet", "Замен пока нет."))
                    .foregroundStyle(IRIZ_SUBTLE)
                    .accessibilityLabel(L("settings.slovarZamenPust", "Словарь замен пуст"))
            } else {
                // Подписи колонок ОДИН раз. Прежде каждая строка несла свои две:
                // на четырнадцати заменах это двадцать восемь повторов «Как
                // распозналось» и «На что менять», из-за которых сами слова
                // владельца терялись в служебном тексте.
                // Подписи стоят НАД СВОИМИ полями, а не по краям строки.
                // Прежде между ними была распорка, и «На что менять» уезжало к
                // правому краю, далеко от второго поля. Владелец 07.09.2026:
                // «слово „на что менять“ правее, чем сам текст, и не очень
                // понятно. Они должны быть соотнесены между столбцами».
                // Геометрия та же, что у строки: две равные колонки и стрелка
                // между ними, только невидимая.
                HStack(spacing: 8) {
                    Text(L("settings.kakRaspoznalos", "Как распозналось"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").hidden()
                    Text(L("settings.naChtoMenyat", "На что менять"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer().frame(width: CORRECTION_TRASH_WIDTH)
                }
                .font(.caption)
                .foregroundStyle(IRIZ_SUBTLE)
                .accessibilityHidden(true)
            }

            ForEach(Array(model.corrections.indices), id: \.self) { index in
                HStack(spacing: 8) {
                    TextField(L("settings.kakRaspoznalos", "Как распозналось"), text: correctionSource(at: index))
                        .labelsHidden()
                        .accessibilityLabel(Lf("dictionary.heard.a11y", "Как распозналось, замена %d", index + 1))
                    Image(systemName: "arrow.right")
                        .foregroundStyle(IRIZ_SUBTLE)
                        .accessibilityHidden(true)
                    TextField(L("settings.naChtoMenyat", "На что менять"), text: correctionReplacement(at: index))
                        .labelsHidden()
                        .accessibilityLabel(Lf("dictionary.replacement.a11y", "На что менять, замена %d", index + 1))
                    Button(role: .destructive) {
                        model.removeCorrection(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Lf("dictionary.delete.a11y", "Удалить замену %d", index + 1))
                }
            }

        } header: {
            sectionHeader(.corrections)
        }
    }

    /// Редактор заготовок стоит рядом со словарём и намеренно на него не
    /// похож: у замены две короткие строки, у заготовки — фраза и блок текста.
    private var snippetsSection: some View {
        Section {
            // Кнопка сверху по тому же правилу, что и у замен: список читают
            // редко, дописывают часто, и мотать портянку вниз ради этого нельзя.
            Button(L("settings.dobavitZagotovku", "Добавить заготовку"), systemImage: "plus") {
                model.addSnippet()
            }
            .accessibilityLabel(L("settings.dobavitZagotovku", "Добавить заготовку"))

            if model.snippets.isEmpty {
                Text(L("settings.zagotovokPokaNet", "Заготовок пока нет."))
                    .foregroundStyle(IRIZ_SUBTLE)
                    .accessibilityLabel(L("settings.spisokZagotovokPust", "Список заготовок пуст"))
            }

            ForEach(Array(model.snippets.indices), id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField(L("settings.chtoProiznositsya", "Что произносится"), text: snippetTrigger(at: index))
                            .accessibilityLabel(Lf("snippets.phrase.a11y", "Фраза заготовки %d", index + 1))
                        Button(role: .destructive) {
                            model.removeSnippet(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Lf("snippets.delete.a11y", "Удалить заготовку %d", index + 1))
                    }
                    TextEditor(text: snippetBody(at: index))
                        .frame(minHeight: 72)
                        .accessibilityLabel(Lf("snippets.text.a11y", "Текст заготовки %d", index + 1))
                }
                .padding(.vertical, 2)
            }

            settingsNote {
                Text(L("settings.proiznesennayaFrazaZamenyaetsyaS", "Произнесённая фраза заменяется сохранённым текстом — так вставляются шапки, реквизиты и стандартные формулировки. Совпадение точное и по границам слова: «иск» внутри «иска» не сработает, регистр значения не имеет. Заготовки и словарь замен подставляются одним проходом, поэтому текст заготовки словарь уже не переписывает. Сырая расшифровка на диске остаётся нетронутой, а промпт-режим заготовок не видит вовсе."))
                    .font(.footnote)
                    .foregroundStyle(IRIZ_SUBTLE)
                    .accessibilityLabel(L("settings.proiznesennayaFrazaZamenyaetsyaS2", "Произнесённая фраза заменяется сохранённым текстом: шапки, реквизиты, стандартные формулировки. Совпадение точное и по границам слова, регистр не важен. Заготовки и словарь подставляются одним проходом, текст заготовки словарь не переписывает. Сырая расшифровка на диске не меняется, промпт-режим заготовок не видит"))
            }
        } header: {
            sectionHeader(.snippets)
        }
    }

    private var transferSection: some View {
        Section {
            HStack {
                Button(L("settings.eksportirovat", "Экспортировать…"), systemImage: "square.and.arrow.up") {
                    exportDictionary()
                }
                .accessibilityLabel(L("settings.eksportirovatSlovarIZagotovki", "Экспортировать словарь и заготовки в файл"))

                Button(L("settings.importirovat", "Импортировать…"), systemImage: "square.and.arrow.down") {
                    importDictionary()
                }
                .accessibilityLabel(L("settings.importirovatSlovarIZagotovki", "Импортировать словарь и заготовки из файла"))

                // Шаблон. Выгрузка пустого словаря показывает формат, но не
                // показывает, ЧТО писать в поля. Владелец 07.09.2026: «нужно
                // иметь возможность скачать шаблон, который можно заполнить и
                // загрузить». Внутри два примера замены и одна заготовка.
                Button(L("settings.skachatShablon", "Скачать шаблон"), systemImage: "doc.badge.plus") {
                    saveDictionaryTemplate()
                }
                .accessibilityLabel(L("settings.skachatShablonSlovarya", "Скачать шаблон файла словаря с примерами"))
            }

            if let transferMessage {
                Label(transferMessage, systemImage: transferFailed
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill")
                    .foregroundStyle(transferFailed ? Color.red : Color.secondary)
                    .accessibilityLabel(transferMessage)
            }

            settingsNote {
                Text(L("settings.faylObychnyyJsonEgo", "Файл — обычный JSON, его можно открыть и поправить руками. Это единственная копия словаря: всё остальное живёт в настройках системы и исчезает вместе с ними. При импорте совпавшие по фразе записи берутся из файла, а те, которых в файле нет, остаются на месте — импорт ничего не удаляет. Негодный файл отклоняется целиком, с номером испорченной записи: половина восстановленного словаря хуже честного отказа. Импортированное попадает в настройки после кнопки «Сохранить»."))
                    .font(.footnote)
                    .foregroundStyle(IRIZ_SUBTLE)
                    .accessibilityLabel(L("settings.faylObychnyyJsonEgo2", "Файл — обычный JSON, его можно поправить руками. Это единственная копия словаря. При импорте совпавшие по фразе записи берутся из файла, остальные остаются на месте, импорт ничего не удаляет. Негодный файл отклоняется целиком, с номером испорченной записи. Импортированное попадает в настройки после кнопки Сохранить"))
            }
        } header: {
            sectionHeader(.transfer)
        }
    }

    private func saveDictionaryTemplate() {
        let panel = NSSavePanel()
        panel.title = L("settings.shablonSlovarya", "Шаблон словаря")
        panel.nameFieldStringValue = "iriz-slovar-shablon.json"
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.dictionaryTemplateData().write(to: url, options: .atomic)
            transferFailed = false
            transferMessage = L("settings.shablonZapisanZapolnite", "Шаблон записан. Заполните его и вернитесь сюда с кнопкой «Импортировать».")
        } catch {
            transferFailed = true
            transferMessage = "Не удалось записать файл: \(error.localizedDescription)"
        }
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.title = L("settings.eksportSlovaryaIZagotovok", "Экспорт словаря и заготовок")
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
        panel.title = L("settings.importSlovaryaIZagotovok", "Импорт словаря и заготовок")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let summary = try model.importDictionaryData(data)
            transferFailed = false
            transferMessage = summary + L("settings.nazhmiteSohranitChtobyZapisat", " Нажмите «Сохранить», чтобы записать.")
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
                     ? L("settings.schitayu", "Считаю…")
                     : L("settings.pokaNichegoNeZanyato", "Пока ничего не занято: ни модели, ни надиктовок на диске нет."))
                    .foregroundStyle(IRIZ_SUBTLE)
            } else {
                ForEach(diskEntries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            Text(entry.note)
                                .font(.footnote)
                                .foregroundStyle(IRIZ_SUBTLE)
                        }
                        Spacer()
                        Text(diskUsageSizeText(entry.bytes))
                            .monospacedDigit()
                            .foregroundStyle(IRIZ_SUBTLE)
                        Button(L("settings.pokazat", "Показать")) {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                        .modifier(GlassButton())
                    }
                }
                HStack {
                    Text(L("settings.vsego", "Всего"))
                    Spacer()
                    Text(diskUsageSizeText(diskEntries.reduce(0) { $0 + $1.bytes }))
                        .monospacedDigit()
                }
                .font(.system(size: 13, weight: .semibold))
            }

            Picker(L("settings.hranitNadiktovki", "Хранить надиктовки"), selection: $model.retentionDays) {
                Text(L("settings.vsegda", "Всегда")).tag(0)
                Text(L("settings.30Dney", "30 дней")).tag(30)
                Text(L("settings.90Dney", "90 дней")).tag(90)
                Text(L("settings.god", "Год")).tag(365)
            }
            .pickerStyle(.menu)

            Text(L("settings.srokSchitaetsyaPoDate", "Срок считается по дате папки. Что старше — уходит при следующем запуске, "
                 + "молча и без корзины. «Всегда» выключает уборку совсем.\n\n"
                 + "Мусор убирается в любом случае и сроку не подчиняется: распакованный "
                 + "архив модели, рядом с которым лежит распакованная папка, и карантин "
                 + "старше месяца. Терять там нечего — это копии того, что уже есть."))
                .font(.footnote)
                .foregroundStyle(IRIZ_SUBTLE)

            Text(L("settings.knopkiOchistitVseZdes", "Кнопки «очистить всё» здесь нет намеренно: нажатая не глядя, она стоит "
                 + "дороже сэкономленного гигабайта. Выборочная чистка живёт там, где видно, "
                 + "что именно чистишь, - в окне истории."))
                .font(.footnote)
                .foregroundStyle(IRIZ_SUBTLE)
        } header: {
            Text(L("settings.mestoNaDiske", "Место на диске"))
        }
        .task(id: page) {
            guard page == .disk, diskEntries.isEmpty, !diskCounting else { return }
            diskCounting = true
            let found = await Task.detached(priority: .utility) { diskUsageEntries() }.value
            diskEntries = found
            diskCounting = false
        }
    }

    /// Язык интерфейса. Отдельной страницей и первой: человек, открывший
    /// настройки на незнакомом языке, ищет именно ее.
    private var languageSection: some View {
        Section {
            Picker(L("settings.yazykInterfeysa", "Язык интерфейса"), selection: $languageChoice) {
                ForEach(IrizLanguage.allCases, id: \.self) { language in
                    Text(language == .auto
                         ? "\(language.ownName) (\(irizResolvedLanguage(choice: .auto, systemPreferred: Locale.preferredLanguages).ownName))"
                         : language.ownName)
                        .tag(language)
                }
            }
            .pickerStyle(.inline)
            .onChange(of: languageChoice) { _, choice in
                setIrizLanguageChoice(choice)
                statusMessage = L("settings.yazykSmenitsyaPoslePerezapuska", "Язык сменится после перезапуска.")
            }

            Text(L("settings.avtoBeretYazykSistemy", "«Авто» берет язык системы. Выбор руками старше системного: "
                 + "macOS может быть на английском, а интерфейс вам нужен русский.\n\n"
                 + "Смена языка вступает в силу после перезапуска приложения: "
                 + "тексты собираются один раз при старте."))
                .font(.footnote)
                .foregroundStyle(IRIZ_SUBTLE)

            // Тема живёт рядом с языком: и то и другое - про то, как окно
            // выглядит, а не про то, как продукт работает.
            Picker(L("settings.temaInterfeysa", "Тема интерфейса"), selection: $appearanceChoice) {
                ForEach(IrizAppearanceChoice.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.inline)
            .onChange(of: appearanceChoice) { _, choice in
                setIrizAppearanceChoice(choice)
                applyIrizAppearance()
            }

            Text(L("settings.temaMenyaetsyaSrazu", "Тема меняется сразу, перезапуск не нужен. Плашки это не касается: она висит поверх чужого окна и берёт вид системы. Тёмное стекло на светлом столе было бы чёрным прямоугольником посреди чужой работы."))
                .font(.footnote)
                .foregroundStyle(IRIZ_SUBTLE)
        } header: {
            Text(L("settings.yazyk", "Язык"))
        }
    }

    /// Расшифровка файлов: бросил запись - получил текст рядом с ней.
    private var filesSection: some View {
        Section {
            speechRecognitionControls
            IrizDropZone(title: L("settings.perenesiteZapisiSyuda", "Перенесите записи сюда"),
                         subtitle: L("settings.diktofonZvonokEksportIz", "Диктофон, звонок, экспорт из встречи. Текст ляжет рядом с файлом."),
                         extensions: AudioFileBatch.supportedExtensions.sorted()) { urls in
                enqueue(urls, into: $files.queue)
            }
            .disabled(files.busy)
            Picker(L("files.language", "Язык записи"), selection: $fileLanguage) {
                ForEach(DictationLanguage.allCases, id: \.self) { language in
                    Text(language == .auto ? L("files.languageAuto", "Определить автоматически")
                         : Locale.current.localizedString(forLanguageCode: language.rawValue) ?? language.rawValue)
                        .tag(language)
                }
            }
            .disabled(files.busy)
            ForEach(files.queue) { item in
                VStack(alignment: .leading, spacing: 6) {
                    IrizDropRow(item: item) { files.queue.removeAll { $0.id == item.id } }
                        .disabled(files.busy)
                    if let error = files.errors[item.id] {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        let destination = AudioFileBatch.destination(forSource: item.url, in: nil)
                        Button(L("files.showDestination", "Показать папку результата")) {
                            NSWorkspace.shared.activateFileViewerSelecting([destination.deletingLastPathComponent()])
                        }
                        .modifier(GlassButton())
                    }
                }
            }
            if !files.queue.isEmpty {
                Button(files.errors.isEmpty ? L("files.start", "Расшифровать записи")
                       : L("files.retry", "Повторить оставшиеся")) {
                    guard !meetingBusy, !isPreview, model.speechModelInstalled else { return }
                    files.start(engine: model.speechEngine, language: fileLanguage)
                }
                .modifier(GlassProminentButton())
                .disabled(files.busy || meetingBusy || isPreview || !model.speechModelInstalled)
            }
            if let progress = files.progress {
                if let fraction = files.fraction {
                    ProgressView(value: fraction) { Text(progress) }
                } else {
                    ProgressView { Text(progress) }
                        .controlSize(.small)
                }
                Button(files.stopping ? L("files.stopping", "Останавливаю после текущей записи…")
                       : L("files.stopAfterCurrent", "Остановить после текущей записи")) {
                    files.stopAfterCurrent()
                }
                .modifier(GlassButton())
                .disabled(files.stopping)
            }
            if let report = files.report {
                Text(report).font(.footnote).textSelection(.enabled)
            }
            ForEach(files.results, id: \.source) { result in
                VStack(alignment: .leading, spacing: 6) {
                    Label(result.destination.lastPathComponent, systemImage: "checkmark.circle")
                        .textSelection(.enabled)
                    HStack {
                        Button(L("files.openText", "Открыть текст")) { openFileResult(result.destination) }
                            .modifier(GlassButton())
                        Button(L("files.showInFinder", "Показать в Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([result.destination])
                        }
                        .modifier(GlassButton())
                    }
                }
            }
            Text(L("settings.rasshifrovkaIdetNaEtom", "Расшифровка идёт на этом Маке тем же движком, что и диктовка. "
                 + "Звук никуда не отправляется, а сам файл остаётся там, где лежал."))
                .font(.footnote)
                .foregroundStyle(IRIZ_SUBTLE)
        } header: {
            Text(L("settings.rasshifrovkaFaylov", "Расшифровка файлов"))
        }
    }

    /// Встречи и заседания: тот же перенос, но звук СОХРАНЯЕТСЯ.
    /// История надиктовок в главном окне.
    ///
    /// Владелец просил одно место: «не сверху просто через плашку, а
    /// непосредственно основная история для всех настроек, для просмотра
    /// предыдущих моих диктовок». Отдельная плавающая панель истории остаётся
    /// для быстрого доступа с клавиши, но искать прошлую надиктовку человек
    /// приходит сюда, где уже лежит всё остальное.
    ///
    /// Вставки в поле здесь нет намеренно: фокус принадлежит этому окну, и
    /// «вставить» означало бы вставить в него же. Копирование есть.
    private var historySection: some View {
        Section {
            HStack(spacing: 8) {
                IrizGlyphView(.history, size: 13)
                    .foregroundStyle(IRIZ_SUBTLE)
                TextField(L("settings.poiskPoNadiktovkam", "Поиск по надиктовкам"), text: $historyModel.query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(L("settings.poiskPoNadiktovkam", "Поиск по надиктовкам"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(IrizSearchFieldPlate())

            if historyModel.isLoading {
                ProgressView(L("history.loading", "Читаю надиктовки…"))
                    .controlSize(.small)
            }
            if let notice = historyModel.notice {
                Label(notice, systemImage: historyModel.noticeIsError ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(historyModel.noticeIsError ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !historyModel.isLoading, historyModel.visible.isEmpty, !historyModel.noticeIsError {
                Text(historyModel.entries.isEmpty
                     ? L("settings.pokaPustoNadiktovannoePoyavitsya", "Пока пусто. Надиктованное появится здесь.")
                     : L("history.notFoundTitle", "Ничего не нашлось"))
                    .foregroundStyle(IRIZ_SUBTLE)
            }
            if historyModel.query.isEmpty, historyModel.entries.count >= DICTATION_HISTORY_VISIBLE_LIMIT {
                Text(L("history.loadingBody", "Показываю последние сто. Остальные найдёт поиск."))
                    .font(.footnote)
                    .foregroundStyle(IRIZ_SUBTLE)
            }
            ForEach(historyModel.visible) { entry in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dictationHistoryPreview(entry.displayText))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text(dictationHistoryTimeLabel(entry.label))
                            Text("·")
                            Text("\(entry.displayText.count) \(L("history.charsShort", "симв."))")
                        }
                        .font(.footnote)
                        .foregroundStyle(IRIZ_SUBTLE)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("settings.kopirovat", "Копировать")) { copyHistory(entry) }
                        .disabled(isPreview)
                }
                .contextMenu {
                    Button(L("settings.kopirovat", "Копировать")) { copyHistory(entry) }
                        .disabled(isPreview)
                }
            }
        } header: {
            Text(L("settings.istoriyaNadiktovok", "История надиктовок"))
        }
        .onAppear { loadHistory() }
        .onDisappear { historyModel.cancelLoading() }
    }

    private func loadHistory() {
        historyModel.reload { try DictationStore.dictationsDirectory() }
    }

    private func copyHistory(_ entry: DictationHistoryEntry) {
        guard !isPreview else { return }
        let copied = DictationHistoryClipboard.copy(entry.displayText)
        historyModel.noticeIsError = !copied
        historyModel.notice = copied
            ? L("history.copiedTimed", "Скопировано. Буфер очистится через 2 минуты.")
            : L("history.copyFailed", "Не удалось скопировать. Попробуй ещё раз.")
    }

    private var meetingsSection: some View {
        Section {
            speechRecognitionControls
            IrizDropZone(title: L("settings.perenesiteZapisVstrechi", "Перенесите запись встречи"),
                         subtitle: L("meetings.storage", "Запись на русском языке. Звук и протокол сохранятся в архиве iriz; готовые файлы можно открыть отсюда."),
                         extensions: AudioFileBatch.supportedExtensions.sorted()) { urls in
                enqueue(urls, into: $meetingQueue)
            }
            .disabled(meetingBusy)
            ForEach(meetingQueue) { item in
                IrizDropRow(item: item) { meetingQueue.removeAll { $0.id == item.id } }
                    .disabled(meetingBusy)
            }

            if !meetingQueue.isEmpty {
                Button(meetingFailed ? L("files.retry", "Повторить оставшиеся")
                       : L("settings.razobratZapisi", "Разобрать записи")) { runMeetings() }
                    .modifier(GlassProminentButton())
                    .disabled(meetingBusy || files.busy || isPreview || !model.speechModelInstalled)
                    .accessibilityLabel(L("settings.razobratZapisiVstrech", "Разобрать записи встреч"))
            }

            if let meetingProgress {
                // Ход показывается словами, а не полосой: у часовой записи
                // полоса врёт про остаток, а название шага честно говорит,
                // что именно сейчас происходит.
                ProgressView { Text(meetingProgress) }
                    .controlSize(.small)
                Button(meetingStopping ? L("files.stopping", "Останавливаю после текущей записи…")
                       : L("files.stopAfterCurrent", "Остановить после текущей записи")) {
                    meetingStopping = true
                }
                .modifier(GlassButton())
                .disabled(meetingStopping)
            }

            if let meetingReport {
                Label(meetingReport,
                      systemImage: meetingFailed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(meetingFailed ? Color.orange : IRIZ_SUBTLE)
                    .textSelection(.enabled)
            }

            ForEach(meetingResults, id: \.directory) { artifacts in
                VStack(alignment: .leading, spacing: 6) {
                    Label(artifacts.directory.lastPathComponent, systemImage: "checkmark.circle")
                        .textSelection(.enabled)
                    HStack {
                        Button(L("meetings.openProtocol", "Открыть протокол")) { openFileResult(artifacts.transcript) }
                            .modifier(GlassButton())
                        Button(L("meetings.showFolder", "Показать папку встречи")) {
                            NSWorkspace.shared.activateFileViewerSelecting([artifacts.directory])
                        }
                        .modifier(GlassButton())
                    }
                }
            }

            // Здесь продукт нарушает собственное правило, и молчать об этом
            // нельзя: в диктовке звук не сохраняется никогда, а у встречи он
            // остаётся вместе с расшифровкой. Иначе протокол нечем сверить.
            Text(L("settings.raznicaSDiktovkoyNazvana", "Разница с диктовкой названа прямо: у встречи сохраняется и звук, и расшифровка. "
                 + "В обычной диктовке звук не сохраняется никогда. Файлы лежат на вашем диске "
                 + "открытым текстом под правами 0600: шифрование диска даёт FileVault, а не приложение."))
                .font(.footnote)
                .foregroundStyle(IRIZ_SUBTLE)
        } header: {
            Text(L("settings.vstrechi", "Встречи"))
        }
    }

    /// Прогон очереди встреч.
    ///
    /// Записи идут по одной, а не разом: распознавание и разделение по
    /// говорящим забирают ANE целиком, и две записи параллельно означали бы
    /// вдвое дольше обе, а не быстрее.
    ///
    /// Отказ на одной записи не отменяет остальные: владелец принёс папку, и
    /// одна битая запись не должна стоить ему разбора всех.
    private func runMeetings() {
        guard !meetingBusy, !files.busy, !meetingQueue.isEmpty, !isPreview, model.speechModelInstalled else { return }
        meetingBusy = true
        meetingStopping = false
        let items = meetingQueue
        let engine = model.speechEngine
        meetingReport = nil
        meetingFailed = false
        Task { @MainActor in
            let pipeline = MeetingPipeline(transcriber: AudioFileTranscriber(engine: engine))
            var done = 0
            var failures: [String] = []
            for item in items {
                guard !meetingStopping else { break }
                let name = item.url.deletingPathExtension().lastPathComponent
                meetingProgress = "\(name): \(L("files.reading", "читаю запись"))"
                do {
                    let result = try await pipeline.run(
                        audio: item.url,
                        title: name,
                        progress: { step in
                            Task { @MainActor in
                                guard meetingBusy else { return }
                                meetingProgress = "\(name): \(step.lowercased())"
                            }
                        }
                    )
                    done += 1
                    meetingQueue.removeAll { $0.id == item.id }
                    meetingResults.append(result.artifacts)
                    if !result.speakersResolved {
                        // Владелец должен отличить монолог от неудавшегося
                        // разделения: в первом случае имена расставлять не
                        // нужно, во втором нужно.
                        failures.append(Lf("meetings.speakersUnresolved", "%@: говорящие не разделены. Текст сохранён одной репликой; проверьте протокол.", name))
                    }
                } catch {
                    let reason = (error as? MeetingPipelineFailure)?.rawValue ?? error.localizedDescription
                    failures.append("\(name): \(reason)")
                }
            }
            meetingProgress = nil
            meetingBusy = false
            meetingFailed = !failures.isEmpty
            let base = Lf("files.finished", "Готово: %d из %d.", done, items.count)
                + (meetingStopping ? " " + L("files.stopped", "Очередь остановлена. Оставшиеся файлы можно запустить снова.") : "")
            meetingReport = failures.isEmpty ? base : base + "\n" + failures.joined(separator: "\n")
        }
    }

    private func openFileResult(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            statusMessage = Lf("files.openFailed", "Не удалось открыть %@. Проверь файл через Finder.", url.lastPathComponent)
        }
    }

    /// Положить файлы в очередь, не задваивая уже принесённые.
    private func enqueue(_ urls: [URL], into queue: Binding<[IrizDropItem]>) {
        for source in urls {
            let url = source.standardizedFileURL
            guard !queue.wrappedValue.contains(where: { $0.url.standardizedFileURL == url }) else { continue }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            queue.wrappedValue.append(IrizDropItem(url: url, bytes: bytes ?? 0))
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
    case history
    case language
    case files
    case meetings
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

    /// Значок страницы из СВОЕГО набора. Готовые системные глифы - чужой
    /// набор: они читаются как деталь macOS, а не как лицо продукта.
    public var glyph: IrizGlyph {
        switch self {
        case .history: return .history
        case .language: return .language
        case .files: return .files
        case .meetings: return .meetings
        case .keys: return .keys
        case .layout: return .layout
        case .dictation: return .dictation
        case .plate: return .plate
        case .dictionary: return .dictionary
        case .snippets: return .snippets
        case .prompt: return .prompt
        case .transfer: return .transfer
        case .disk: return .disk
        }
    }

    public var title: String {
        switch self {
        case .history: return L("settings.istoriya", "История")
        case .language: return L("settings.yazyk", "Язык")
        case .files: return L("settings.rasshifrovkaFaylov", "Расшифровка файлов")
        case .meetings: return L("settings.vstrechi", "Встречи")
        case .keys: return L("settings.klavishi", "Клавиши")
        case .layout: return L("settings.raskladka2", "Раскладка")
        case .dictation: return L("settings.diktovka", "Диктовка")
        case .plate: return L("settings.plashka", "Плашка")
        case .dictionary: return L("settings.slovarZamen", "Словарь замен")
        case .snippets: return L("settings.zagotovki", "Заготовки")
        case .prompt: return L("settings.promptRezhim", "Промпт-режим")
        case .transfer: return L("settings.perenos", "Перенос")
        case .disk: return L("settings.mestoNaDiske", "Место на диске")
        }
    }
}
