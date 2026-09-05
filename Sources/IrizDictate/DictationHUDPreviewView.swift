// Живой предпросмотр плашки для настроек.
//
// Владелец: «там, где выбирается цвет, должно быть, как будет выглядеть плашка.
// Я должен кликнуть в визуал. Не маленькая, большая, средняя, а прям можно
// кликать». Список слов заменяется тремя живыми плашками.
//
// ГЛАВНОЕ ЗДЕСЬ - чем это НЕ является. Это не похожая картинка и не реплика на
// SwiftUI: рисуют ровно те же классы, что рисуют настоящую плашку, теми же
// функциями цвета, формы и высот столбиков. Второй копии внешнего вида в
// проекте не появляется, и предпросмотр не может разойтись с тем, что владелец
// увидит при диктовке. Этот проект уже платил за разъехавшиеся источники
// правды четыре раза - геометрией плашки, знаком строки меню, путями после
// переименования и размером, объявленным дважды.
//
// Сборка пары «стекло + волна» вне окна плашки не гипотеза: ровно так её
// собирает DictationHUDLiveCapture, и она там работает.
import AppKit

/// Публичный фасад: настройки не знают ни про стадии, ни про тона, ни про
/// формы. Они говорят «покажи такой размер с такой палитрой» - и всё.
public final class DictationHUDPreviewView: NSView {
    /// Размер плашки. Меняется - меняется и геометрия предпросмотра.
    public var sizeChoice: DictationHUDSizeChoice = DICTATION_HUD_DEFAULT_SIZE {
        didSet { guard sizeChoice != oldValue else { return }; refresh() }
    }

    /// Палитра волны.
    public var palette: DictationHUDWavePalette = DICTATION_HUD_DEFAULT_WAVE_PALETTE {
        didSet { guard palette != oldValue else { return }; refresh() }
    }

    /// Что показывает предпросмотр: обычную диктовку или промпт-режим. Цвет
    /// режима владелец выбирает глазами, а не по названию тона.
    public var purpose: DictationHUDPreviewPurpose = .dictation {
        didSet { guard purpose != oldValue else { return }; refresh() }
    }

    /// Живёт ли волна. У невыбранного варианта она стоит: три бегущие волны
    /// рядом спорят за внимание и мешают выбрать.
    public var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            isAnimating ? startTicking() : stopTicking()
        }
    }

    /// Стекло есть только на macOS 26. На младших предпросмотр показывает
    /// волну без стекла - ровно то же, что владелец увидит в плашке на той же
    /// системе. Врать про стекло там, где его нет, хуже, чем показать без него.
    private var glass: AnyObject?
    private let bars = DictationHUDWaveBarsView(frame: .zero)
    private var phase: CGFloat = 0
    private var ticker: Timer?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        if #available(macOS 26.0, *) {
            let stack = DictationHUDGlassStack(frame: .zero)
            stack.bodyContent = bars
            addSubview(stack)
            glass = stack
        } else {
            addSubview(bars)
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    /// Таймер снимается при уходе с экрана, а не в deinit: deinit не изолирован
    /// главным актором, а таймер живёт на нём. Заодно это честнее - невидимый
    /// предпросмотр не имеет права тикать тридцать раз в секунду.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopTicking() } else if isAnimating { startTicking() }
    }

    public override var isFlipped: Bool { false }

    /// Сколько места занимает предпросмотр этого размера.
    public var previewSize: CGSize { dictationHUDCollapsedSize(sizeChoice) }

    public override var intrinsicContentSize: NSSize { previewSize }

    public override func layout() {
        super.layout()
        if let stack = glass as? NSView {
            stack.frame = CGRect(origin: .zero, size: bounds.size)
        } else {
            bars.frame = bounds.insetBy(dx: dictationHUDGlassInset(for: bounds.size),
                                        dy: dictationHUDGlassInset(for: bounds.size))
        }
        refresh()
    }

    private func refresh() {
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let stage = DictationHUDStage.listening(purpose == .prompt ? .prompt : .dictation)
        let tone = dictationHUDWaveTone(stage: stage, purpose: purpose == .prompt ? .prompt : .dictation)
        bars.tint = dictationHUDWaveColor(tone)
        bars.coreWhiteScale = tone == .prompt ? DICTATION_HUD_GOLD_CORE_WHITE : 1
        bars.glyph = .wave
        bars.lineIntensity = 0.55
        bars.collapse = 0
        bars.phase = phase
        let count = dictationHUDBarCount(sizeChoice)
        bars.heights = dictationHUDWaveBarHeights(
            levels: dictationHUDWorkingLevels(phase: phase, count: count),
            count: count
        )
        if #available(macOS 26.0, *), let stack = glass as? DictationHUDGlassStack {
            stack.modeGlow(dictationHUDWaveColor(tone),
                           strength: tone == .prompt ? DICTATION_HUD_MODE_GLOW_STRENGTH : 0)
            stack.haloPhase = phase
            stack.apply(dictationHUDGlassShape(form: .listening, in: size), animated: false)
        }
        bars.needsDisplay = true
    }

    private func startTicking() {
        stopTicking()
        // Тот же режим, что у таймеров плашки: в `.default` тик умирает, пока
        // открыто любое меню, и предпросмотр замирает у владельца на глазах.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.12
            self.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }
}

/// Что показывает предпросмотр. Отдельный тип, а не внутренний
/// `DictationRecordingPurpose`: настройки не обязаны знать про устройство
/// конвейера диктовки.
public enum DictationHUDPreviewPurpose: String, CaseIterable, Sendable {
    case dictation, prompt
}
