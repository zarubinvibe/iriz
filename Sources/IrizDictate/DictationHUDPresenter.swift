// Порядок показа плашки «идёт голос»: что и когда попадает на экран.
//
// Здесь нет ни AppKit, ни решений — решения в DictationHUD.swift, рисование в
// DictationHUDWindow.swift. Такое разделение позволяет проверить тестом всё
// поведение (что показали, что погасили, крутится ли опрос уровня), ни разу не
// поднимая живое окно: под `swift test` его и не поднять.
import Foundation

/// Поверхность, на которой плашка рисуется. Единственная реализация в продукте —
/// `DictationHUDPanelSurface` (NSPanel). В тестах подставляется запоминающая
/// заглушка.
@MainActor
protocol DictationHUDSurface: AnyObject {
    func present(_ content: DictationHUDContent)
    func updateHintLines(_ lines: [String])
    func dismiss()
    /// Собрать всё, что можно собрать заранее, НЕ показывая плашку.
    func prewarm()
    /// Кого звать, когда владелец забрал не доехавший текст.
    func setTranscriptCopiedHandler(_ handler: @escaping () -> Void)
}

extension DictationHUDSurface {
    func updateHintLines(_ lines: [String]) {}
    func prewarm() {}
    func setTranscriptCopiedHandler(_ handler: @escaping () -> Void) {}
}

/// Режим run loop для ОБОИХ таймеров плашки.
///
/// `.common`, не `.default`: таймер в режиме `.default` не срабатывает, пока
/// крутится вложенный цикл отслеживания — открыто любое меню (включая наше же
/// в строке меню) или зажата кнопка мыши на протяжке. С `.default` терминальную
/// плашку было нечем снять с экрана, пока меню открыто (гасит её только таймер:
/// `.ready` терминальную плашку не трогает намеренно), а индикатор уровня
/// замирал ровно тогда, когда владелец что-то тащит и диктует.
let DICTATION_HUD_TIMER_MODE: RunLoop.Mode = .common

/// Единственное место, где заводятся таймеры плашки: режим обязан быть один и
/// тот же у опроса уровня и у гашения, поэтому он тут, а не на двух вызовах.
@MainActor
func dictationHUDTimer(after interval: TimeInterval,
                       repeats: Bool,
                       _ body: @escaping @MainActor () -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
        // Таймер добавлен в RunLoop.main ниже, то есть блок и так вызывается на
        // главном потоке — изоляция здесь фактическая, а не обещанная (тем же
        // приёмом, что крючок смены аудиоустройства). Без лишнего перескока
        // через `Task` тик приходит ровно в свой такт цикла.
        MainActor.assumeIsolated { body() }
    }
    RunLoop.main.add(timer, forMode: DICTATION_HUD_TIMER_MODE)
    return timer
}

/// Опрос уровня голоса. Отдельным типом, чтобы «таймер гасится вне записи»
/// проверялось прямо, а не через живое окно.
@MainActor
final class DictationHUDLevelPump {
    private let interval: TimeInterval
    private var timer: Timer?

    var onTick: (() -> Void)?

    init(interval: TimeInterval = DICTATION_HUD_LEVEL_POLL_SECONDS) {
        self.interval = interval
    }

    var isRunning: Bool { timer?.isValid == true }

    /// Идемпотентно: повторный `true` не заводит второй таймер, повторный
    /// `false` не падает.
    func setRunning(_ shouldRun: Bool) {
        guard shouldRun else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timer = dictationHUDTimer(after: interval, repeats: true) { [weak self] in
            self?.onTick?()
        }
    }
}

@MainActor
final class DictationHUDPresenter {
    private let makeSurface: () -> DictationHUDSurface
    private let levelSnapshot: () -> (level: Float, sequence: UInt64)
    private let staleGuardEnabled: Bool
    /// Состояние конвейера СЕЙЧАС, а не то, что презентер показал последним.
    /// Без этого «погасить по таймеру» было безусловным, и истёкшая плашка
    /// отказа оставляла пустой экран посреди идущего распознавания.
    private let pipelineState: () -> DictationController.State
    /// Режим ИДУЩЕЙ записи. Спрашивается ровно в момент, когда строится стадия
    /// `.listening`, и дальше живёт в ней значением: контроллер обнуляет
    /// `recordingPurpose` на отпускании клавиши, и поздний опрос соврал бы.
    private let recordingPurpose: () -> DictationRecordingPurpose
    private let reduceMotion: () -> Bool
    private let historyHint: () -> String
    private let triggerMode: () -> TriggerMode
    private let activeHotkeyHint: () -> String
    private let showsDragHint: () -> Bool
    private let pump: DictationHUDLevelPump

    private var surface: DictationHUDSurface?
    private var dismissTimer: Timer?
    private var smoothedLevel: Float = 0
    private var lastLevelSequence: UInt64?
    private var sameLevelSequenceTicks = 0

    /// Что сейчас на экране. `nil` — плашки нет.
    private(set) var stage: DictationHUDStage?

    var isPollingLevel: Bool { pump.isRunning }

    init(levelSnapshot: @escaping () -> (level: Float, sequence: UInt64),
         pipelineState: @escaping () -> DictationController.State,
         historyHint: @escaping () -> String,
         triggerMode: @escaping () -> TriggerMode,
         activeHotkeyHint: @escaping () -> String,
         showsDragHint: @escaping () -> Bool,
         recordingPurpose: @escaping () -> DictationRecordingPurpose = { .dictation },
         reduceMotion: @escaping () -> Bool = { dictationHUDReduceMotionEnabled() },
         pump: DictationHUDLevelPump = DictationHUDLevelPump(),
         surface: @escaping () -> DictationHUDSurface = { DictationHUDPanelSurface() }) {
        self.levelSnapshot = levelSnapshot
        self.staleGuardEnabled = true
        self.pipelineState = pipelineState
        self.historyHint = historyHint
        self.triggerMode = triggerMode
        self.activeHotkeyHint = activeHotkeyHint
        self.showsDragHint = showsDragHint
        self.recordingPurpose = recordingPurpose
        self.reduceMotion = reduceMotion
        self.pump = pump
        self.makeSurface = surface
        pump.onTick = { [weak self] in self?.render() }
    }

    /// Совместимость тестов и простых поверхностей без sequence. Живой продукт
    /// использует initializer выше и включает сторож залипшего аудиопотока.
    init(level: @escaping () -> Float,
         pipelineState: @escaping () -> DictationController.State,
         historyHint: @escaping () -> String,
         recordingPurpose: @escaping () -> DictationRecordingPurpose = { .dictation },
         reduceMotion: @escaping () -> Bool = { dictationHUDReduceMotionEnabled() },
         pump: DictationHUDLevelPump = DictationHUDLevelPump(),
         surface: @escaping () -> DictationHUDSurface = { DictationHUDPanelSurface() }) {
        self.levelSnapshot = { (level(), 0) }
        self.staleGuardEnabled = false
        self.pipelineState = pipelineState
        self.historyHint = historyHint
        self.triggerMode = { .toggle }
        self.activeHotkeyHint = { "" }
        self.showsDragHint = { false }
        self.recordingPurpose = recordingPurpose
        self.reduceMotion = reduceMotion
        self.pump = pump
        self.makeSurface = surface
        pump.onTick = { [weak self] in self?.render() }
    }

    // MARK: - Входы конвейера

    func pipelineStateChanged(_ state: DictationController.State) {
        // Смена состояния конвейера — эхо, а не новость: `.ready` приходит
        // следом за вердиктом и не имеет права заводить отсчёт заново, иначе
        // терминальная плашка жила бы дольше положенного.
        apply(dictationHUDPresentation(pipelineState: state,
                                       purpose: recordingPurpose(),
                                       current: stage),
              isFreshEvent: false)
    }

    func startRefused(_ refusal: DictationStartRefusal) {
        // `nil` — «оставить как есть»: живую панель отказ не сносит.
        guard let stage = dictationHUDStage(forStartRefusal: refusal) else { return }
        apply(.visible(stage))
    }

    /// `text` - то, что уходило в поле. Нужен ровно для одного: если текст не
    /// доехал, плашка развернётся в панель и покажет его. Пустая строка тут
    /// законна - тогда панели не будет, и это правильно: обещать текст,
    /// которого нет, хуже молчания.
    func deliveryFinished(_ verdict: TextInsertionVerdict, text: String = "") {
        undelivered = text.isEmpty ? nil : text
        apply(.visible(dictationHUDStage(forDeliveryVerdict: verdict)))
    }

    func nothingRecognized(savedToHistory: Bool) {
        apply(.visible(.nothingRecognized(savedToHistory: savedToHistory)))
    }

    func recognitionTimedOut() {
        apply(.visible(.recognitionTimedOut))
    }

    /// Распознавание упало. Уже сказанный исход не перебиваем: ошибка после
    /// вердикта доставки («вставил») или после сторожа («не успел распознать»)
    /// относится к хвосту задачи, а не к надиктовке, и заменять ею верное
    /// сообщение — врать.
    func recognitionFailed(savedToHistory: Bool) {
        if let stage, dictationHUDStageIsTerminal(stage) { return }
        apply(.visible(.recognitionFailed(savedToHistory: savedToHistory)))
    }

    func promptFailed(_ kind: PromptFailureKind) {
        if let stage, dictationHUDStageIsTerminal(stage) { return }
        apply(.visible(.promptFailed(kind)))
    }

    func promptDeliveryFinished(_ verdict: TextInsertionVerdict, text: String = "") {
        undelivered = text.isEmpty ? nil : text
        apply(.visible(dictationHUDStage(forPromptDeliveryVerdict: verdict)))
    }

    func promptSavedAfterFocusChange(text: String = "") {
        undelivered = text.isEmpty ? nil : text
        apply(.visible(.promptSavedAfterFocusChange))
    }

    /// Собрать поверхность заранее — со старта приложения, а не с первого
    /// нажатия. Плашка при этом не показывается: см. `prewarm()` поверхности.
    ///
    /// Стадии не трогает: пока владелец не заговорил, показывать нечего,
    /// и прогрев не имеет права выглядеть показом.
    func prewarm() {
        presentingSurface().prewarm()
    }

    /// Снять плашку немедленно, не дожидаясь её таймера.
    ///
    /// Нужна ровно одному вызывающему: окно спасения. Плашка и окно говорят про
    /// один и тот же провал, и оставить их вдвоём на экране — сказать владельцу
    /// одно и то же дважды разными словами, причём плашка висит поверх окна и
    /// гаснет посреди чтения. Гасим ДО показа окна: окно зовёт NSApp.activate,
    /// и порядок «сначала убрать, потом поднять» не даёт мигнуть.
    func dismiss() {
        hide()
    }

    // MARK: - Показ и гашение

    /// `isFreshEvent` — случилось новое событие, а не эхо состояния. Второе
    /// нажатие на непрогретую модель повторяет тот же отказ, и отсчёт «сколько
    /// плашке жить» обязан пойти заново: иначе она погаснет по таймеру первого
    /// нажатия, ровно когда владелец нажал второй раз.
    private func apply(_ presentation: DictationHUDPresentation, isFreshEvent: Bool = true) {
        switch presentation {
        case .hidden:
            hide()
        case .visible(let newStage):
            let changed = newStage != stage
            if changed, dictationHUDIsListening(newStage) { resetLevelState() }
            stage = newStage
            // Опрос уровня заводится только под запись и гаснет на любом другом
            // состоянии — иначе он молотил бы 20 раз в секунду на пустом экране.
            pump.setRunning(dictationHUDPollsLevel(newStage))
            if changed || isFreshEvent { scheduleDismiss(for: newStage) }
            render()
        }
    }

    private func hide() {
        stage = nil
        pump.setRunning(false)
        resetLevelState()
        cancelDismiss()
        surface?.dismiss()
    }

    /// Текст, который не доехал. Живёт до следующей записи: плашка с панелью
    /// стоит на экране дольше обычной, и потерять текст, пока владелец до него
    /// тянется, нельзя.
    private var undelivered: String?

    /// Текст забрали - плашке больше нечего держать. Гасим и забываем текст:
    /// иначе следующая же перерисовка подняла бы панель заново.
    private func transcriptTaken() {
        undelivered = nil
        hide()
    }

    private func render() {
        guard let stage else { return }
        let historyLabel = historyHint()
        let level = dictationHUDIsListening(stage) ? nextSmoothedLevel() : 0
        let reduceMotion = reduceMotion()
        let content = dictationHUDContent(stage: stage,
                                          level: level,
                                          reduceMotion: reduceMotion,
                                          historyHint: historyLabel,
                                          transcript: undelivered)
        let surface = presentingSurface()
        surface.updateHintLines(dictationHUDHintLines(
            stage: stage,
            triggerMode: triggerMode(),
            hotkeyLabel: activeHotkeyHint(),
            historyLabel: historyLabel,
            showsDragHint: showsDragHint()
        ))
        surface.present(content)
    }

    private func nextSmoothedLevel() -> Float {
        let snapshot = levelSnapshot()
        if staleGuardEnabled {
            if lastLevelSequence == snapshot.sequence {
                sameLevelSequenceTicks += 1
            } else {
                lastLevelSequence = snapshot.sequence
                sameLevelSequenceTicks = 0
            }
        }
        let raw = staleGuardEnabled && dictationHUDLevelIsStale(sameSequenceTicks: sameLevelSequenceTicks)
            ? 0
            : snapshot.level
        smoothedLevel = dictationHUDSmoothedLevel(previous: smoothedLevel, raw: raw)
        return smoothedLevel
    }

    private func resetLevelState() {
        smoothedLevel = 0
        lastLevelSequence = nil
        sameLevelSequenceTicks = 0
    }

    /// Поверхность заводится по первому обращению — и обращением этим в живом
    /// приложении оказывается `prewarm()` со старта, а не первое нажатие.
    /// Ленивость осталась ради тестов и ради того, что порядок сборки
    /// определяет вызывающий, а не init презентера.
    private func presentingSurface() -> DictationHUDSurface {
        if let surface { return surface }
        let created = makeSurface()
        created.setTranscriptCopiedHandler { [weak self] in self?.transcriptTaken() }
        surface = created
        return created
    }

    private func scheduleDismiss(for stage: DictationHUDStage) {
        cancelDismiss()
        guard let delay = dictationHUDDismissDelay(for: stage) else { return }
        dismissTimer = dictationHUDTimer(after: delay, repeats: false) { [weak self] in
            self?.dismissIfStillShowing(stage)
        }
    }

    /// Время плашки истекло — но гасить безусловно нельзя: конвейер мог за это
    /// время никуда не уйти. Пересчитываем от СОСТОЯНИЯ, а не от того, что было
    /// показано: после истёкшего отказа «ещё распознаю прошлую» на экран
    /// возвращается «распознаю»/«слушаю», а на покое плашка честно уходит.
    /// `current: nil` — истёкшую терминальную плашку заново не удерживаем.
    ///
    /// Не `private`: под `swift test` run loop не бежит и живой таймер не
    /// стреляет, поэтому тик гашения тесты дёргают руками — тем же приёмом, что
    /// тик опроса уровня через `pump.onTick`.
    func dismissIfStillShowing(_ expected: DictationHUDStage) {
        guard stage == expected else { return }
        apply(dictationHUDPresentation(pipelineState: pipelineState(),
                                       purpose: recordingPurpose(),
                                       current: nil),
              isFreshEvent: false)
    }

    private func cancelDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }
}
