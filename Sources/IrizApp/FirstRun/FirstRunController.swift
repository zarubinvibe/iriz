// Ведущий знакомства: состояние, действия и само окно.
//
// Окно своё, а не NSAlert. Цепочка системных диалогов, которая была тут
// раньше, не могла ничего объяснить: у алерта нет места под мысль, а у самого
// страшного разрешения объяснение обязано быть длиннее одной строки.
import AppKit
import AVFoundation
import Combine
import IrizCore
import IrizDictate
import IrizPrompt
import IrizSettings
import SwiftUI

/// Найденный на диске агент: что показать и что записать в настройки.
struct FirstRunAgent: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
}

@MainActor
final class FirstRunModel: ObservableObject {
    @Published private(set) var step: FirstRunStep = .welcome
    @Published private(set) var granted: [FirstRunPermission: Bool] = [:]
    @Published var tryItText: String = ""
    /// Идёт ли проба и какой уровень голоса. Живут в модели, а не во вьюхе:
    /// вьюха перестраивается на каждый кадр, а состояние пробы обязано её
    /// пережить.
    @Published private(set) var isRecording = false
    /// Речь кончилась, текста ещё нет. Отдельное состояние, а не молчание:
    /// пауза без подписи читается как «сломалось».
    @Published private(set) var isTranscribing = false
    @Published private(set) var level: CGFloat = 0

    /// Ход установки модели. nil - установка ещё не начиналась.
    @Published private(set) var installPhase: SpeechModelInstallPhase?
    /// Модель на диске. Читается живьём при каждом обновлении разрешений: она
    /// могла приехать и до знакомства.
    @Published private(set) var modelInstalled = false

    /// Агенты, которые уже стоят на этом Маке. Ищутся на диске, а не
    /// спрашиваются у человека: спросить «где у тебя лежит codex» значит
    /// отправить его в терминал ровно там, где он пришёл за простотой.
    @Published private(set) var agents: [FirstRunAgent] = []
    /// Кто выбран. nil - никто, и это нормальный исход шага.
    @Published private(set) var connectedAgentID: String?
    /// Перевод включён. Отдельно от подключения агента: агент нужен обоим
    /// режимам, но включать их за человека нельзя.
    @Published private(set) var translationEnabled = false
    @Published var translateText: String = ""

    /// Как начать и закончить пробу. Замыкание, а не прямая ссылка на
    /// контроллер: знакомство не обязано знать устройство конвейера диктовки,
    /// а конвейер не обязан знать про знакомство.
    var toggleDictation: (() -> Void)?
    /// Как поменять клавишу диктовки. Тоже замыкание: запись сочетания живёт
    /// в настройках, и знакомство не обязано знать её устройство.
    var recordHotkey: ((@escaping () -> Void) -> Void)?

    /// Клавиша диктовки, как её называет само приложение. Читается живьём:
    /// человек может поменять её прямо на этом экране, и подпись обязана
    /// поменяться вместе с ней.
    @Published private(set) var hotkeyLabel: String = ""
    /// Клавиша перевода. Отдельная от диктовки: это разные жесты.
    @Published private(set) var translationHotkeyLabel: String = ""

    func refreshHotkeyLabel() {
        hotkeyLabel = MenuKeys.current().dictation
    }

    func refreshTranslationHotkeyLabel() {
        translationHotkeyLabel = MenuKeys.russianKeyName(
            DictationSettings.shared.configuredTranslationHotkey
        )
    }

    func changeHotkey() {
        recordHotkey? { [weak self] in
            Task { @MainActor in self?.refreshHotkeyLabel() }
        }
    }

    private let defaults: UserDefaults
    private var poll: Timer?
    /// Что сделать, когда знакомство кончилось.
    var onFinish: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshPermissions()
        refreshHotkeyLabel()
        refreshTranslationHotkeyLabel()
    }

    var canGoBack: Bool { firstRunPreviousStep(before: step) != nil }
    var isLastStep: Bool { firstRunNextStep(after: step) == nil }

    func goNext() {
        guard firstRunCanAdvance(from: step) else { return }
        guard let next = firstRunNextStep(after: step) else {
            finish()
            return
        }
        withAnimation(irizAnimation(.irizEaseOut)) { step = next }
    }

    func goBack() {
        guard let previous = firstRunPreviousStep(before: step) else { return }
        withAnimation(irizAnimation(.irizEaseOut)) { step = previous }
    }

    /// Действие шага. Микрофон спрашивается системным запросом, остальные два
    /// открывают нужную страницу Системных настроек: включить переключатель
    /// за человека нельзя, и обещать этого не надо.
    func performAction() {
        switch step {
        case .model:
            installModel()
        case .microphone:
            // Системное окно показывается ОДИН раз за жизнь приложения. После
            // отказа повторный запрос молча не делает ничего, и кнопка
            // становится мёртвой ровно тогда, когда она нужнее всего.
            // Поэтому после отказа ведём в настройки, как и с остальными.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                openSettingsPane("Privacy_Microphone")
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refreshPermissions() }
            }
        case .accessibility:
            // Системный промпт сам добавляет iriz в список, и человеку
            // остаётся только щёлкнуть переключатель. Без него он ищет
            // приложение в пустом списке и не находит.
            let options = ["AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openSettingsPane("Privacy_Accessibility")
        case .inputMonitoring:
            openSettingsPane("Privacy_ListenEvent")
        default:
            break
        }
    }

    /// Начать установку модели. Идёт в фоне: пока она едет, человек проходит
    /// разрешения, и время не тратится дважды.
    func installModel() {
        guard !SpeechModelInstaller.shared.isRunning else { return }
        installPhase = .downloading(0)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await SpeechModelInstaller.shared.install(dictating: self.isRecording) { phase in
                Task { @MainActor in
                    self.installPhase = phase
                    if case .finished = phase { self.modelInstalled = true }
                }
            }
        }
    }

    /// Найти агентов на диске и вспомнить, кто выбран.
    func refreshAgents() {
        let settings = DictationSettings.shared
        agents = PromptAgentCatalog.identifiers.compactMap { id in
            guard let adapter = PromptAgentCatalog.adapter(id: id, customArguments: []) else { return nil }
            // Свой CLI без пути искать негде: он и есть «введи путь руками»,
            // а знакомство спрашивать путь не будет.
            guard !adapter.executableName.isEmpty else { return nil }
            guard let url = DictationSettings.detectAgentExecutable(adapter: adapter) else { return nil }
            return FirstRunAgent(id: id, name: adapter.displayName, path: url.path)
        }
        connectedAgentID = settings.promptModeEnabled ? settings.promptAgentID : nil
        translationEnabled = settings.translationModeEnabled
    }

    /// Подключить агента: выбрать его и включить режим задания. Включение
    /// сказано вслух на самом шаге - молча уводить речь наружу нельзя.
    func connectAgent(_ id: String) {
        let settings = DictationSettings.shared
        settings.promptAgentID = id
        settings.promptModeEnabled = true
        connectedAgentID = id
    }

    func enableTranslation() {
        DictationSettings.shared.translationModeEnabled = true
        translationEnabled = true
    }

    func refreshPermissions() {
        modelInstalled = speechModelCacheExists(for: .multilingualV3)
        refreshAgents()
        var next: [FirstRunPermission: Bool] = [:]
        for permission in FirstRunPermission.allCases {
            next[permission] = firstRunPermissionGranted(permission)
        }
        granted = next
    }

    /// Пока окно открыто, состояние разрешений перечитывается: человек уходит
    /// в Системные настройки и возвращается, и точка обязана позеленеть сама.
    /// Без опроса он видит «пока нет» после того, как только что разрешил, и
    /// решает, что не сработало.
    func startWatching() {
        stopWatching()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    func stopWatching() {
        poll?.invalidate()
        poll = nil
    }

    /// Проба голосом. Идёт тем же путём, что и обычная диктовка.
    func toggleTrial() {
        isRecording.toggle()
        toggleDictation?()
    }

    /// Уровень голоса от конвейера. Приходит только пока открыто знакомство.
    func updateLevel(_ value: Float) {
        level = CGFloat(max(0, min(1, value)))
    }

    /// Запись началась или кончилась. Источник один и тот же, что у знака
    /// строки меню: две поверхности про одну запись не имеют права расходиться.
    func dictationStateChanged(isRecording running: Bool, isTranscribing thinking: Bool = false) {
        if isTranscribing != thinking { isTranscribing = thinking }
        guard isRecording != running else { return }
        isRecording = running
        if !running { level = 0 }
    }

    func finish() {
        defaults.set(true, forKey: FIRST_RUN_COMPLETED_KEY)
        stopWatching()
        onFinish?()
    }

    private func openSettingsPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Окно знакомства. Живёт столько же, сколько приложение: закрытие крестиком
/// не должно считаться отказом от продукта.
@MainActor
final class FirstRunWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let model = FirstRunModel()

    func show() {
        // Пока знакомство открыто, приложение перестаёт быть невидимкой из
        // строки меню. Без этого у окна нет ни значка в Dock, ни места в
        // Cmd-Tab: человек уходит в Системные настройки, окно проваливается за
        // чужие, и вернуть его нечем - продукт выглядит исчезнувшим.
        NSApp.setActivationPolicy(.regular)
        if let window {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            model.startWatching()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            // Размер фиксирован: у знакомства нет содержимого, которое стоило
            // бы тянуть, а изменяемое окно на семь экранов текста разъезжается.
            // Свернуть его человек имеет право: разрешения выдаются в чужом
            // окне, и убрать подсказку с дороги - нормальное желание.
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = FirstRunCopy.windowTitle
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Прозрачности у этого окна НЕТ, и это осознанно.
        //
        // Подложка знакомства непрозрачна по решению: на семи экранах текста
        // сквозь окно видно чужие окна, и объяснение превращается в кашу -
        // читаемость важнее эффекта. Прозрачный корпус под непрозрачным
        // содержимым не давал ничего, кроме своего пути композиции и своей
        // тени, то есть был мёртвой настройкой.
        model.onFinish = { [weak self] in self?.close() }
        window.contentView = NSHostingView(rootView: FirstRunView(model: model))
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Поверх чужих окон - пока знакомство не пройдено. Разрешение даётся в
        // Системных настройках, и инструкция обязана быть видна В ЭТОТ момент,
        // а не за ними. Окно двигается мышью, если оно закрыло нужный
        // переключатель.
        window.level = .floating
        // Пространство человек меняет сам, окно едет за ним: искать знакомство
        // на другом рабочем столе никто не станет.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        self.window = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.startWatching()
    }

    func close() {
        model.stopWatching()
        window?.orderOut(nil)
        // Значок в Dock уходит вместе с окном: в остальное время продукт живёт
        // в строке меню и места в Dock не занимает.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Крестик - не отказ от продукта, но и не повод держать значок в Dock.
    /// Путь тот же, что у кнопки «Готово», кроме отметки о пройденном
    /// знакомстве: её ставит только сам последний шаг.
    func windowWillClose(_ notification: Notification) {
        model.stopWatching()
        NSApp.setActivationPolicy(.accessory)
    }
}
