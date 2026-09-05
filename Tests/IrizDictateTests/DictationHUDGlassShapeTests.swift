import Foundation
import Testing

@testable import IrizDictate

@Suite("отказ собирается в кружок с крестиком")
struct DictationHUDFailureShapeTests {
    /// Слова владельца 04.09.2026: волна «должна из линий потом также
    /// схлопнуться в кружочек, в котором будет красный крестик».
    @Test func everyFailureCollapsesToTheCircle() {
        let failures: [DictationHUDStage] = [
            .notDelivered(.insertionFailed),
            .promptNotDelivered(.insertionFailed),
            .promptFailed(.invalidResult),
            .nothingRecognized(savedToHistory: true),
            .nothingRecognized(savedToHistory: false),
            .recognitionTimedOut,
            .recognitionFailed(savedToHistory: true),
            .refused(.secureInputActive),
        ]
        let size = CGSize(width: 248, height: 36.8)
        for stage in failures {
            #expect(dictationHUDGlassForm(for: stage) == .done, "\(stage) не собралась в кружок")
            let shape = dictationHUDGlassShape(form: dictationHUDGlassForm(for: stage), in: size)
            #expect(abs(shape.body.width - shape.body.height) < 0.001, "\(stage): это не круг")
            #expect(dictationHUDWaveGlyph(for: stage, purpose: .dictation) == .cross)
            #expect(dictationHUDWaveGlyph(for: stage, purpose: .prompt) == .cross,
                    "обрыв старше режима: крестик обязан быть в обоих")
            #expect(dictationHUDWaveTone(stage: stage, purpose: .prompt) == .failure)
        }
    }

    /// Успех крестика не получает ни при каком режиме.
    @Test func successNeverShowsTheCross() {
        for stage in [DictationHUDStage.inserted, .promptSavedAfterFocusChange] {
            #expect(dictationHUDWaveGlyph(for: stage, purpose: .dictation) == .check)
            #expect(dictationHUDWaveGlyph(for: stage, purpose: .prompt) == .bolt)
        }
    }

    /// Две черты, а не ломаная: соединённые, они дали бы галочку с хвостом.
    @Test func crossIsTwoSeparateStrokes() {
        let strokes = dictationHUDCrossStrokes(in: CGRect(x: 0, y: 0, width: 32, height: 32))
        #expect(strokes.count == 2)
        #expect(strokes.allSatisfy { $0.count == 2 })
        #expect(strokes[0][0].x < strokes[0][1].x && strokes[0][0].y < strokes[0][1].y)
        #expect(strokes[1][0].x < strokes[1][1].x && strokes[1][0].y > strokes[1][1].y)
    }
}

@Suite("плашка держит пропорции на всех трёх размерах")
struct DictationHUDSizeGeometryTests {
    /// У DictationHUDSizeChoice не было ни одного теста, а геометрия плашки уже
    /// стоила пяти отказов подряд. Проверяем то, что ломалось: стекло обязано
    /// помещаться в окно ЛЮБОГО размера, а не только среднего.
    @Test func glassFitsEveryWindowSize() {
        for choice in DictationHUDSizeChoice.allCases {
            let size = dictationHUDCollapsedSize(choice)
            for form in DictationHUDGlassForm.allCases {
                let shape = dictationHUDGlassShape(form: form, in: size)
                #expect(shape.body.minX >= -0.001, "\(choice)/\(form): стекло вылезло слева")
                #expect(shape.body.minY >= -0.001, "\(choice)/\(form): стекло вылезло снизу")
                #expect(shape.body.maxX <= size.width + 0.001, "\(choice)/\(form): стекло вылезло справа")
                #expect(shape.body.maxY <= size.height + 0.001, "\(choice)/\(form): стекло вылезло сверху")
            }
        }
    }

    /// Поле сверху равно полю снизу: перекошенное стекло читается браком.
    @Test func glassSitsCentredVertically() {
        for choice in DictationHUDSizeChoice.allCases {
            let size = dictationHUDCollapsedSize(choice)
            let shape = dictationHUDGlassShape(form: .listening, in: size)
            let top = size.height - shape.body.maxY
            let bottom = shape.body.minY
            #expect(abs(top - bottom) < 0.001, "\(choice): поле сверху \(top), снизу \(bottom)")
        }
    }

    /// Стекло растёт вместе с окном, а не остаётся константой. Именно это и
    /// ломалось: «большая» плашка была не крупнее, а шире с пустотой внутри.
    @Test func glassGrowsWithTheWindow() {
        let small = dictationHUDGlassShape(form: .listening, in: dictationHUDCollapsedSize(.small))
        let medium = dictationHUDGlassShape(form: .listening, in: dictationHUDCollapsedSize(.medium))
        let large = dictationHUDGlassShape(form: .listening, in: dictationHUDCollapsedSize(.large))
        #expect(small.body.height < medium.body.height)
        #expect(medium.body.height < large.body.height)
        #expect(small.body.width < medium.body.width)
        #expect(medium.body.width < large.body.width)
    }

    /// Круг остаётся кругом на любом размере.
    @Test func doneFormStaysACircle() {
        for choice in DictationHUDSizeChoice.allCases {
            let size = dictationHUDCollapsedSize(choice)
            let shape = dictationHUDGlassShape(form: .done, in: size)
            #expect(abs(shape.body.width - shape.body.height) < 0.001, "\(choice): не круг")
            #expect(abs(shape.bodyRadius - shape.body.height / 2) < 0.001, "\(choice): радиус не половина")
        }
    }

    /// Столбики считаются тем же полем, что резервирует рисование: иначе
    /// крайние получают нулевую прозрачность и волна стоит не по центру.
    @Test func barCountUsesTheSameInsetAsDrawing() {
        for choice in DictationHUDSizeChoice.allCases {
            let width = dictationHUDCollapsedSize(choice).width
            let usable = width - (DICTATION_HUD_WAVE_SIDE_INSET * 2)
            let step = DICTATION_HUD_BAR_WIDTH + DICTATION_HUD_BAR_GAP
            let span = (CGFloat(dictationHUDBarCount(choice) - 1) * step) + DICTATION_HUD_BAR_WIDTH
            #expect(span <= usable + 0.001, "\(choice): волна шире поля рисования")
        }
    }

    /// Больше плашка - подробнее волна.
    @Test func barCountGrowsWithTheSize() {
        #expect(dictationHUDBarCount(.small) < dictationHUDBarCount(.medium))
        #expect(dictationHUDBarCount(.medium) < dictationHUDBarCount(.large))
    }
}

@Suite("«я уже это делаю» не красится отказом")
struct DictationRefusalPresentationTests {
    /// Поймано владельцем живьём: нажал клавишу второй раз во время
    /// расшифровки, увидел красную ошибку, а следом - зелёную галочку успешной
    /// вставки. Работа шла и дошла; красный крест был ложью.
    @Test func busyRefusalsNeverPaintThePlate() {
        #expect(dictationHUDStage(forStartRefusal: .alreadyRecording) == nil)
        #expect(dictationHUDStage(forStartRefusal: .transcriptionInFlight) == nil)
    }

    /// А настоящие отказы обязаны показываться: писать в поле пароля нечем,
    /// распознавать без модели нечем.
    @Test func realRefusalsStayVisible() {
        #expect(dictationHUDStage(forStartRefusal: .secureInputActive) == .refused(.secureInputActive))
        #expect(dictationHUDStage(forStartRefusal: .modelNotReady) == .refused(.modelNotReady))
    }

    /// Ни один отказ не забыт: список закрыт, и новый случай обязан получить
    /// решение явно, а не унаследовать чужое умолчанием.
    @Test func everyRefusalHasADecision() {
        for refusal in [DictationStartRefusal.alreadyRecording, .transcriptionInFlight,
                        .secureInputActive, .modelNotReady] {
            let stage = dictationHUDStage(forStartRefusal: refusal)
            let busy = refusal == .alreadyRecording || refusal == .transcriptionInFlight
            #expect((stage == nil) == busy, "\(refusal): решение разошлось со смыслом")
        }
    }
}

@Suite("плашка разворачивается в панель с текстом")
struct DictationHUDTranscriptLayoutTests {
    /// Слова владельца: «эта плашка трансформируется в зону, где текст
    /// напечатан, и я его могу копировать».
    @Test func panelIsWiderThanThePlateButFitsTheScreen() {
        for choice in DictationHUDSizeChoice.allCases {
            let plate = dictationHUDCollapsedSize(choice)
            let size = dictationHUDTranscriptSize(lineCount: 3, plateSize: plate, screenWidth: 1440)
            #expect(size.width > plate.width, "\(choice): панель не шире плашки")
            #expect(size.width <= 1440 - 80, "\(choice): панель шире экрана")
            #expect(size.height >= plate.height, "\(choice): панель ниже плашки")
        }
    }

    /// Панель растёт по числу строк - и упирается в потолок. Надиктовка на три
    /// минуты не имеет права занять весь экран.
    @Test func heightGrowsWithLinesAndStops() {
        let plate = dictationHUDCollapsedSize(.medium)
        let one = dictationHUDTranscriptSize(lineCount: 1, plateSize: plate, screenWidth: 1440)
        let four = dictationHUDTranscriptSize(lineCount: 4, plateSize: plate, screenWidth: 1440)
        let many = dictationHUDTranscriptSize(lineCount: 400, plateSize: plate, screenWidth: 1440)
        #expect(one.height < four.height)
        #expect(four.height < many.height)
        let ceiling = dictationHUDTranscriptSize(lineCount: DICTATION_HUD_TRANSCRIPT_MAX_LINES,
                                                 plateSize: plate, screenWidth: 1440)
        #expect(many.height == ceiling.height, "потолок высоты не держится")
    }

    /// Узкий экран не ломает панель: она сжимается, а не вылезает.
    @Test func narrowScreenClampsTheWidth() {
        let plate = dictationHUDCollapsedSize(.large)
        let size = dictationHUDTranscriptSize(lineCount: 2, plateSize: plate, screenWidth: 420)
        #expect(size.width <= max(plate.width, 340))
    }

    /// Оценка строк: длинный текст даёт больше строк, перевод строки считается.
    @Test func lineCountFollowsTheText() {
        let width: CGFloat = 320
        #expect(dictationHUDTranscriptLineCount(text: "коротко", width: width) == 1)
        let long = String(repeating: "слово ", count: 60)
        #expect(dictationHUDTranscriptLineCount(text: long, width: width) > 3)
        #expect(dictationHUDTranscriptLineCount(text: "раз\nдва\nтри", width: width) == 3)
        #expect(dictationHUDTranscriptLineCount(text: "", width: width) == 1)
    }

    /// Форма панели: прямоугольник со скруглением, а не стадион, и стекло
    /// помещается в окно.
    @Test func transcriptShapeFitsAndIsNotAStadium() {
        let size = dictationHUDTranscriptSize(lineCount: 5,
                                              plateSize: dictationHUDCollapsedSize(.medium),
                                              screenWidth: 1440)
        let shape = dictationHUDGlassShape(form: .transcript, in: size)
        #expect(shape.body.minX >= 0 && shape.body.minY >= 0)
        #expect(shape.body.maxX <= size.width && shape.body.maxY <= size.height)
        #expect(shape.bodyRadius < shape.body.height / 2, "скругление в половину высоты даёт стадион")
    }
}
