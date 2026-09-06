// Решения конвейера доставки надиктовки — свой код, чистые функции без AppKit.
//
// Почему отдельным файлом: живой буфер обмена, живой ASR и защищённый ввод
// под `swift test` недоступны, поэтому все РЕШЕНИЯ вынесены сюда, а в
// DictationController остаётся только обвязка, которая их зовёт. Тестами
// покрываются функции этого файла.
import Foundation

enum DictationRecordingPurpose: Equatable {
    case dictation
    case prompt
    /// Говоришь по-русски, вставляется по-английски. Отдельный режим, а не
    /// настройка обычной диктовки: у него своя клавиша, свой цвет и свой
    /// исход, и путать его с диктовкой нельзя - вставленный не тот язык
    /// замечают не сразу, а исправлять поздно.
    case translation
    /// Запись встречи или заседания. Отдельный режим, а не настройка диктовки,
    /// и это требование владельца: «нужно как-то выделять отдельно, чтобы было
    /// видно по цвету, что идёт работа по записи встречи».
    ///
    /// Цена путаницы несимметрична и потому цвет отдельный: диктовку, принятую
    /// за встречу, человек заметит по лишнему файлу; встречу, принятую за
    /// диктовку, он заметит тогда, когда запись заседания не сохранилась.
    case meeting
}

/// Enter относится только к обычной диктовке. Промпт всегда сначала попадает
/// в поле как черновик: приложение никогда не отправляет его автоматически.
func shouldPressEnterAfterVoiceOutput(
    purpose: DictationRecordingPurpose,
    shortcut: DictationReleaseShortcut,
    primaryBehavior: DictationCompletionBehavior
) -> Bool {
    guard purpose == .dictation else { return false }
    return shouldPressEnterAfterDictation(shortcut: shortcut,
                                          primaryBehavior: primaryBehavior)
}

// MARK: - Подтверждение доставки текста

/// Окно подтверждения доставки: за столько цель обязана запросить текст
/// у ленивого провайдера буфера обмена. ⌘V доходит до фокусного поля за
/// десятки миллисекунд, так что 0,4 с — заведомый запас; десять секунд
/// ждать нельзя, владелец за это время уже ушёл.
let INSERTION_DELIVERY_WINDOW_SECONDS: TimeInterval = 0.4

/// Почему доставка не подтверждена. Строка идёт в лог и объясняет владельцу
/// (через лог) конкретный класс провала, а не общее «не получилось».
/// `CaseIterable` — чтобы тест решения об окне спасения бежал по ВСЕМ классам
/// провала, а не по тем трём, что вспомнил автор теста: новый класс провала без
/// решения «показывать окно или молчать» обязан ронять гейт.
enum TextInsertionFailure: String, Equatable, CaseIterable {
    /// Ни одна стратегия вставки не запустилась: буфер обмена или события отказали.
    case insertionFailed
    /// Стратегия запустилась, но цель так и не запросила текст за окно ожидания.
    case targetNeverRequestedText
    /// Сработал прямой ввод юникодом — там факт забора текста наблюдать нечем.
    case deliveryNotObservable
}

/// Вердикт доставки. `waiting` — окно ещё не истекло, надо подождать ещё.
enum TextInsertionVerdict: Equatable {
    case delivered
    case waiting
    case notDelivered(TextInsertionFailure)
}

/// Вердикт по наблюдаемым фактам: какая стратегия запустилась, запросила ли
/// цель текст и сколько прошло с момента отправки ⌘V.
///
/// Ключевой момент: «мы отправили ⌘V» — НЕ доставка. Доставка — это когда
/// цель сама запросила данные у провайдера буфера обмена.
func textInsertionVerdict(startedStrategy: TextInsertionStrategy?,
                          targetRequestedText: Bool,
                          elapsed: TimeInterval,
                          window: TimeInterval = INSERTION_DELIVERY_WINDOW_SECONDS) -> TextInsertionVerdict {
    guard let startedStrategy else { return .notDelivered(.insertionFailed) }
    if targetRequestedText { return .delivered }
    guard startedStrategy == .clipboardPaste else {
        return .notDelivered(.deliveryNotObservable)
    }
    let deadline = max(0, window)
    guard elapsed.isFinite else { return .notDelivered(.targetNeverRequestedText) }
    return elapsed >= deadline ? .notDelivered(.targetNeverRequestedText) : .waiting
}

/// Звук по вердикту. Здесь и живёт главное обещание этапа: «готово» звучит
/// ТОЛЬКО при подтверждённой доставке, во всех остальных исходах — отказ.
enum DictationFeedbackSound: String, Equatable {
    case done
    case error
}

func dictationFeedbackSound(for verdict: TextInsertionVerdict) -> DictationFeedbackSound {
    switch verdict {
    case .delivered:
        return .done
    case .waiting, .notDelivered:
        return .error
    }
}

// MARK: - Порядок конвейера после распознавания

/// Что делать с результатом распознавания. Сырьё сохраняется НЕЗАВИСИМО от
/// того, осталось ли что вставлять: обработка умеет вернуть пустую строку
/// (trim, снятие `<unk>`, замены), и раньше в этом случае надиктовка не
/// сохранялась вообще — владелец говорил, а файла не появлялось.
struct DictationDeliveryPlan: Equatable {
    let savesRawText: Bool
    let insertsText: Bool
}

func dictationDeliveryPlan(rawTranscript: String, processedText: String) -> DictationDeliveryPlan {
    // Пустой ответ ASR (молчание, случайное касание) каталога не заводит —
    // иначе на диске владельца копился бы мусор из пустых raw.txt.
    DictationDeliveryPlan(savesRawText: !rawTranscript.isEmpty,
                          insertsText: !processedText.isEmpty)
}

/// Codex может собирать промпт десятки секунд. За это время фокус способен
/// уехать в другое приложение; вставлять туда результат нельзя. Неизвестный
/// PID тоже не считается разрешением — безопасный исход: сохранить в истории.
func promptInsertionAllowed(recordedTargetPID: pid_t?, currentTargetPID: pid_t?) -> Bool {
    guard let recordedTargetPID, let currentTargetPID else { return false }
    return recordedTargetPID == currentTargetPID
}

/// Обычная диктовка следует текущему фокусу (`expectedTargetPID == nil`).
/// Промпт-режим закрепляет доставку за приложением, где началась запись.
func textInsertionTargetAllowsPosting(expectedTargetPID: pid_t?, currentTargetPID: pid_t?) -> Bool {
    guard let expectedTargetPID else { return true }
    return promptInsertionAllowed(recordedTargetPID: expectedTargetPID,
                                  currentTargetPID: currentTargetPID)
}

// MARK: - Таймаут распознавания

/// Множитель реального времени для таймаута распознавания. Parakeet TDT v3
/// на ANE идёт примерно ×0,1 реального времени, так что ×4 — запас, который
/// не пережимает даже холодный первый прогон.
let TRANSCRIPTION_TIMEOUT_REALTIME_FACTOR: Double = 4
/// Пол таймаута: короткая фраза всё равно ждёт разумный минимум.
let TRANSCRIPTION_TIMEOUT_MINIMUM_SECONDS: Double = 5
/// Потолок: двадцатиминутная запись не должна держать диктовку мёртвой час.
let TRANSCRIPTION_TIMEOUT_MAXIMUM_SECONDS: Double = 300

/// Сколько ждать распознавание клипа такой длительности. Именно от клипа, а
/// не константой: короткая фраза и десятиминутный диктант не могут ждать
/// одинаково.
func transcriptionTimeoutSeconds(
    clipSeconds: Double,
    realtimeFactor: Double = TRANSCRIPTION_TIMEOUT_REALTIME_FACTOR,
    minimum: Double = TRANSCRIPTION_TIMEOUT_MINIMUM_SECONDS,
    maximum: Double = TRANSCRIPTION_TIMEOUT_MAXIMUM_SECONDS
) -> Double {
    let floorSeconds = max(0, minimum)
    let ceilingSeconds = max(floorSeconds, maximum)
    guard clipSeconds.isFinite, clipSeconds > 0, realtimeFactor.isFinite, realtimeFactor > 0 else {
        return floorSeconds
    }
    return min(ceilingSeconds, max(floorSeconds, clipSeconds * realtimeFactor))
}

/// Сколько ждать прогрев модели, если владелец начал говорить раньше.
///
/// Три минуты: первая загрузка Whisper после перезагрузки macOS шла 85 секунд
/// на машине владельца, и запас нужен вдвое. Дольше - это уже не прогрев, а
/// поломка, и честная ошибка полезнее вечного ожидания.
let dictationWarmUpWaitLimitSeconds: Double = 180

// MARK: - Отказ старта записи

/// Почему запись не стартует. `secureInputActive` — новый класс отказа:
/// в поле пароля синтетический ⌘V не дойдёт всё равно, честнее сказать сразу.
enum DictationStartRefusal: String, Equatable {
    case secureInputActive
    case modelNotReady
    case alreadyRecording
    case transcriptionInFlight
}

/// Отказать ли старту.
///
/// `modelWarming` отделяет «модель ещё грузится» от «модели нет». Разница
/// стоила владельцу рабочего утра: после перезагрузки macOS сбрасывает
/// скомпилированный кэш CoreML, первая загрузка Whisper идёт до полутора минут,
/// и всё это время каждое нажатие отбивалось - 24 отказа подряд в логе.
///
/// ЗАПИСЬ МОДЕЛИ НЕ ТРЕБУЕТ. Модель нужна расшифровке, которая идёт ПОСЛЕ.
/// Поэтому пока модель грузится, запись начинается как обычно, а расшифровка
/// дожидается загрузки. Отказ остаётся только там, где распознавать нечем
/// вообще: модель не скачана или сломана.
func dictationStartRefusal(modelReady: Bool,
                           isRecording: Bool,
                           isBusy: Bool,
                           secureInputActive: Bool,
                           modelWarming: Bool = false) -> DictationStartRefusal? {
    if secureInputActive { return .secureInputActive }
    if !modelReady, !modelWarming { return .modelNotReady }
    if isRecording { return .alreadyRecording }
    if isBusy { return .transcriptionInFlight }
    return nil
}
