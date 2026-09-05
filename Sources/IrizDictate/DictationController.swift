// Оркестратор диктовки smltlk — свой код (не донорский), написан по карте
// извлечения: логика handlePress/handleRelease донора (EXTRACT_MAP §2)
// переписана под MenuBarExtra-архитектуру smltlk.
//
// Конвейер: правый Cmd (toggle) → запись 16 кГц моно → Parakeet TDT v3 →
// постобработка → raw.txt на диск → вставка в фокусное поле.
// Модель греется ФОНОВОЙ ЗАДАЧЕЙ в start(), не по нажатию клавиши.
import AppKit
import CoreGraphics
import FluidAudio
import Foundation
import IrizCore
import IrizPrompt

@MainActor
public final class DictationController {
    public static let settingsDidSaveNotification = Notification.Name("ru.smltlk.dictationSettingsDidSave")

    /// Состояние конвейера — опора для знака в строке меню (рисует другой
    /// исполнитель). Тексты unavailable — по-русски, их можно показать как есть.
    public enum State: Equatable {
        /// Модель ещё греется (первая загрузка ~16 с, последующие ~0,1 с).
        case warmingUp
        case ready
        case recording
        case transcribing
        case generatingPrompt
        case unavailable(String)
    }

    public private(set) var state: State = .warmingUp {
        didSet {
            log("state: \(oldValue) → \(state)")
            onStateChange?(state)
            hud?.pipelineStateChanged(state)
        }
    }
    /// Подписка на смену состояния (знак строки меню).
    public var onStateChange: ((State) -> Void)?

    private let settings: DictationSettings
    private let audio = AudioCapture()
    private let asr = TranscriptionWorker()
    private let hotkeys = HotkeyListener()
    /// Окно истории надиктовок — по хоткею истории.
    private let history = DictationHistoryPresenter()
    /// Обучение словаря из правок человека. Хранит ТОЛЬКО наш текст и адрес
    /// окна, куда он ушёл; чужое поле спрашивается один раз и не сохраняется.
    let learning = DictationLearningWatcher()
    private let learningToast = DictationLearningToastPresenter()
    /// Плашка «идёт голос»: знак в строке меню — 18×18 pt в углу, владелец его
    /// не видит, когда смотрит в поле ввода. Заводится в `start()`, то есть
    /// только в живом приложении: под `swift test` `start()` не зовут, и панель
    /// в тест-раннере не поднимается (её там и не поднять).
    private var hud: DictationHUDPresenter?

    /// Барьер реентранси транскрипции (actor TranscriptionWorker от неё НЕ
    /// защищает — см. комментарий там). Точный эквивалент isBusy донора.
    private var isBusy = false
    private var isRecording = false
    private var modelReady = false
    private var recordingPurpose: DictationRecordingPurpose = .dictation
    private var recordedTargetPID: pid_t?
    /// РЕШЕНИЕ, а не приложение. Идентификатор того, что было спереди, живёт
    /// ровно один вызов в `handlePress`; дальше едет только выбранный профиль.
    private var recordedPromptProfile: PromptRecipientProfile?
    private var maxDurationTask: Task<Void, Never>?
    /// Весь хвост после отпускания клавиши. Удерживаем задачу, чтобы остановка
    /// приложения могла отменить и ASR, и запущенный процесс Codex.
    private var pipelineTask: Task<Void, Never>?
    /// Номер попытки распознавания. Сторожевой таймер и сама транскрипция
    /// сверяются с ним: чей номер устарел — тот попытку уже не закрывает и
    /// текст не вставляет.
    private var transcriptionGeneration: UInt64 = 0
    private var transcriptionWatchdog: Task<Void, Never>?
    /// NSWorkspace иногда присылает повторные sleep/wake. Только первый
    /// переход гасит или поднимает runtime.
    private var powerLifecycle = AudioPowerLifecycle()
    /// Подмена таймаута распознавания — только тестами, чтобы не ждать живьём.
    private let transcriptionTimeoutOverride: Double?
    /// Счётчики доставки: их читает status.json (scripts/gate_app.sh).
    private let insertionStats: InsertionStats
    private var settingsObserver: NotificationObserver?

    public init() {
        self.settings = .shared
        self.transcriptionTimeoutOverride = nil
        self.insertionStats = InsertionStats()
        observeSettings()
    }

    /// Для тестов и будущих точек сборки.
    init(settings: DictationSettings,
         transcriptionTimeout: Double? = nil,
         insertionStats: InsertionStats = InsertionStats()) {
        self.settings = settings
        self.transcriptionTimeoutOverride = transcriptionTimeout
        self.insertionStats = insertionStats
        observeSettings()
    }

    /// Текущий уровень записи для индикации (волна знака строки меню).
    public var recordingLevel: Float {
        recordingLevelSnapshot.level
    }

    /// HUD нужен и уровень, и монотонная sequence: по одному Float нельзя
    /// отличить честную ровную громкость от умершего аудиопотока.
    var recordingLevelSnapshot: (level: Float, sequence: UInt64) {
        audio.latestRecordingLevelSnapshot()
    }

    public var isRecordingActive: Bool { isRecording }

    // MARK: - Запуск

    /// Собрать плашку заранее — по той же причине, по которой фоном греется
    /// модель: первое за утро нажатие не должно выглядеть подвисанием.
    /// Зовётся со старта приложения, отдельно от `start()`: без «Мониторинга
    /// ввода» тот уходит в `.unavailable`, а плашка нужна и там — ею же
    /// показывается отказ.
    ///
    /// Ничего не показывает: см. `DictationHUDPanelSurface.prewarm()`.
    public func prewarmHUD() {
        if hud == nil { wireHUD() }
        hud?.prewarm()
    }

    public func start() {
        // Рубильник офлайна — ПЕРВОЙ строкой: дальше любой сетевой вызов
        // FluidAudio бросает OfflineError вместо обращения к сети.
        DownloadUtils.enforceOffline = true

        let hostile = detectedHostileRegistryEnvVars(in: ProcessInfo.processInfo.environment)
        if !hostile.isEmpty {
            log("WARNING: registry override env var(s) set: \(hostile.joined(separator: ", ")) — ignored, offline enforced")
        }

        wireLearning()
        wireHotkeys()
        wireAudioConfigurationRecovery()
        wireHUD()
        guard hotkeys.start() else {
            state = .unavailable("Нет разрешения «Мониторинг ввода» — горячая клавиша диктовки не слушается.")
            return
        }

        // После wake уже загруженная модель остаётся в памяти. Поднимаем
        // только listener; повторный load нужен лишь первому запуску.
        if modelReady {
            state = .ready
        } else {
            Task { [weak self] in
                await self?.warmUpModel()
            }
        }

        // Микрофон: спросить заранее, чтобы первое нажатие не уходило в
        // системный диалог. Требует NSMicrophoneUsageDescription + entitlement
        // в бандле (зона scripts/build_app.sh).
        if !Permissions.isGranted(.microphone) {
            Permissions.request(.microphone)
        }
    }

    public func stop() {
        if isRecording {
            // Sleep/выход отменяет клип: не запускаем распознавание и не
            // создаём raw/audio recovery-артефакт.
            handleCancel()
        }
        maxDurationTask?.cancel()
        maxDurationTask = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        transcriptionWatchdog?.cancel()
        transcriptionWatchdog = nil
        transcriptionGeneration &+= 1
        isBusy = false
        audio.onConfigurationChange = nil
        hotkeys.stop()
        audio.stopEngine()
        state = modelReady ? .ready : .warmingUp
    }

    /// Перед сном не оставляет активными ни tap/engine, ни обработку клипа.
    public func prepareForSystemSleep() {
        guard powerLifecycle.transition(for: .willSleep) == .suspendRuntime else { return }
        log("dictation: system sleep — suspending audio runtime")
        stop()
    }

    /// После wake возвращает hotkey/listener, но запись начинает только
    /// следующее явное нажатие пользователя.
    public func resumeAfterSystemWake() {
        guard powerLifecycle.transition(for: .didWake) == .resumeListening else { return }
        log("dictation: system wake — resuming listener")
        start()
    }

    private func warmUpModel() async {
        do {
            try await asr.load(profile: settings.speechEngine)
            // Рычаг под смешанную речь включен и в ЖИВОЙ диктовке, а не только в
            // CLI: без него термины внутри русской фразы ломаются ровно там, где
            // владелец диктует каждый день.
            await asr.setInitialPrompt(whisperDefaultInitialPrompt)
            modelReady = true
            if state == .warmingUp { state = .ready }
        } catch {
            log("ASR warmup failed: \(error.localizedDescription)")
            state = .unavailable(error.localizedDescription)
        }
    }

    // MARK: - Привязка хоткеев

    private func wireHotkeys() {
        applySettings()

        hotkeys.onPress = { [weak self] in self?.handlePress(purpose: .dictation) }
        hotkeys.onRelease = { [weak self] detectedAt in
            self?.handleRelease(shortcut: .standard, hotkeyDetectedAt: detectedAt)
        }
        hotkeys.onPromptPress = { [weak self] in self?.handlePress(purpose: .prompt) }
        hotkeys.onTranslationPress = { [weak self] in self?.handlePress(purpose: .translation) }
        hotkeys.onPromptRelease = { [weak self] detectedAt in
            self?.handleRelease(shortcut: .standard, hotkeyDetectedAt: detectedAt)
        }
        hotkeys.onReleaseAlternate = { [weak self] detectedAt in
            self?.handleRelease(shortcut: .alternate, hotkeyDetectedAt: detectedAt)
        }
        hotkeys.onCancel = { [weak self] in self?.handleCancel() }
        hotkeys.onShowHistory = { [weak self] in
            self?.history.toggle()
        }
        hotkeys.onRejectedBusyPress = { [weak self] in
            guard let self else { return }
            // Нажатие при непрогретой модели, летящей транскрипции или
            // защищённом вводе не молчит: звук + причина в лог.
            if let refusal = self.startRefusal() {
                log("dictation: press rejected — \(refusal.rawValue)")
                self.hud?.startRefused(refusal)
            }
            if self.settings.playFeedbackSounds { Sounds.playError() }
        }
        hotkeys.isRecordingActive = { [weak self] in self?.isRecording ?? false }
        hotkeys.canStartRecording = { [weak self] in
            guard let self else { return false }
            return self.startRefusal() == nil
        }
    }

    /// Открывает или закрывает окно истории надиктовок.
    ///
    /// До этого попасть в историю можно было только хоткеем, то есть только по
    /// памяти: в меню про неё не было ни строки, и целая функция оставалась
    /// ненаходимой. Меню зовёт этот метод — ту же самую цепочку, что и клавиша.
    /// Начать запись встречи.
    ///
    /// Отдельная точка входа, а не флаг диктовки: у режимов разные исходы, и
    /// перепутать их нельзя. Диктовка вставляет текст под курсор и звук не
    /// хранит; встреча кладёт звук и протокол в свою папку и не вставляет
    /// ничего.
    public func startMeetingRecording() {
        guard !isRecording else { return }
        handlePress(purpose: .meeting)
    }

    /// Остановить запись встречи и отдать её в разбор.
    public func stopMeetingRecording() {
        guard isRecording, recordingPurpose == .meeting else { return }
        handleRelease(shortcut: .standard,
                      hotkeyDetectedAt: ProcessInfo.processInfo.systemUptime)
    }

    public var isRecordingMeeting: Bool {
        isRecording && recordingPurpose == .meeting
    }

    /// Сохранить записанное и запустить конвейер протокола.
    ///
    /// Файл пишется ДО разбора и остаётся на диске, даже если разбор упадёт:
    /// запись заседания дороже протокола, её нельзя терять из-за отказа
    /// распознавателя.
    private func finishMeetingRecording(samples: [Float]) {
        state = .ready
        guard !samples.isEmpty else {
            log("meeting: пустая запись, сохранять нечего")
            return
        }
        do {
            let url = try meetingRecordingScratchURL()
            let recording = try writeMeetingWAV(samples: samples,
                                                sampleRate: SAMPLE_RATE,
                                                to: url)
            log("meeting: записано \(Int(recording.seconds)) с в \(url.lastPathComponent)")
            Task { @MainActor in
                let pipeline = MeetingPipeline()
                let title = "Встреча " + meetingDateFormatter().string(from: Date())
                do {
                    let result = try await pipeline.run(audio: recording.url, title: title)
                    log("meeting: протокол готов, реплик \(result.turns.count)")
                } catch {
                    // Разбор упал, но звук уже на диске - его можно принести в
                    // окно встреч руками и разобрать ещё раз.
                    log("meeting: разбор отказал (\(error)), звук остался в \(recording.url.path)")
                }
            }
        } catch {
            log("meeting: не удалось сохранить звук (\(error))")
        }
    }

    /// Кого звать, когда с плашки просят настройки. Ставит приложение: у
    /// модуля диктовки окна настроек нет и быть не должно.
    public var onOpenSettings: (() -> Void)?

    public func showHistory() {
        history.toggle()
    }

    /// Применяет сохранённые настройки к уже работающему listener.
    public func applySettings() {
        settings.refreshFromDisk()
        hotkeys.setHotkey(settings.configuredHotkey)
        hotkeys.setEnterHotkey(settings.configuredEnterHotkey)
        hotkeys.setHistoryHotkey(settings.configuredHistoryHotkey)
        hotkeys.setPromptHotkey(settings.configuredPromptHotkey)
        hotkeys.setPromptHotkeyEnabled(settings.promptModeEnabled)
        hotkeys.setTranslationHotkey(settings.configuredTranslationHotkey)
        hotkeys.setTranslationHotkeyEnabled(settings.translationModeEnabled)
        hotkeys.setAlternateCompletionEnabled(settings.alternateCompletionEnabled)
        hotkeys.setTriggerMode(settings.triggerMode)
    }

    private func observeSettings() {
        settingsObserver = NotificationObserver(NotificationCenter.default.addObserver(
            forName: Self.settingsDidSaveNotification,
            object: settings,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        })
    }

    /// Плашка «идёт голос»: уровень она берёт отсюда же, откуда волна знака, а
    /// подсказку про историю — из НАСТРОЕННОГО хоткея, чтобы не отправлять
    /// владельца нажимать не то.
    /// Показать панель расшифровки с готовым текстом - без микрофона и без
    /// речи. Нужно инструменту: снять панель кадром и судить её глазами можно
    /// только на живом окне, а живое окно иначе поднимается только настоящей
    /// неудавшейся вставкой, которую по заказу не устроишь.
    public func showUndeliveredDemo(_ text: String) {
        if hud == nil { wireHUD() }
        hud?.deliveryFinished(.notDelivered(.targetNeverRequestedText), text: text)
    }

    private func wireHUD() {
        // Один раз за жизнь процесса. `start()` зовётся ещё и после пробуждения
        // системы, и пересобранный презентер выбрасывал бы вместе с собой
        // прогретую панель — то есть возвращал заминку первому показу после
        // каждого сна. Все замыкания внутри держат контроллер слабо, пересборка
        // ничего не освежает.
        guard hud == nil else { return }
        hud = DictationHUDPresenter(
            levelSnapshot: { [weak self] in self?.recordingLevelSnapshot ?? (0, 0) },
            // Состояние конвейера тем же приёмом, что уровень: когда время
            // плашки истекло, презентер обязан спросить «а что сейчас?», а не
            // гасить экран по памяти о последнем показанном сообщении.
            pipelineState: { [weak self] in self?.state ?? .ready },
            historyHint: { [weak self] in
                guard let self else { return "" }
                return dictationHUDHistoryHint(keycode: self.settings.historyHotkeyKeycode,
                                               modifiers: self.settings.historyHotkeyModifiers)
            },
            triggerMode: { [weak self] in self?.settings.triggerMode ?? .toggle },
            activeHotkeyHint: { [weak self] in
                guard let self else { return "" }
                switch self.recordingPurpose {
                case .dictation:
                    return dictationHUDHistoryHint(keycode: self.settings.hotkeyKeycode,
                                                   modifiers: self.settings.hotkeyModifiers)
                case .prompt:
                    return dictationHUDHistoryHint(keycode: self.settings.promptHotkeyKeycode,
                                                   modifiers: self.settings.promptHotkeyModifiers)
                case .translation:
                    return dictationHUDHistoryHint(keycode: self.settings.translationHotkeyKeycode,
                                                   modifiers: self.settings.translationHotkeyModifiers)
                case .meeting:
                    // У записи встречи своей клавиши нет: она начинается из
                    // окна, куда владелец принёс запись или нажал «записать».
                    return ""
                }
            },
            showsDragHint: { [weak self] in
                dictationHUDShowsDragHint(
                    shownCount: self?.settings.dictationHUDHintShownCount
                        ?? DICTATION_HUD_DRAG_HINT_LIMIT
                )
            },
            // Режим записи — плашка обязана показать его СРАЗУ, пока владелец
            // говорит, а не после, на распознавании.
            recordingPurpose: { [weak self] in self?.recordingPurpose ?? .dictation },
            surface: { [weak self, settings] in
                let surface = DictationHUDPanelSurface(settings: settings)
                // Управление подключается прямо здесь: плашка знает, у кого
                // спросить язык, и знает, кому сказать о смене. Без этого меню
                // на ней просто не открывается - молча, без поломки.
                surface.controls = DictationHUDControls(
                    currentLanguage: { settings.dictationLanguage },
                    setLanguage: { language in
                        settings.dictationLanguage = language
                        // Настройки сохраняются сразу: язык меняют за секунду
                        // до нажатия клавиши, и «применится после сохранения»
                        // здесь означало бы «не применится вовсе».
                        NotificationCenter.default.post(
                            name: DictationController.settingsDidSaveNotification,
                            object: settings
                        )
                    },
                    currentSize: { settings.dictationHUDSize },
                    setSize: { size in
                        settings.dictationHUDSize = size
                        NotificationCenter.default.post(
                            name: DictationController.settingsDidSaveNotification,
                            object: settings
                        )
                    },
                    openSettings: { self?.onOpenSettings?() },
                    openHistory: { self?.showHistory() }
                )
                return surface
            }
        )
    }

    /// Причина, по которой запись сейчас не стартует, или nil. Одна точка
    /// решения для автомата хоткея и для handlePress — чтобы они не разъехались.
    private func startRefusal() -> DictationStartRefusal? {
        dictationStartRefusal(modelReady: modelReady,
                              isRecording: isRecording,
                              isBusy: isBusy,
                              secureInputActive: Permissions.isSecureInputActive)
    }

    /// Смена аудиоустройства посреди записи: крючок AudioCapture до этого
    /// никому не был присвоен, а восстановление графа — мёртвым кодом.
    private func wireAudioConfigurationRecovery() {
        audio.onConfigurationChange = { [weak self] in
            // Уведомление приходит уже на главную очередь (observer заведён с
            // queue: .main), так что изоляция здесь фактическая, а не обещанная.
            MainActor.assumeIsolated { self?.handleAudioConfigurationChange() }
        }
    }

    private func handleAudioConfigurationChange() {
        log("dictation: audio configuration changed — recovering graph")
        do {
            let recovered = try audio.recoverAfterConfigurationChange()
            log(recovered
                ? "dictation: audio graph recovered after configuration change"
                : "dictation: audio configuration changed while engine idle — nothing to recover")
        } catch {
            log("dictation: audio graph recovery FAILED: \(error.localizedDescription)")
            guard isRecording else { return }
            // Движок стоит, дописывать нечем. Отпускаем запись как по таймеру
            // максимальной длительности: уже захваченные сэмплы уходят в
            // распознавание, владелец получает начало фразы, а не тишину.
            hotkeys.resetToggleState()
            handleRelease(shortcut: .standard,
                          hotkeyDetectedAt: ProcessInfo.processInfo.systemUptime)
        }
    }

    // MARK: - Конвейер

    /// Начать или закончить диктовку не клавишей, а из интерфейса.
    ///
    /// Нужно знакомству: там человек пробует голос ДО того, как узнал, какая
    /// клавиша за это отвечает. Нажатие кнопки идёт тем же путём, что и
    /// нажатие клавиши, - иначе проба показывала бы не тот продукт, который
    /// потом достанется.
    /// Правка человека -> всплывашка -> словарь.
    ///
    /// Пара НЕ попадает в словарь сама. Словарь применяется молча к каждой
    /// следующей диктовке, и молчаливое обучение однажды выучит опечатку:
    /// человек должен увидеть пару и согласиться. Решение владельца от
    /// 05.09.2026, записано в docs/PLAN-FEATURES.md.
    private func wireLearning() {
        learning.onPairs = { [weak self] pairs in
            self?.learningToast.show(pairs)
        }
        learningToast.onAccept = { [weak self] pairs in
            guard let self else { return }
            let existing = self.settings.transcriptCorrections
            let added = pairs.map { TranscriptCorrection(source: $0.heard, replacement: $0.fixed) }
            self.settings.transcriptCorrections = existing + added
            log("learning: добавлено пар в словарь \(added.count)")
        }
    }

    public func toggleDictationFromUI() {
        handlePress(purpose: .dictation)
    }

    private func handlePress(purpose: DictationRecordingPurpose) {
        if let refusal = startRefusal() {
            log("dictation: press refused — \(refusal.rawValue)")
            hud?.startRefused(refusal)
            // Защищённый ввод — отказ снаружи автомата: его состояние надо
            // сбросить, иначе следующее нажатие уедет в «release» без записи.
            if refusal == .secureInputActive { hotkeys.resetToggleState() }
            if settings.playFeedbackSounds { Sounds.playError() }
            return
        }
        guard Permissions.isGranted(.microphone) else {
            log("dictation: microphone not granted — requesting")
            Permissions.request(.microphone)
            hotkeys.resetToggleState()
            if settings.playFeedbackSounds { Sounds.playError() }
            return
        }
        do {
            try audio.startRecording(inputDevicePreference: settings.inputDevice)
        } catch {
            log("dictation: audio start failed: \(error.localizedDescription)")
            hotkeys.resetToggleState()
            if settings.playFeedbackSounds { Sounds.playError() }
            return
        }
        recordingPurpose = purpose
        // Приложение спрашиваем ОДИН раз и только в промпт-режиме: обычная
        // диктовка от получателя не зависит вовсе. Из ответа берутся два
        // значения — pid для адресной вставки и профиль промпта, — после чего
        // сам объект приложения выходит из области видимости. Идентификатор не
        // сохраняется, не считается и не попадает в журнал: запись «куда
        // владелец диктует» — это данные о том, с кем он работает.
        let frontApplication = purpose == .prompt ? NSWorkspace.shared.frontmostApplication : nil
        recordedTargetPID = frontApplication?.processIdentifier
        recordedPromptProfile = purpose == .prompt
            ? settings.promptAppProfileMap.profile(forBundleID: frontApplication?.bundleIdentifier)
            : nil
        // Новая диктовка - лучший момент спросить про предыдущую: человек
        // закончил править и вернулся к работе. Ждать дольше бессмысленно, а
        // спрашивать раньше значит перебивать его посреди правки.
        learning.check()
        isRecording = true
        state = .recording
        if settings.playFeedbackSounds { Sounds.playStart() }
        scheduleMaxDurationAutoRelease()
    }

    private func handleRelease(shortcut: DictationReleaseShortcut, hotkeyDetectedAt: TimeInterval) {
        guard isRecording else { return }
        isRecording = false
        maxDurationTask?.cancel()
        maxDurationTask = nil

        let purpose = recordingPurpose
        let targetPID = recordedTargetPID
        // Профиль решён в момент нажатия, когда нужное приложение ещё было
        // спереди. Перерешать его здесь нельзя: пока говорили, фокус мог уйти.
        let promptProfile = recordedPromptProfile
        recordingPurpose = .dictation
        recordedTargetPID = nil
        recordedPromptProfile = nil

        let captured = audio.endRecording()

        // Встреча уходит своим путём немедленно: у неё другой исход. Текст
        // никуда не вставляется, звук сохраняется, и порог «слишком короткий
        // клип» ей не подходит - трёхсекундная реплика в заседании это тоже
        // заседание.
        if purpose == .meeting {
            finishMeetingRecording(samples: captured.samples)
            return
        }

        guard case .transcribe(let clipSeconds) =
                recordingReleaseAction(capturedSampleCount: captured.samples.count) else {
            // Слишком короткий клип — случайное касание, молча выходим.
            state = .ready
            return
        }

        settings.refreshFromDisk()
        let language = settings.dictationLanguage
        let corrections = settings.transcriptCorrections
        // Заготовки идут только в путь вставки. В промпт-режиме ниже
        // используется `result.text` — сырьё, — поэтому раскрытая шапка
        // документа наружу к агенту не уезжает.
        let snippets = settings.snippets
        let removeFinalPeriod = settings.removeFinalPeriod
        let pasteSuffix = settings.pasteSuffix
        let pressEnter = shouldPressEnterAfterVoiceOutput(
            purpose: purpose,
            shortcut: shortcut,
            primaryBehavior: settings.primaryCompletionBehavior
        )
        let enterDelayNanoseconds = UInt64(settings.enterDelayMilliseconds) * 1_000_000
        let playSounds = settings.playFeedbackSounds

        transcriptionGeneration &+= 1
        let generation = transcriptionGeneration
        isBusy = true
        state = .transcribing
        scheduleTranscriptionWatchdog(generation: generation,
                                      clipSeconds: clipSeconds,
                                      playSounds: playSounds)

        pipelineTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishTranscription(generation: generation) }
            // Легло ли сырьё на диск. Нужно плашке провала: обещать историю,
            // когда сохранить не успели, — та же ложь, за которую этот этап
            // уже правили.
            var savedRaw = false
            var promptGenerationStarted = false
            do {
                let result = try await self.asr.transcribe(samples: captured.samples,
                                                           language: language,
                                                           requestedAt: hotkeyDetectedAt)
                let processed = processedDictationText(rawTranscript: result.text,
                                                       corrections: corrections,
                                                       snippets: snippets,
                                                       removeFinalPeriod: removeFinalPeriod,
                                                       language: language)
                log("ASR: \(millisecondsLabel(result.fluidCallSeconds)) for \(captured.samples.count) samples")
                // Молчим, когда не сработало ничего: иначе лог зарастёт нулями.
                // Раскрытие заготовки видно в тексте, но без строки в логе
                // «почему шапка не вставилась» отладить нечем.
                if processed.appliedSnippetCount > 0 {
                    log("dictation: \(processed.appliedSnippetCount) snippet(s) expanded")
                }

                let plan = dictationDeliveryPlan(rawTranscript: result.text,
                                                 processedText: processed.text)
                // Сырьё на диск — ДО вставки и НЕЗАВИСИМО от её исхода.
                // Раньше этот вызов стоял ПОСЛЕ проверки на пустой текст, и
                // пустая обработка теряла надиктовку целиком.
                var rawURL: URL?
                if plan.savesRawText {
                    rawURL = try DictationStore.save(rawText: result.text)
                    savedRaw = true
                    // Тайминги токенов — сразу за сырьём и НИКОГДА вместо него:
                    // отдельный файл, отдельная попытка, свой отказ в лог.
                    // Надиктовка не имеет права упасть из-за побочного артефакта.
                    self.saveTokenTimings(result.tokenTimings,
                                          audioSeconds: result.audioSeconds,
                                          besideRawAt: rawURL)
                }
                // Обе строки ниже говорят про сырьё, и обе обязаны говорить правду:
                // при пустом ответе ASR (тишина в микрофон) каталог не заводится вообще,
                // а прежняя формулировка рапортовала «raw kept on disk» и в этом случае.
                // Замерено живьём: тишина → ASR вернул пустую строку → каталога от этой
                // минуты на диске нет, а лог утверждал обратное. Этап, весь смысл которого
                // «приложение не врёт», не имеет права врать в собственном логе.
                let rawFate = plan.savesRawText ? "raw kept on disk" : "nothing to keep — ASR returned empty"
                guard self.transcriptionGeneration == generation else {
                    log("dictation: transcription returned after timeout — \(rawFate), text not inserted")
                    return
                }

                // Сторож охраняет только ASR. Codex имеет собственный жёсткий
                // таймаут; оставлять здесь ASR-таймер значило бы оборвать
                // нормальную генерацию длинного промпта через несколько секунд.
                self.transcriptionWatchdog?.cancel()
                self.transcriptionWatchdog = nil

                if purpose == .translation {
                    guard let rawURL else {
                        log("translation: ASR returned empty - nothing to translate")
                        self.hud?.nothingRecognized(savedToHistory: false)
                        if playSounds { Sounds.playError() }
                        return
                    }
                    promptGenerationStarted = true
                    self.state = .generatingPrompt
                    try await self.translateAndDeliver(
                        rawTranscript: result.text,
                        rawURL: rawURL,
                        recordedTargetPID: targetPID,
                        generation: generation,
                        playSounds: playSounds
                    )
                    return
                }

                if purpose == .prompt {
                    guard let rawURL else {
                        log("prompt: ASR returned empty — nothing to build")
                        self.hud?.nothingRecognized(savedToHistory: false)
                        if playSounds { Sounds.playError() }
                        return
                    }
                    promptGenerationStarted = true
                    self.state = .generatingPrompt
                    try await self.generateAndDeliverPrompt(
                        rawTranscript: result.text,
                        rawURL: rawURL,
                        recordedTargetPID: targetPID,
                        profile: promptProfile ?? self.settings.promptRecipient,
                        generation: generation,
                        playSounds: playSounds
                    )
                    return
                }

                guard plan.insertsText else {
                    // Считаем ОТДЕЛЬНО от отказов: вставка не провалилась, её
                    // не было. На диске эти случаи неотличимы - `inserted.txt`
                    // не появляется и там, и там, - и именно из-за этого 12,6 %
                    // каталогов без вставки спорили с 5,8 % по счётчику.
                    let nothing = self.insertionStats.recordNothingToInsert()
                    log("dictation: processing left nothing to insert — \(rawFate), всего таких \(nothing)")
                    self.hud?.nothingRecognized(savedToHistory: plan.savesRawText)
                    if playSounds { Sounds.playError() }
                    return
                }

                // Очистка речи - между обработкой и вставкой: словарь замен и
                // разбор уже отработали, а в поле уходит уже очищенный текст.
                //
                // Внешний режим здесь НЕ вызывается. Он уводит текст с машины,
                // а обычная диктовка наружу не уходит никогда: наружу ходит
                // отдельный режим, который владелец включает руками и видит
                // предупреждение. Местная очистка молчалива по построению.
                let cleaned: String
                switch self.settings.speechCleanupMode {
                case .off:
                    cleaned = processed.text
                case .local:
                    cleaned = speechCleanupLocal(processed.text)
                case .external:
                    // Единственная ветка, где текст диктовки уходит с машины, и
                    // включает её владелец руками, прочитав предупреждение.
                    cleaned = await self.cleanedExternally(processed.text)
                }
                let textToInsert = pastedText(from: cleaned, suffix: pasteSuffix)
                let attempt = TextInserter.insert(textToInsert)
                // Запоминаем СВОЙ текст и адрес окна: по ним потом узнаем
                // правку человека. Чужого здесь нет ни байта.
                self.learning.remember(inserted: textToInsert,
                                       pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
                let verdict = await TextInserter.confirmDelivery(attempt)
                self.recordInsertionVerdict(verdict)
                // Плашка ДО Enter и до записи inserted.txt: владелец должен
                // увидеть исход сразу, а не после настроенной задержки Enter.
                self.hud?.deliveryFinished(verdict, text: textToInsert)
                // Спасение — сразу за плашкой и с ТЕМ ЖЕ текстом, что уходил в
                // поле. Сырьё сюда попасть не может: у ASR фамилия клиента
                // звучит так, как послышалась.
                self.offerRecovery(text: textToInsert, verdict: verdict)

                switch verdict {
                case .delivered:
                    // Enter только по ПОДТВЕРЖДЁННОЙ доставке: раньше он летел
                    // по факту «отправили ⌘V», то есть иногда в пустоту.
                    if pressEnter {
                        try await Task.sleep(nanoseconds: enterDelayNanoseconds)
                        KeyboardShortcutPoster.postReturn()
                    }
                case .waiting:
                    log("dictation: delivery verdict unresolved — counted as failure")
                case .notDelivered(let failure):
                    log("dictation: text NOT delivered — \(failure.rawValue)")
                }
                // Рядом с сырьём — то, что ФАКТИЧЕСКИ ушло в поле (после словаря
                // и суффикса). Только по подтверждённой доставке: «вставленным»
                // называется вставленное, иначе следующий этап будет диффить
                // правку против того, чего в поле не было. Сырьё этим не
                // трогается — это отдельный файл.
                //
                // ПОСЛЕ Enter, не до: задержку Enter владелец настраивает сам,
                // и запись файла не имеет права её сдвигать.
                if verdict == .delivered {
                    self.saveInsertedText(textToInsert, besideRawAt: rawURL)
                }
                guard playSounds else { return }
                switch dictationFeedbackSound(for: verdict) {
                case .done: Sounds.playDone()
                case .error: Sounds.playError()
                }
            } catch is CancellationError {
                log(promptGenerationStarted
                    ? "prompt: pipeline cancelled"
                    : "dictation: pipeline cancelled")
            } catch {
                if promptGenerationStarted {
                    log("prompt: pipeline failed — \(safePromptFailureLogLabel(for: error))")
                } else {
                    log("dictation: transcribe/insert failed: \(error.localizedDescription)")
                }
                // Молчать здесь нельзя: `defer` тут же ставит `.ready`, рабочая
                // плашка гаснет — и владелец видит ровно то же, что при удачной
                // короткой вставке, хотя текста в поле нет, а при упавшем ASR
                // от надиктовки не осталось даже сырья. Плашка сама решит, не
                // перебивает ли она уже сказанный исход.
                //
                // Устаревшую попытку не докладываем: её закрыл сторож и своё
                // сообщение уже показал.
                if self.transcriptionGeneration == generation {
                    if promptGenerationStarted {
                        self.hud?.promptFailed(promptFailureKind(for: error))
                    } else {
                        self.hud?.recognitionFailed(savedToHistory: savedRaw)
                    }
                }
                if playSounds { Sounds.playError() }
            }
        }
    }

    /// Второй слой конвейера: сырьё остаётся каноном, выбранный агент возвращает
    /// только проверяемый PromptSpec, а готовый текст собирается локально.
    /// Вставка — без суффикса и без Enter.
    ///
    /// Качество не зависит от добросовестности агента: `PromptSpecValidator`
    /// требует дословной опоры каждого утверждения на сырьё, поэтому соврать
    /// нашему верификатору не может ни один CLI, какой бы марки он ни был.
    /// Перевод надиктованного и его вставка.
    ///
    /// Короче промпта на всю проверку: у перевода нет ни схемы, ни четырнадцати
    /// пунктов, ни разметки. Есть один обмен и одно правило - вставляем ровно
    /// то, что вернул агент, очищенное от обёрток.
    ///
    /// Сырьё на диск уже легло до вызова: перевод может не дойти, а сказанное
    /// терять нельзя.
    /// Очистка внешним агентом.
    ///
    /// Зовётся ТОЛЬКО из режима `.external`, который владелец включает руками и
    /// рядом с которым в настройках стоит предупреждение. Отказ здесь никогда
    /// не роняет диктовку: не нашёлся агент, не ответил, ответил мусором -
    /// уходит исходный текст. Очистка это удобство, а не условие доставки.
    private func cleanedExternally(_ text: String) async -> String {
        guard settings.speechCleanupMode == .external else { return text }
        let adapter = settings.promptAgentAdapter
        guard let executableURL = settings.detectPromptAgentExecutable() else {
            log("cleanup: агент не найден, текст идёт как есть")
            return text
        }
        let model = settings.promptAgentModel
        guard !adapter.requiresModel || !model.isEmpty else {
            log("cleanup: модель агента не задана, текст идёт как есть")
            return text
        }
        do {
            let answer = try await CodexPromptGenerator(
                executableURL: executableURL,
                adapter: adapter,
                model: model
            )
            .ask(SpeechCleanupRequest.body(text: text))
            return SpeechCleanupRequest.cleaned(from: answer, original: text)
        } catch {
            log("cleanup: агент отказал (\(error)), текст идёт как есть")
            return text
        }
    }

    private func translateAndDeliver(
        rawTranscript: String,
        rawURL: URL,
        recordedTargetPID: pid_t?,
        generation: UInt64,
        playSounds: Bool
    ) async throws {
        let adapter = settings.promptAgentAdapter
        guard let executableURL = settings.detectPromptAgentExecutable() else {
            throw PromptPipelineError.codexUnavailable
        }
        let model = settings.promptAgentModel
        guard !adapter.requiresModel || !model.isEmpty else {
            throw PromptPipelineError.codexUnavailable
        }

        let answer = try await CodexPromptGenerator(
            executableURL: executableURL,
            adapter: adapter,
            model: model
        )
        .ask(TranslationRequest.body(text: rawTranscript,
                                     targetLanguage: settings.translationTargetLanguage))
        try Task.checkCancellation()
        guard transcriptionGeneration == generation else { throw CancellationError() }

        let translated = TranslationRequest.extract(answer)
        guard !translated.isEmpty else {
            log("translation: agent returned nothing usable")
            hud?.promptFailed(.invalidResult)
            if playSounds { Sounds.playError() }
            return
        }

        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard promptInsertionAllowed(recordedTargetPID: recordedTargetPID,
                                     currentTargetPID: currentPID) else {
            log("translation: target application changed - text not inserted")
            hud?.promptSavedAfterFocusChange(text: translated)
            if playSounds { Sounds.playError() }
            return
        }

        let attempt = TextInserter.insert(translated, targetPID: recordedTargetPID)
        let verdict = await TextInserter.confirmDelivery(attempt)
        recordInsertionVerdict(verdict)
        hud?.promptDeliveryFinished(verdict, text: translated)
        if verdict == .delivered {
            saveInsertedText(translated, besideRawAt: rawURL)
        } else {
            log("translation: text NOT delivered")
        }
        guard playSounds else { return }
        switch dictationFeedbackSound(for: verdict) {
        case .done: Sounds.playDone()
        case .error: Sounds.playError()
        }
    }

    private func generateAndDeliverPrompt(
        rawTranscript: String,
        rawURL: URL,
        recordedTargetPID: pid_t?,
        profile: PromptRecipientProfile,
        generation: UInt64,
        playSounds: Bool
    ) async throws {
        let adapter = settings.promptAgentAdapter
        guard let executableURL = settings.detectPromptAgentExecutable() else {
            throw PromptPipelineError.codexUnavailable
        }
        let model = settings.promptAgentModel
        guard !adapter.requiresModel || !model.isEmpty else {
            throw PromptPipelineError.codexUnavailable
        }

        let builder = PromptEnvelopeBuilder()
        let directory = rawURL.deletingLastPathComponent()
        let markup = builder.analyze(
            rawTranscript,
            hasPreviousPrompt: builder.hasPreviousPrompt(before: directory)
        )
        let result = try await CodexPromptGenerator(
            executableURL: executableURL,
            adapter: adapter,
            model: model
        )
        .generate(
            rawTranscript: rawTranscript,
            markup: markup,
            profile: profile,
            guidance: settings.promptUserGuidance
        )
        try Task.checkCancellation()
        guard transcriptionGeneration == generation else { throw CancellationError() }

        let verification = PromptVerifier().verify(raw: rawTranscript, prompt: result.artifact)
        let blockingIDs = verification.items
            .filter { $0.blocking && $0.verdict == .no }
            .map(\.id)
        guard blockingIDs.isEmpty else {
            // Отклонённый промт не выбрасывается. Владелец потратил на него минуты
            // речи и восемнадцать секунд ожидания; молча стереть работу и показать
            // красное - худший из возможных ответов. Артефакт ложится рядом с сырьём
            // под ОТДЕЛЬНЫМ именем, чтобы его нельзя было спутать с принятым, и вместе
            // с отчётом проверки: без отчёта «почему» остаётся неизвестным навсегда.
            DictationStore.saveRejectedPromptArtifacts(
                artifact: result.artifact,
                report: verification.text,
                besideRawAt: rawURL
            )
            throw PromptPipelineError.verificationFailed(blockingIDs)
        }

        guard try DictationStore.savePromptArtifacts(
            artifact: result.artifact,
            generatedPrompt: result.prompt,
            besideRawAt: rawURL
        ) else {
            throw PromptPipelineError.artifactAlreadyExists
        }

        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard promptInsertionAllowed(recordedTargetPID: recordedTargetPID,
                                     currentTargetPID: currentPID) else {
            log("prompt: target application changed — artifact saved, insertion skipped")
            hud?.promptSavedAfterFocusChange(text: result.prompt)
            if playSounds { Sounds.playError() }
            return
        }

        // Даже если фокус сменится после проверки выше, события адресуются
        // исходному PID, а перед самой отправкой цель проверяется повторно.
        let attempt = TextInserter.insert(result.prompt, targetPID: recordedTargetPID)
        let verdict = await TextInserter.confirmDelivery(attempt)
        recordInsertionVerdict(verdict)
        hud?.promptDeliveryFinished(verdict, text: result.prompt)
        offerRecovery(text: result.prompt, verdict: verdict)
        if verdict == .delivered {
            saveInsertedText(result.prompt, besideRawAt: rawURL)
        } else if case .notDelivered(let failure) = verdict {
            log("prompt: text NOT delivered — \(failure.rawValue)")
        } else {
            log("prompt: delivery verdict unresolved — counted as failure")
        }

        guard playSounds else { return }
        switch dictationFeedbackSound(for: verdict) {
        case .done: Sounds.playDone()
        case .error: Sounds.playError()
        }
    }

    // MARK: - Спасение недоставленного текста

    /// Провал доставки перестаёт быть строкой в логе: текст, который собирались
    /// вставить, возвращается владельцу в окне — скопировать или вставить ещё
    /// раз. Решение «показывать или молчать» целиком в чистой функции
    /// `dictationRecoveryPresentation`, здесь только порядок действий.
    ///
    /// Обе точки вызова (диктовка и промпт) отдают ИМЕННО тот текст, который
    /// уходил в поле. Приложение-получатель сюда не передаётся: его не знает ни
    /// окно, ни лог, ни диск.
    private func offerRecovery(text: String, verdict: TextInsertionVerdict) {
        switch dictationRecoveryPresentation(verdict: verdict,
                                             rescueEnabled: settings.rescueWindowEnabled,
                                             hasText: !text.isEmpty) {
        case .stayQuiet(let reason):
            // Про удачную доставку молчим и в логе: строка «окно не показано,
            // потому что доставлено» была бы в журнале на каждой надиктовке.
            guard verdict != .delivered else { return }
            log("rescue: window not shown — \(reason.rawValue)")
        case .rescueWindow(let failure):
            // Плашка НЕ уходит: она сама и есть спасение. Слова владельца
            // 04.09.2026: «эта плашка трансформируется в зону, где текст
            // напечатан, и я его могу копировать».
            //
            // Прежде отсюда открывалось окно истории: плашка гасла, а поверх
            // всплывало отдельное окно. Связь с только что не доехавшей
            // надиктовкой держалась исключительно в голове владельца, и это
            // читалось как две разные новости подряд вместо одной.
            //
            // Окно истории никуда не делось - в него по-прежнему можно зайти
            // за старыми записями. Оно просто перестало открываться само.
            log("rescue: text shown in the plate — \(failure.rawValue)")
        }
    }

    // MARK: - Учёт доставки и сторож распознавания

    /// Провал записи `inserted.txt` не имеет права уронить доставку: текст уже
    /// в поле, сырьё уже на диске. Причина уходит в лог и на этом всё.
    private func saveInsertedText(_ text: String, besideRawAt rawURL: URL?) {
        guard let rawURL else { return }
        do {
            let written = try DictationStore.saveInsertedText(text, besideRawAt: rawURL)
            if !written {
                log("dictation: inserted.txt already present next to \(rawURL.deletingLastPathComponent().lastPathComponent) — left as is")
            }
        } catch {
            log("dictation: cannot write inserted.txt: \(error.localizedDescription)")
        }
    }

    /// Тайминги токенов рядом с сырьём. Побочный артефакт: любой отказ
    /// уходит в лог и на надиктовку не влияет — текст владельца важнее улики
    /// для будущей фичи.
    private func saveTokenTimings(_ tokens: [DictationTokenTiming],
                                  audioSeconds: Double,
                                  besideRawAt rawURL: URL?) {
        guard let rawURL, !tokens.isEmpty else { return }
        do {
            let written = try DictationStore.saveTokenTimings(
                DictationTimings(audioSeconds: audioSeconds, tokens: tokens),
                besideRawAt: rawURL
            )
            if !written {
                log("dictation: timings.json already present next to \(rawURL.deletingLastPathComponent().lastPathComponent) — left as is")
            }
        } catch {
            log("dictation: cannot write timings.json: \(error.localizedDescription)")
        }
    }

    private func recordInsertionVerdict(_ verdict: TextInsertionVerdict) {
        // Причина пишется рядом с фактом. Три исхода лечатся по-разному:
        // `insertionFailed` - не запустилась ни одна стратегия (права, буфер);
        // `targetNeverRequestedText` - цель не забрала текст за окно ожидания;
        // `deliveryNotObservable` - сработал прямой ввод, наблюдать нечем, и
        // это вообще не отказ, а неизвестность. Сведённые в один булев флаг,
        // они дали владельцу 5,8 % без единой зацепки, что чинить.
        let reason: String?
        switch verdict {
        case .delivered: reason = nil
        case .waiting: reason = "waiting"
        case .notDelivered(let failure): reason = failure.rawValue
        }
        let totals = insertionStats.record(delivered: verdict == .delivered, reason: reason)
        if verdict != .delivered {
            log("dictation: insertion failures \(totals.failures) of \(totals.attempts) attempts"
                + (reason.map { ", reason \($0)" } ?? ""))
        }
    }

    /// Зависший ASR не должен убивать диктовку до перезапуска приложения:
    /// раньше `isBusy` снимался только в defer завершившейся задачи.
    private func scheduleTranscriptionWatchdog(generation: UInt64,
                                               clipSeconds: Double,
                                               playSounds: Bool) {
        transcriptionWatchdog?.cancel()
        let timeout = resolvedTranscriptionTimeout(clipSeconds: clipSeconds)
        transcriptionWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.transcriptionTimedOut(generation: generation,
                                       clipSeconds: clipSeconds,
                                       timeout: timeout,
                                       playSounds: playSounds)
        }
    }

    private func resolvedTranscriptionTimeout(clipSeconds: Double) -> Double {
        transcriptionTimeoutOverride ?? transcriptionTimeoutSeconds(clipSeconds: clipSeconds)
    }

    private func transcriptionTimedOut(generation: UInt64,
                                       clipSeconds: Double,
                                       timeout: Double,
                                       playSounds: Bool) {
        guard transcriptionGeneration == generation else { return }
        // Попытка помечается брошенной и получает отмену. Если ASR уже закончил
        // вычисление и всё же вернёт результат, сырьё ещё сохранится, но
        // проверка поколения не даст вставить текст в давно сменившийся фокус.
        transcriptionGeneration &+= 1
        transcriptionWatchdog = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        isBusy = false
        // Плашка ДО `state = .ready`, как на путях `nothingRecognized` и
        // `deliveryFinished`. В обратном порядке нетерминальная «распознаю»
        // гаснет (`orderOut` + сброс запомненного экрана), и панель поднимается
        // заново в том же такте: мигание, а на двух мониторах — переезд плашки
        // на другой экран, потому что экран под курсором пересчитывается.
        hud?.recognitionTimedOut()
        if case .transcribing = state { state = .ready }
        log(String(format: "dictation: transcription timed out after %.1f s for %.1f s clip — dictation unblocked",
                   timeout, clipSeconds))
        if playSounds { Sounds.playError() }
    }

    private func finishTranscription(generation: UInt64) {
        // Сторож уже закрыл эту попытку — не трогаем состояние следующей.
        guard transcriptionGeneration == generation else { return }
        transcriptionWatchdog?.cancel()
        transcriptionWatchdog = nil
        pipelineTask = nil
        isBusy = false
        switch state {
        case .transcribing, .generatingPrompt:
            state = .ready
        default:
            break
        }
    }

    private func handleCancel() {
        guard isRecording else { return }
        isRecording = false
        maxDurationTask?.cancel()
        maxDurationTask = nil
        _ = audio.endRecording()
        recordingPurpose = .dictation
        recordedTargetPID = nil
        recordedPromptProfile = nil
        // Toggle-автомат о Escape не знает — состояние сбрасываем сами.
        hotkeys.resetToggleState()
        state = .ready
        log("dictation cancelled by Escape")
    }

    private func scheduleMaxDurationAutoRelease() {
        maxDurationTask?.cancel()
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MAX_RECORDING_SECONDS) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.isRecording else { return }
            log("dictation: max recording duration reached — auto release")
            self.hotkeys.resetToggleState()
            self.handleRelease(shortcut: .standard,
                               hotkeyDetectedAt: ProcessInfo.processInfo.systemUptime)
        }
    }

    #if DEBUG
    func simulateActiveRecordingForTesting() {
        audio.beginRecording()
        isRecording = true
        state = .recording
    }

    var audioStateForTesting: (isRunning: Bool, isEngineStarted: Bool) {
        (audio.isRunning, audio.isEngineStarted)
    }

    var isSuspendedForSystemSleepForTesting: Bool {
        powerLifecycle.isSuspended
    }

    /// Тестовая опора: заводит попытку распознавания, которая никогда не
    /// вернётся. Живой ASR под `swift test` недоступен (модели нет, TCC нет) —
    /// как и в AudioCapture, факт решения наблюдается опорой, а не железом.
    func simulateHungTranscriptionForTesting(clipSeconds: Double) {
        transcriptionGeneration &+= 1
        isBusy = true
        state = .transcribing
        scheduleTranscriptionWatchdog(generation: transcriptionGeneration,
                                      clipSeconds: clipSeconds,
                                      playSounds: false)
    }

    var isBusyForTesting: Bool { isBusy }

    var promptSettingsForTesting: (hotkey: HotkeyChoice, enabled: Bool, codexPath: String) {
        (
            hotkeys.promptHotkey,
            hotkeys.promptHotkeyEnabled,
            settings.promptAgentPath(for: settings.promptAgentID)
        )
    }

    func transcriptionTimeoutForTesting(clipSeconds: Double) -> Double {
        resolvedTranscriptionTimeout(clipSeconds: clipSeconds)
    }
    #endif
}

private final class NotificationObserver: @unchecked Sendable {
    let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

enum PromptPipelineError: Error {
    /// Выбранный агент не настроен: исполняемый файл не найден либо не задана
    /// обязательная модель. Имя случая осталось прежним, чтобы не тревожить
    /// стабильные точки в тестах и логах.
    case codexUnavailable
    case artifactAlreadyExists
    case verificationFailed([String])
}

/// Единственная граница между богатыми ошибками конвейера и HUD/логом.
/// Текст stderr, внешний ответ и идентификаторы проверки дальше не проходят.
func promptFailureKind(for error: any Error) -> PromptFailureKind {
    if let error = error as? PromptPipelineError {
        switch error {
        case .codexUnavailable: return .executableConfiguration
        case .artifactAlreadyExists: return .artifactConflict
        case .verificationFailed: return .invalidResult
        }
    }
    guard let error = error as? CodexPromptGeneratorError else { return .launchRuntime }
    switch error {
    case .invalidExecutable:
        return .executableConfiguration
    case .invalidTimeout, .temporaryDirectoryUnavailable, .privateFilePreparationFailed,
         .launchFailed, .nonZeroExit, .terminated:
        return .launchRuntime
    case .timedOut:
        return .timeout
    case .missingResult, .resultTooLarge, .invalidResultJSON, .invalidPromptSpec,
         .invalidPromptOutcome, .renderingFailed:
        return .invalidResult
    }
}

func safePromptFailureLogLabel(for error: any Error) -> String {
    if let error = error as? PromptPipelineError {
        switch error {
        case .codexUnavailable: return "agent unavailable"
        case .artifactAlreadyExists: return "prompt artifact already exists"
        case .verificationFailed(let ids):
            // Без пунктов красный вердикт неотличим от любого другого и чинить
            // нечего: владелец видел «verification failed» и не мог узнать, что
            // именно не сошлось. Но тип случая - обычный `[String]`, и ничто в
            // нём не мешает однажды принести туда чужой текст. Поэтому наружу
            // идут только строки ФОРМЫ идентификатора проверки («Б1»…«Б14»);
            // всё прочее молча отбрасывается, и граница остаётся закрытой.
            let safe = ids.filter { id in
                guard let first = id.first, first == "Б" else { return false }
                let rest = id.dropFirst()
                return !rest.isEmpty && rest.count <= 2 && rest.allSatisfy(\.isNumber)
            }
            return safe.isEmpty
                ? "verification failed"
                : "verification failed — \(safe.joined(separator: ", "))"
        }
    }
    guard let error = error as? CodexPromptGeneratorError else {
        return "unexpected prompt failure"
    }
    switch error {
    case .invalidExecutable: return "invalid executable"
    case .invalidTimeout: return "invalid timeout"
    case .temporaryDirectoryUnavailable: return "temporary directory unavailable"
    case .privateFilePreparationFailed: return "private file preparation failed"
    case .launchFailed: return "launch failed"
    case .nonZeroExit(let status, _): return "non-zero exit \(status)"
    case .terminated(let signal, _): return "terminated by signal \(signal)"
    case .timedOut: return "timed out"
    case .missingResult: return "missing result"
    case .resultTooLarge: return "result too large"
    case .invalidResultJSON: return "invalid result JSON"
    case .invalidPromptSpec: return "invalid PromptSpec"
    case .invalidPromptOutcome: return "invalid prompt outcome"
    case .renderingFailed: return "rendering failed"
    }
}
