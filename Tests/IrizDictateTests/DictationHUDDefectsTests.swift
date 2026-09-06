// Пробы трёх дефектов, названных владельцем живьём 06.09.2026.
//
// Каждая проба стережёт ОДНО правило, и каждая обязана краснеть на прежнем
// коде. Живой щелчок мышью тесту недоступен, поэтому судится то, что решает
// исход щелчка: раздача события подвидам, наличие выхода из раскрытой формы и
// арифметика середины плашки.
import AppKit
import Testing

@testable import IrizDictate

@Suite("плашка: щелчок доходит до кнопки")
@MainActor
struct DictationHUDHitDispatchTests {

    /// Плашка в покое, раскрытая полоской: ряд кнопок поверх стекла.
    private func makeStrip() -> (NSView, DictationHUDStripView) {
        let size = dictationHUDStripSize(working: dictationHUDCollapsedSize(.medium), buttons: 6)
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        // Вид-картинка снизу: он обязан молчать, иначе съест перетаскивание.
        let decor = DictationHUDHintView(frame: CGRect(origin: .zero, size: size))
        let strip = DictationHUDStripView(frame: CGRect(origin: .zero, size: size))
        strip.actions = dictationHUDStripActions(isRecording: false, language: .russian)
        root.addSubview(decor)
        root.addSubview(strip)
        root.layoutSubtreeIfNeeded()
        return (root, strip)
    }

    /// Главное правило. Прежний перебор шёл по ТИПУ подвида и полоску пропускал:
    /// щелчок по любой кнопке доставался контейнеру и раскрывал панель.
    @Test func каждаяКнопкаПолоскиПолучаетСвойЩелчок() throws {
        let (root, strip) = makeStrip()
        let frames = dictationHUDStripLayout(width: strip.bounds.width,
                                             height: strip.bounds.height,
                                             buttons: 6)
        #expect(frames.count == 6)
        for (index, frame) in frames.enumerated() {
            let point = root.convert(CGPoint(x: frame.midX, y: frame.midY), from: strip)
            let hit = dictationHUDHitTarget(subviews: root.subviews, at: point)
            #expect(hit is DictationHUDActionButton,
                    "щелчок по кнопке \(index) не дошёл до неё: \(String(describing: hit))")
        }
    }

    /// Щелчок МИМО кнопок обязан достаться плашке: ею двигают и её раскрывают.
    @Test func щелчокМимоКнопокОстаётсяПлашке() {
        let (root, _) = makeStrip()
        let corner = CGPoint(x: 1, y: 1)
        #expect(dictationHUDHitTarget(subviews: root.subviews, at: corner) == nil)
    }

    /// Цена правила «раздавать любому подвиду»: вид-картинка ОБЯЗАН молчать.
    /// Заговорит - и плашку станет нечем таскать.
    @Test func видыКартинкиМышьНеБерут() {
        let box = CGRect(x: 0, y: 0, width: 124, height: 37)
        let point = CGPoint(x: 40, y: 18)
        #expect(DictationHUDHintView(frame: box).hitTest(point) == nil)
        #expect(DictationHUDCapsuleView(frame: box).hitTest(point) == nil)
        #expect(DictationHUDWaveBarsView(frame: box).hitTest(point) == nil)
    }

    /// Полоска скрыта - щелчок обязан идти сквозь неё, а не тонуть в невидимом.
    @Test func скрытаяПолоскаЩелчокНеЛовит() {
        let (root, strip) = makeStrip()
        strip.isHidden = true
        let frames = dictationHUDStripLayout(width: strip.bounds.width,
                                             height: strip.bounds.height,
                                             buttons: 6)
        let point = root.convert(CGPoint(x: frames[0].midX, y: frames[0].midY), from: strip)
        #expect(dictationHUDHitTarget(subviews: root.subviews, at: point) == nil)
    }
}

/// Заглушка поверхности: тесту нужен только поток содержимого.
@MainActor
private final class ExitSurface: DictationHUDSurface {
    var presented: [DictationHUDContent] = []
    var dismissCount = 0
    /// Кого зовёт панель, когда текст забрали. Тесту это единственный способ
    /// пройти путь щелчка по панели, не имея мыши.
    var textTaken: (() -> Void)?

    func present(_ content: DictationHUDContent) { presented.append(content) }
    func dismiss() { dismissCount += 1 }
    func setTranscriptCopiedHandler(_ handler: @escaping () -> Void) { textTaken = handler }
}

@Suite("плашка: из любой формы есть выход")
@MainActor
struct DictationHUDExitTests {

    private func makePresenter() -> (DictationHUDPresenter, ExitSurface) {
        let surface = ExitSurface()
        let presenter = DictationHUDPresenter(level: { 0 },
                                              pipelineState: { .ready },
                                              historyHint: { "" },
                                              reduceMotion: { true },
                                              surface: { surface })
        presenter.prewarm()
        return (presenter, surface)
    }

    /// Выход первый: щелчок мимо кнопок и кнопка «свернуть» - один путь.
    @Test func щелчокСворачивает() throws {
        let (presenter, surface) = makePresenter()
        presenter.toggleOpen()
        #expect(presenter.isOpen)
        presenter.toggleOpen()
        #expect(!presenter.isOpen)
        #expect(try #require(surface.presented.last).expanded == false)
    }

    /// Выход второй и третий: крестик в шапке и Escape зовут `collapse()`.
    /// Не переключатель: закрытую плашку он открыть не имеет права.
    @Test func сворачиваниеТолькоЗакрывает() {
        let (presenter, _) = makePresenter()
        presenter.collapse()
        #expect(!presenter.isOpen, "закрытая плашка раскрылась от «свернуть»")
        presenter.toggleOpen()
        presenter.collapse()
        #expect(!presenter.isOpen)
        presenter.collapse()
        #expect(!presenter.isOpen)
    }

    /// Дефект владельца дословно: «когда через всплывающую плашку открывается
    /// на диктовке, их нельзя закрыть». Щелчок по панели уходил в копирование,
    /// копирование звало покой, а покой перерисовывал плашку с прежним
    /// раскрытием - панель вставала обратно, и выйти из неё было нечем.
    @Test func забралиТекстПанельНеВозвращается() throws {
        let (presenter, surface) = makePresenter()
        presenter.toggleOpen()
        #expect(presenter.isOpen)
        let taken = try #require(surface.textTaken)
        taken()
        #expect(!presenter.isOpen, "панель вернулась после того, как текст забрали")
        #expect(try #require(surface.presented.last).expanded == false)
        // И плашка на экране осталась: сворачивание - не снос.
        #expect(surface.dismissCount == 0)
    }

    /// Раскрытая форма ОБЯЗАНА нести кнопку выхода на любой стадии конвейера.
    @Test func вЛюбойСтадииРаскрытаяФормаНесётСвернуть() {
        let stages: [DictationHUDStage] = [
            .resting, .listening(.dictation), .listening(.prompt), .listening(.translation),
            .recognizing, .buildingPrompt, .inserted,
            .notDelivered(.insertionFailed),
            .nothingRecognized(savedToHistory: true),
            .nothingRecognized(savedToHistory: false),
            .recognitionTimedOut,
            .recognitionFailed(savedToHistory: true),
            .recognitionFailed(savedToHistory: false),
            .promptFailed(.invalidResult), .promptSavedAfterFocusChange,
            .refused(.secureInputActive),
        ]
        for stage in stages {
            let content = dictationHUDContent(stage: stage,
                                              level: 0,
                                              reduceMotion: true,
                                              historyHint: "",
                                              expanded: true)
            #expect(content.actions.contains { $0.id == .collapse },
                    "из стадии \(stage) выйти нечем")
        }
    }

    /// Escape без идущей записи сворачивает плашку - и НЕ подавляется:
    /// клавиша принадлежит приложению под плашкой.
    @Test func escapeБезЗаписиСворачиваетИНеПодавляется() {
        var automaton = HotkeyTransitionState()
        let result = automaton.transition(
            for: HotkeyEventSnapshot(typeRawValue: CGEventType.keyDown.rawValue,
                                     keycode: ESCAPE_KEYCODE,
                                     flagsRawValue: 0,
                                     isAutoRepeat: false),
            hotkey: hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE, modifiers: []),
            triggerMode: .toggle,
            isRecording: false
        )
        #expect(result.actions == [HotkeyTransitionAction.dismissOverlay])
        #expect(!result.suppress, "Escape отобран у приложения под плашкой")
    }

    /// А во время записи Escape остаётся отменой - прежнее поведение цело.
    @Test func escapeВоВремяЗаписиОтменяет() {
        var automaton = HotkeyTransitionState()
        let result = automaton.transition(
            for: HotkeyEventSnapshot(typeRawValue: CGEventType.keyDown.rawValue,
                                     keycode: ESCAPE_KEYCODE,
                                     flagsRawValue: 0,
                                     isAutoRepeat: false),
            hotkey: hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE, modifiers: []),
            triggerMode: .toggle,
            isRecording: true
        )
        #expect(result.actions == [HotkeyTransitionAction.cancel])
        #expect(result.suppress)
    }
}

@Suite("плашка: середина не съезжает")
struct DictationHUDPlateGeometryTests {

    /// Дефект владельца дословно: «после раскрытия плашки и закрытия обратно,
    /// она опять съезжает куда-то вправо». Десять циклов подряд не имеют права
    /// сдвинуть плашку ни на пункт.
    @Test func десятьЦикловРаскрытияНеДвигаютПлашку() {
        for choice in DictationHUDSizeChoice.allCases {
            let working = dictationHUDCollapsedSize(choice)
            let rest = dictationHUDRestingSize(working)
            let strip = dictationHUDStripSize(working: working, buttons: 6)
            var plate = DictationHUDPlateGeometry(
                frame: CGRect(x: 733, y: 41, width: rest.width, height: rest.height))
            let before = plate.frame
            for _ in 0..<10 {
                // Наведение: капля растёт в полоску.
                plate.setSize(strip)
                // Раскрытие панели: она выше и шире полоски.
                plate.setSize(CGSize(width: 421, height: 213))
                // И обратно в каплю.
                plate.setSize(strip)
                plate.setSize(rest)
            }
            #expect(plate.frame == before,
                    "размер \(choice): плашка уехала \(before) -> \(plate.frame)")
        }
    }

    /// Середина живёт отдельно от кадра именно потому, что кадр округляется.
    /// Нечётная сторона - тот самый случай, на котором копилась ошибка.
    @Test func нечётныйРазмерНеУноситСередину() {
        var plate = DictationHUDPlateGeometry(frame: CGRect(x: 100, y: 100, width: 42, height: 15))
        let center = plate.center
        for size in [CGSize(width: 201, height: 37), CGSize(width: 42, height: 15),
                     CGSize(width: 124, height: 37), CGSize(width: 42, height: 15)] {
            plate.setSize(size)
            #expect(plate.center == center, "середина уехала на размере \(size)")
        }
    }

    /// Новое место (перетаскивание, притяжение) середину ПЕРЕНОСИТ: это не морф.
    @Test func новоеМестоПереноситСередину() {
        var plate = DictationHUDPlateGeometry(frame: CGRect(x: 0, y: 0, width: 42, height: 15))
        plate.setFrame(CGRect(x: 500, y: 300, width: 42, height: 15))
        #expect(plate.center == CGPoint(x: 521, y: 307.5))
        // Кадр - округлённое изображение середины, и на нечётной ширине он
        // встаёт на полпункта в сторону. Копиться этому нечему: следующий морф
        // считается опять от середины.
        plate.setSize(CGSize(width: 201, height: 37))
        #expect(abs(plate.frame.midX - 521) <= 0.5)
        #expect(plate.center == CGPoint(x: 521, y: 307.5))
    }
}

@Suite("плашка: окно не уезжает за кромку экрана")
@MainActor
struct DictationHUDOnScreenTests {
    /// Видимая область как у ноутбука владельца: строка меню сверху, Dock снизу.
    private let visible = CGRect(x: 0, y: 76, width: 1280, height: 718)

    /// Раскрытие идёт от центра, и у кромки половина роста уходит наружу.
    /// Поймано кадром: плашка в месте «низ-центр», низ панели за экраном.
    @Test func раскрытаяПанельВозвращаетсяНаЭкран() {
        for anchor in DictationHUDAnchor.allCases {
            let rest = dictationHUDRestingSize(dictationHUDCollapsedSize(.small))
            var plate = DictationHUDPlateGeometry(
                frame: dictationHUDAnchoredFrame(anchor, plate: rest, in: visible))
            // Панель расшифровки на четыре строки - самая высокая форма.
            plate.setSize(CGSize(width: 257, height: 176))
            let window = dictationHUDOnScreenFrame(plate.frame, visible: visible)
            #expect(visible.contains(window),
                    "место \(anchor): окно \(window) вылезло из \(visible)")
        }
    }

    /// И клэмп НЕ имеет права двигать плашку: он правит окно, а середина
    /// остаётся прежней. Иначе съезд, вычищенный из морфа, вернулся бы через
    /// кромку экрана.
    @Test func клэмпНеУноситПлашкуПриПовторныхРаскрытиях() {
        let rest = dictationHUDRestingSize(dictationHUDCollapsedSize(.small))
        var plate = DictationHUDPlateGeometry(
            frame: dictationHUDAnchoredFrame(.bottomCenter, plate: rest, in: visible))
        let before = plate.frame
        for _ in 0..<10 {
            plate.setSize(CGSize(width: 257, height: 176))
            _ = dictationHUDOnScreenFrame(plate.frame, visible: visible)
            plate.setSize(rest)
            _ = dictationHUDOnScreenFrame(plate.frame, visible: visible)
        }
        #expect(plate.frame == before, "клэмп унёс плашку: \(before) -> \(plate.frame)")
    }

    /// Экран неизвестен (плашка ещё не показана) - кадр не трогаем: врать
    /// выдуманной областью хуже, чем не править ничего.
    @Test func безЭкранаКадрНеТрогается() {
        let frame = CGRect(x: -100, y: -100, width: 50, height: 50)
        #expect(dictationHUDOnScreenFrame(frame, visible: nil) == frame)
    }
}
