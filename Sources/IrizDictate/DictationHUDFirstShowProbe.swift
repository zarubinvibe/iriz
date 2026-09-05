// Замер того, на что жаловался владелец: «она как будто бы тормозит в самом
// начале». Жалоба про первый показ за сессию, и спорить с ней можно только
// числом, снятым на живой панели.
//
// Почему технический режим, а не тест: под `swift test` окно не поднять, а без
// окна нет ни буфера, ни CADisplayLink, ни первого кадра — мерить будет нечего.
// Режим строится тем же приёмом, что `--export-hud-animation`: отдельный аргумент
// командной строки, работа до разрешений и захвата звука, выход по результату.
import AppKit
import Foundation

/// Что успели прогреть до первого показа. Существует ради сравнения: без
/// «до» число «после» ничего не значит.
public enum DictationHUDPrewarmMode: String, Sendable {
    /// Ничего. Так выглядела плашка до того, как шейдер стали собирать заранее.
    case none
    /// Только шейдер. Так плашка вела себя, когда за прогрев отвечал один
    /// `prewarmDictationHUDWave()`.
    case wave
    /// Всё, что можно собрать заранее: панель, слои, шейдер, первый кадр,
    /// шрифты подсказки, механика display link.
    case full
}

/// Поднять плашку и вернуть строку замера. Плашка при этом действительно
/// показывается — иначе замер был бы про другое.
@MainActor
public func measureDictationHUDFirstShow(mode: DictationHUDPrewarmMode,
                                         timeout: TimeInterval = 2) -> String {
    let surface = DictationHUDPanelSurface()
    switch mode {
    case .none: break
    case .wave: prewarmDictationHUDWave()
    case .full: surface.prewarm()
    }

    // Одного числа «до первого кадра» мало: заминка живёт ещё и в разрывах
    // между кадрами раскрытия, и именно она читается как «тормозит».
    let frames = DictationHUDFrameLog()
    surface.frameObserver = { gap, work in frames.add(gap: gap, work: work) }

    surface.updateHintLines(["правый ⌘ — остановить", "мышью — переставить"])
    surface.present(dictationHUDContent(stage: .listening(.dictation),
                                        level: 0.45,
                                        reduceMotion: false,
                                        historyHint: ""))

    // Первый кадр приходит с тиком display link, то есть уже из цикла событий:
    // без прокрутки цикла замер закончится ничем. Крутим всё раскрытие целиком.
    let deadline = Date().addingTimeInterval(min(timeout, DICTATION_HUD_REVEAL_IN_DURATION + 0.1))
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    let metric = surface.firstShowMetric
    surface.frameObserver = nil
    surface.dismiss()

    guard let metric else {
        return "HUD_FIRST_SHOW mode=\(mode.rawValue) result=timeout"
    }
    return String(format: "HUD_FIRST_SHOW mode=%@ painted_ms=%.1f ordered_ms=%.1f "
                  + "frames=%d worst_gap_ms=%.1f first_gap_ms=%.1f worst_work_ms=%.1f mean_work_ms=%.1f",
                  mode.rawValue,
                  metric.paintedSeconds * 1000,
                  metric.orderedSeconds * 1000,
                  frames.count,
                  frames.worstGap * 1000,
                  frames.firstGap * 1000,
                  frames.worstWork * 1000,
                  frames.meanWork * 1000)
}

/// Копилка кадров раскрытия. Классом, а не структурой: наблюдатель поверхности —
/// замыкание, и складывать ему некуда, если значение копируется.
@MainActor
final class DictationHUDFrameLog {
    private(set) var count = 0
    private(set) var worstGap: TimeInterval = 0
    private(set) var firstGap: TimeInterval = 0
    private(set) var worstWork: TimeInterval = 0
    private var totalWork: TimeInterval = 0

    var meanWork: TimeInterval { count > 0 ? totalWork / Double(count) : 0 }

    func add(gap: TimeInterval, work: TimeInterval) {
        if count == 0 { firstGap = gap }
        count += 1
        worstGap = max(worstGap, gap)
        worstWork = max(worstWork, work)
        totalWork += work
    }
}
