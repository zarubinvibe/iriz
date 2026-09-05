import AppKit
import IrizCore
import Combine
import Foundation
import IrizDictate

/// Режим работы: одна ось с тремя значениями (VISUAL_SPEC §6.3) вместо трёх
/// независимых тумблеров. Отображение на пару флагов SettingsManager:
/// fixing = autoSwitch on + shadow off · shadow = on + on · paused = off.
enum AppMode: String, CaseIterable, Identifiable {
    case fixing, shadow, paused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixing: return "Исправляет"
        case .shadow: return "Только считает"
        case .paused: return "Пауза"
        }
    }

    var markMode: MarkMode {
        switch self {
        case .fixing: return .fixing
        case .shadow: return .shadow
        case .paused: return .paused
        }
    }
}

/// Состояние знака и меню строки меню. Обновляет AppDelegate, читают SwiftUI-вьюхи.
@MainActor
final class MenuState: ObservableObject {
    struct LayoutEntry: Identifiable {
        let id: String
        let name: String
        let isCurrent: Bool
    }

    /// Состояние знака: нагрузка + альфа зон + авария (см. IrizMark.swift).
    @Published var mark = MarkState(mode: .fixing, alarm: .none) {
        didSet { updateWaveAnimation() }
    }
    /// Универсальный доступ и Мониторинг ввода: без них нет раскладки. Флага два,
    /// потому что меню обязано назвать, какое именно разрешение чинить, — «нет
    /// доступа» вообще отправляет владельца искать наугад в трёх панелях системы.
    @Published var accessibilityOK = false
    @Published var inputMonitoringOK = false
    /// Микрофон: без него нет диктовки, но раскладка работает. Разрешения отваливаются
    /// независимо, поэтому и флага два.
    @Published var microphoneOK = false
    /// Жив ли наш тап клавиатуры. Система отключает его при таймауте
    /// обработчика; обычно он поднимается обратно, но если не поднялся -
    /// раскладка молча перестаёт исправляться, и это обязано быть видно.
    @Published var inputTapOK = true {
        didSet { guard inputTapOK != oldValue else { return }; updateWaveAnimation() }
    }
    @Published var layouts: [LayoutEntry] = []
    @Published var currentLayoutID = ""
    @Published var currentLayoutName = ""
    @Published var mode: AppMode = .fixing
    @Published var todayAutoswitches = 0
    @Published var todayUndos = 0
    /// Состояние конвейера диктовки как есть: меню показывает клавишу только
    /// тогда, когда она сработает.
    @Published var dictationState: DictationController.State = .warmingUp

    /// Раскладка работает, только когда выданы оба разрешения.
    var permissionsOK: Bool { accessibilityOK && inputMonitoringOK }

    /// Версия из бандла — показывается в окне настроек, не в меню.
    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Заголовок меню — крупный и первый. Отвечает на «что сейчас», а не «что это»:
    /// пока идёт речь, слот принадлежит диктовке (VISUAL_SPEC §4), и режим раскладки
    /// в этот момент не то, чем приложение занято.
    var heroTitle: String {
        mark.mode == .dictating ? "Слушает" : mode.title
    }

    /// Хвост заголовка вторым весом: «· Русская». Пусто, пока раскладка неизвестна.
    var heroDetail: String {
        if mark.mode == .dictating { return " · речь в текст" }
        return currentLayoutName.isEmpty ? "" : " · \(currentLayoutName)"
    }

    /// Строка статистики: «Сегодня: 128 исправлений · 4 отмены».
    /// В «Только считает» правок не было вовсе — то же число там значит
    /// «столько ошибок замечено», и называть его исправлениями было бы враньём.
    var statsLine: String {
        let counted = mode == .shadow
            ? "\(todayAutoswitches) \(Self.plural(todayAutoswitches, one: "ошибка раскладки", few: "ошибки раскладки", many: "ошибок раскладки"))"
            : "\(todayAutoswitches) \(Self.plural(todayAutoswitches, one: "исправление", few: "исправления", many: "исправлений"))"
        return "Сегодня: \(counted)"
            + " · \(todayUndos) \(Self.plural(todayUndos, one: "отмена", few: "отмены", many: "отмен"))"
    }

    /// Что показывать в правой колонке строки «Диктовка»: либо клавишу (сработает),
    /// либо причину, по которой сейчас не сработает. Никогда и то и другое —
    /// клавиша рядом с неработающей функцией и есть обещание впустую.
    enum DictationHint: Equatable {
        case key
        case note(String)
        case fault(String)
    }

    var dictationHint: DictationHint {
        if !microphoneOK { return .fault("нет доступа к микрофону") }
        switch dictationState {
        case .warmingUp: return .note("прогревается")
        case .ready: return .key
        case .recording: return .note("идёт запись")
        case .transcribing: return .note("расшифровывает")
        case .generatingPrompt: return .note("собирает промпт")
        case .unavailable(let reason): return .fault(reason)
        }
    }

    /// Строка про разрешения нужна, только когда есть что чинить: об исправности
    /// не докладывают (VISUAL_SPEC §6.2).
    var permissionAlarm: String? {
        if !accessibilityOK { return "Нет доступа к Универсальному доступу" }
        if !inputMonitoringOK { return "Нет доступа к Мониторингу ввода" }
        // Разрешения на месте, а слежение отвалилось: разные поломки лечатся
        // по-разному, и валить их в одну строку значит отправить владельца
        // чинить не то.
        // Аварийной строке разрешено занять ДВЕ строки панели: её работа -
        // быть прочитанной, а обрезанный хвост «отвалил…» не сообщает ничего.
        // Две строки на 300 pt - это около 56 знаков, и текст держится внутри
        // с запасом. Что делать, говорит сам пункт: он кликается и поднимает
        // слежение, а не открывает визард прав, - приписка «нажмите» лишняя.
        if !inputTapOK { return "Слежение за клавишами отвалилось" }
        return nil
    }

    /// Цвет состояния - тот же, что у волны на плашке записи.
    ///
    /// Одно состояние обязано называться одинаково на всех поверхностях:
    /// если на плашке идёт зелёная волна, а в меню про это молчат, владелец
    /// сверяет два интерфейса вместо одного.
    var stateColor: NSColor {
        if mark.alarm == .noPermission || !inputTapOK { return DICTATION_HUD_WAVE_RED }
        if mark.mode == .dictating { return DICTATION_HUD_WAVE_GREEN }
        switch mode {
        case .fixing: return DICTATION_HUD_WAVE_GREEN
        // «Только считает» - тоже работа, но своя, не золотая: золото
        // закреплено за промпт-режимом, где работает ИИ.
        case .shadow: return NSColor.secondaryLabelColor
        case .paused: return NSColor.tertiaryLabelColor
        }
    }

    /// Полная фраза для VoiceOver: глиф — единственный носитель состояния,
    /// без подписи он для VoiceOver нем (VISUAL_SPEC §4).
    var accessibilityLabel: String {
        if mark.alarm == .noPermission, !inputTapOK, accessibilityOK, inputMonitoringOK {
            return "\(IRIZ_NAME): слежение за клавишами отвалилось"
        }
        if mark.alarm == .noPermission { return "\(IRIZ_NAME): нет доступа к Универсальному доступу" }
        if mark.mode == .dictating { return "\(IRIZ_NAME): идёт диктовка" }
        if !microphoneOK { return "\(IRIZ_NAME): нет доступа к микрофону" }
        return "\(IRIZ_NAME): \(currentLayoutName), \(mode.title.lowercased())"
    }


    /// Русская плюрализация: 1 исправление · 2 исправления · 5 исправлений.
    static func plural(_ n: Int, one: String, few: String, many: String) -> String {
        let mod100 = n % 100
        if (11...14).contains(mod100) { return many }
        switch n % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }

    // MARK: - Анимация волны диктовки (VISUAL_SPEC §4)

    /// Таймер фазового сдвига волны. Живёт только в режиме dictating и только
    /// при выключенном «Уменьшении движения» — единственная анимация продукта.
    private var waveTimer: Timer?
    private var waveStart: TimeInterval = 0

    /// Запускает/останавливает фазовый сдвиг по смене знака (didSet mark).
    /// Переход между состояниями мгновенный, без кроссфейда (§4): выход из
    /// dictating сразу гасит таймер и возвращает волну в базовую фазу 0.
    private func updateWaveAnimation() {
        let shouldRun = mark.mode == .dictating && !IrizMark.reduceMotionEnabled
        if shouldRun, waveTimer == nil {
            waveStart = ProcessInfo.processInfo.systemUptime
            waveTimer = Timer.scheduledTimer(
                withTimeInterval: IrizMark.wavePeriod / Double(IrizMark.waveFramesPerPeriod),
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor in self?.waveTick() }
            }
        } else if !shouldRun {
            waveTimer?.invalidate()
            waveTimer = nil
            if mark.wavePhase != 0 { mark.wavePhase = 0 }
        }
    }

    private func waveTick() {
        guard mark.mode == .dictating, !IrizMark.reduceMotionEnabled else {
            updateWaveAnimation()   // режим сменился или движение уменьшили — стоп
            return
        }
        mark.wavePhase = IrizMark.wavePhase(at: ProcessInfo.processInfo.systemUptime - waveStart)
    }
}
