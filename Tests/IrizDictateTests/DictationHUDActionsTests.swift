import CoreGraphics
import Testing
@testable import IrizDictate

/// Кнопки плашки и раскрытие по щелчку. Решение владельца 06.09.2026:
/// «анимация, которая переходит по выбору кнопок… перестраивается из просто
/// закрытой плашки в открытую, где идет запись текста».
@Suite("плашка: кнопки и раскрытие")
@MainActor
struct DictationHUDActionsTests {

    @Test func закрытаяПлашкаКнопокНеНесёт() {
        let content = dictationHUDContent(stage: .resting,
                                          level: 0,
                                          reduceMotion: false,
                                          historyHint: "")
        #expect(content.actions.isEmpty, "закрытая плашка отдала кнопки")
        #expect(!content.expanded)
        #expect(content.transcript == nil, "закрытая плашка подняла панель")
    }

    /// Раскрытая плашка обязана нести все кнопки и в том же порядке: кнопка,
    /// которая ездит с места на место, хуже отсутствующей. Состав вырос с пяти
    /// до семи 06.09.2026: владелец потребовал выбирать режим прямо тут -
    /// «сменить язык, выбрать режим, например, polish или prompt».
    @Test func раскрытаяПлашкаНесётКнопкиВПорядке() {
        let content = dictationHUDContent(stage: .resting,
                                          level: 0,
                                          reduceMotion: false,
                                          historyHint: "",
                                          expanded: true)
        #expect(content.expanded)
        #expect(content.actions.map(\.id) == [.record, .modePrompt, .modeTranslation,
                                              .language, .history, .settings, .collapse])
        // Полоска под мышью - те же кнопки без «свернуть»: сворачивать в покое
        // нечего, плашка и так капля.
        #expect(dictationHUDStripActions(isRecording: false, language: .auto).map(\.id)
                == [.record, .modePrompt, .modeTranslation, .language, .history, .settings])
    }

    /// Кнопка записи называет то, что случится, а не то, что есть.
    @Test func кнопкаЗаписиМеняетЗнакИПодпись() {
        let idle = dictationHUDActions(isRecording: false)[0]
        #expect(idle.symbol == "mic.fill")
        #expect(idle.title == "Начать запись")
        #expect(!idle.active)

        let live = dictationHUDActions(isRecording: true)[0]
        #expect(live.symbol == "stop.fill")
        #expect(live.title == "Закончить запись")
        #expect(live.active, "идущая запись не горит на кнопке")
    }

    /// Пустая панель обещает текст, которого нет. Правило дома остаётся в силе
    /// и для раскрытия по щелчку: панель говорит прямо, чего ждёт.
    @Test func раскрытаяБезТекстаГоворитЧегоЖдёт() {
        let content = dictationHUDContent(stage: .resting,
                                          level: 0,
                                          reduceMotion: false,
                                          historyHint: "",
                                          expanded: true)
        #expect(content.transcript == DICTATION_HUD_OPEN_PLACEHOLDER)
    }

    @Test func раскрытаяСТекстомПоказываетТекст() {
        let content = dictationHUDContent(stage: .resting,
                                          level: 0,
                                          reduceMotion: false,
                                          historyHint: "",
                                          transcript: "живой текст",
                                          expanded: true)
        #expect(content.transcript == "живой текст")
    }

    /// Недоехавший текст поднимает панель САМ, без раскрытия владельцем: это
    /// разные поводы, и путать их нельзя.
    @Test func недоехавшийТекстПоднимаетПанельБезРаскрытия() {
        let content = dictationHUDContent(stage: .notDelivered(.insertionFailed),
                                          level: 0,
                                          reduceMotion: false,
                                          historyHint: "",
                                          transcript: "не доехало")
        #expect(content.transcript == "не доехало")
        #expect(!content.expanded)
        #expect(content.actions.isEmpty)
    }

    @Test func языкХодитПоКругуИВозвращаетсяВНачало() {
        var language = DictationLanguage.auto
        var seen: [DictationLanguage] = []
        for _ in 0..<dictationHUDMenuLanguages.count {
            language = dictationHUDNextLanguage(after: language)
            seen.append(language)
        }
        #expect(seen.last == .auto, "круг языков не замкнулся")
        #expect(Set(seen).count == dictationHUDMenuLanguages.count, "круг пропустил язык")
    }

    /// Язык вне короткого круга (выбран в настройках) не оставляет кнопку без
    /// хода: следующий - первый в круге.
    @Test func языкВнеКругаВозвращаетПервый() {
        #expect(dictationHUDNextLanguage(after: .german) == dictationHUDMenuLanguages[0])
    }
}

/// Своя поверхность-заглушка: соседняя в DictationHUDTests.swift приватна, а
/// делать её общей значит связать два набора проб одним состоянием.
@MainActor
private final class OpenStateSurface: DictationHUDSurface {
    var presented: [DictationHUDContent] = []
    var dismissCount = 0

    func present(_ content: DictationHUDContent) { presented.append(content) }
    func dismiss() { dismissCount += 1 }
}

@Suite("плашка: раскрытие держит презентер")
@MainActor
struct DictationHUDOpenStateTests {

    private func makePresenter() -> (DictationHUDPresenter, OpenStateSurface) {
        let surface = OpenStateSurface()
        let presenter = DictationHUDPresenter(level: { 0 },
                                              pipelineState: { .ready },
                                              historyHint: { "" },
                                              reduceMotion: { true },
                                              surface: { surface })
        return (presenter, surface)
    }

    @Test func щелчокРаскрываетИСворачивает() throws {
        let (presenter, surface) = makePresenter()
        presenter.prewarm()
        #expect(!presenter.isOpen)

        presenter.toggleOpen()
        #expect(presenter.isOpen)
        let opened = try #require(surface.presented.last)
        #expect(opened.expanded)
        #expect(opened.actions.count == 7)

        presenter.toggleOpen()
        #expect(!presenter.isOpen)
        let closed = try #require(surface.presented.last)
        #expect(!closed.expanded)
        #expect(closed.actions.isEmpty)
        // И плашка на экране осталась: сворачивание - не снос.
        #expect(surface.dismissCount == 0)
    }

    /// Живой текст виден только в раскрытой плашке. В закрытой его негде
    /// показать, и гонять кадры ради невидимого - расход без смысла.
    @Test func живойТекстНеПерерисовываетЗакрытуюПлашку() {
        let (presenter, surface) = makePresenter()
        presenter.prewarm()
        let shown = surface.presented.count

        presenter.showLivePreview("первые слова")
        #expect(surface.presented.count == shown, "закрытая плашка перерисовалась ради невидимого текста")

        presenter.toggleOpen()
        presenter.showLivePreview("первые слова и ещё")
        #expect(surface.presented.last?.transcript == "первые слова и ещё")
    }

    /// Возврат в покой забывает живой текст: иначе следующая же перерисовка
    /// подняла бы чужую фразу.
    @Test func покойЗабываетЖивойТекст() {
        let (presenter, surface) = makePresenter()
        presenter.prewarm()
        presenter.toggleOpen()
        presenter.showLivePreview("сказанное")
        #expect(surface.presented.last?.transcript == "сказанное")

        // Уход в покой текст забывает, но раскрытие НЕ отменяет: захлопывать
        // панель после каждой надиктовки значит отбирать у владельца то, что
        // он открыл руками.
        presenter.dismiss()
        #expect(presenter.isOpen, "покой захлопнул панель, открытую владельцем")
        #expect(surface.presented.last?.transcript == DICTATION_HUD_OPEN_PLACEHOLDER)
    }
}

/// Ряд кнопок не имеет права вылезти за плашку НИ НА ОДНОЙ ширине.
///
/// Владелец поймал это живьём: на середине раскрытия правый край ряда торчал
/// наружу. Правило живёт здесь, а не во внимании: перебор ширин от капли до
/// широкой панели, все кнопки внутри, ни одна не наезжает на соседнюю.
@Suite("плашка: ряд кнопок не вылезает")
struct DictationHUDStripLayoutTests {

    @Test func кнопкиВсегдаВнутриПлашки() {
        let height: CGFloat = 37
        for buttons in 1...8 {
            for step in 0...120 {
                let width = 20 + CGFloat(step) * 4
                let frames = dictationHUDStripLayout(width: width, height: height, buttons: buttons)
                #expect(frames.count == buttons)
                for frame in frames {
                    #expect(frame.minX >= -0.01, "кнопка вылезла слева при ширине \(width)")
                    #expect(frame.maxX <= width + 0.01, "кнопка вылезла справа при ширине \(width)")
                    #expect(frame.minY >= -0.01)
                    #expect(frame.maxY <= height + 0.01)
                }
            }
        }
    }

    /// Столбик у боковой плашки судится тем же правилом: не вылезти и не
    /// наехать. Раскладка одна, просто в перевёрнутых мерах.
    @Test func столбикТожеНеВылезает() {
        for buttons in 1...8 {
            for step in 0...80 {
                let height = 20 + CGFloat(step) * 5
                let frames = dictationHUDStripLayout(width: 37, height: height,
                                                     buttons: buttons, vertical: true)
                #expect(frames.count == buttons)
                for frame in frames {
                    #expect(frame.minY >= -0.01, "кнопка вылезла снизу при высоте \(height)")
                    #expect(frame.maxY <= height + 0.01, "кнопка вылезла сверху при высоте \(height)")
                    #expect(frame.minX >= -0.01)
                    #expect(frame.maxX <= 37 + 0.01)
                }
                for pair in zip(frames, frames.dropFirst()) {
                    #expect(pair.1.minY >= pair.0.maxY - 0.01, "кнопки наехали в столбике")
                }
            }
        }
    }

    @Test func кнопкиНеНаезжаютДругНаДруга() {
        for buttons in 2...8 {
            for step in 0...60 {
                let width = 30 + CGFloat(step) * 6
                let frames = dictationHUDStripLayout(width: width, height: 37, buttons: buttons)
                for pair in zip(frames, frames.dropFirst()) {
                    #expect(pair.1.minX >= pair.0.maxX - 0.01,
                            "кнопки наехали друг на друга при ширине \(width)")
                }
            }
        }
    }

    /// Обещанный размер обязан вмещать ряд целиком - иначе полоска раскроется
    /// в плашку, которая ей мала, и ужиматься придётся каждый раз.
    @Test func обещанныйРазмерВмещаетРядЦеликом() {
        let working = CGSize(width: 124, height: 37)
        for buttons in 1...8 {
            let size = dictationHUDStripSize(working: working, buttons: buttons)
            let frames = dictationHUDStripLayout(width: size.width, height: size.height, buttons: buttons)
            let ideal = dictationHUDStripButtonSide(height: size.height)
            for frame in frames {
                #expect(frame.width >= ideal - 0.01, "ряд не поместился в обещанный размер")
            }
        }
    }
}

/// Двенадцать мест притяжения. Решение владельца 06.09.2026: плашка встаёт не
/// куда попало, а в известное место у края.
@Suite("плашка: места притяжения")
struct DictationHUDAnchorTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 900)

    @Test func местВсегдаДвенадцатьИОниРазные() {
        #expect(DictationHUDAnchor.allCases.count == 12)
        let frames = DictationHUDAnchor.allCases.map {
            dictationHUDAnchoredFrame($0, plate: CGSize(width: 124, height: 37), in: screen)
        }
        #expect(Set(frames.map { "\($0)" }).count == 12, "два места совпали")
    }

    @Test func плашкаВсегдаВнутриЭкрана() {
        for anchor in DictationHUDAnchor.allCases {
            for plate in [CGSize(width: 99, height: 29), CGSize(width: 124, height: 37),
                          CGSize(width: 161, height: 48), CGSize(width: 320, height: 120)] {
                let frame = dictationHUDAnchoredFrame(anchor, plate: plate, in: screen)
                #expect(screen.contains(frame), "\(anchor) вынес плашку за экран")
            }
        }
    }

    /// Боком плашка стоит вертикально: горизонтальная у левого края съела бы
    /// треть ширины экрана.
    @Test func бокомПлашкаВертикальна() {
        let plate = CGSize(width: 124, height: 37)
        for anchor in DictationHUDAnchor.allCases where anchor.isVertical {
            let size = dictationHUDAnchoredSize(anchor, plate: plate)
            #expect(size.width == plate.height && size.height == plate.width)
        }
        for anchor in DictationHUDAnchor.allCases where !anchor.isVertical {
            #expect(dictationHUDAnchoredSize(anchor, plate: plate) == plate)
        }
    }

    /// Брошенная в зоне плашка притягивается к ЭТОМУ месту, а не к соседнему.
    @Test func центрЗоныПритягиваетКСвоемуМесту() {
        for anchor in DictationHUDAnchor.allCases {
            let zone = dictationHUDAnchorZone(anchor, in: screen)
            let found = dictationHUDNearestAnchor(to: CGPoint(x: zone.midX, y: zone.midY),
                                                  in: screen)
            #expect(found == anchor, "центр зоны \(anchor) увёл к \(found)")
        }
    }

    /// Экран любого размера: ответ обязан быть, и он обязан быть внутри.
    @Test func узкийЭкранНеЛомаетПритяжение() {
        let narrow = CGRect(x: 0, y: 0, width: 400, height: 300)
        for anchor in DictationHUDAnchor.allCases {
            let frame = dictationHUDAnchoredFrame(anchor, plate: CGSize(width: 380, height: 60),
                                                  in: narrow)
            #expect(narrow.intersects(frame))
            #expect(frame.minX >= narrow.minX - 0.01)
            #expect(frame.maxX <= narrow.maxX + 0.01)
        }
    }
}
