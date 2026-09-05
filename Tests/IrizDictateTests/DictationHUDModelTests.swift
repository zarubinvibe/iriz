import CoreGraphics
import Foundation
import Testing

@testable import IrizDictate

@Suite("плашка: визуальная модель")
struct DictationHUDVisualModelTests {
    /// Пилюли за лентой больше нет, и числа окна изменились из-за этого: свободная
    /// лента шире и ниже, чем почти квадратная пилюля с кантом и полем под ореол.
    @Test func геометрияКомпактнойПлашкиЗафиксированаКонтрактом() {
        #expect(DICTATION_HUD_BASE_SIZE == CGSize(width: 124.2, height: 36.8))
        #expect(DICTATION_HUD_WAVEFORM_WIDTH == 96.6)
        #expect(DICTATION_HUD_CHIP_SIZE == 32.2)
        #expect(DICTATION_HUD_EDGE_INSET == 12)
        // Окно шире и ниже ленты: у волны есть поле и по длине, и по высоте,
        // иначе свечение срезала бы панель — ровно там, где оно самое яркое.
        #expect(DICTATION_HUD_BASE_SIZE.width > DICTATION_HUD_WAVEFORM_WIDTH)
        #expect(DICTATION_HUD_BASE_SIZE.width > DICTATION_HUD_BASE_SIZE.height)
        // Прежде здесь стояло «окно вдвое выше ленты», и это ровно тот контракт,
        // который владелец забраковал: лента занимала среднюю треть высоты, а
        // сверху и снизу оставалась пустота. Поле остается, но названо честно -
        // столько, сколько нужно ауре, чтобы погаснуть самой (см. тест
        // «аураГаснетСамаНеДожидаясьКромки»), а не половина окна про запас.
        #expect(DICTATION_HUD_BASE_SIZE.height > DICTATION_HUD_RIBBON_PROCESSING_SPAN)
        #expect(DICTATION_HUD_RIBBON_PROCESSING_SPAN / DICTATION_HUD_BASE_SIZE.height > 0.6)
    }

    /// Голая лента — у живой записи, подложка-плашка — у исхода. Разделение
    /// обязано совпадать с «терминальная стадия»: разъедься они, и либо
    /// у записи вернётся пузырёк, либо «не вставилось» станет нечитаемым
    /// поверх чужого окна.
    @Test func подложкуПолучаютРовноТерминальныеСтадии() {
        let stages: [DictationHUDStage] = [
            .listening(.dictation), .listening(.prompt), .recognizing, .buildingPrompt,
            .inserted, .notDelivered(.insertionFailed),
            .nothingRecognized(savedToHistory: false), .nothingRecognized(savedToHistory: true),
            .recognitionTimedOut, .recognitionFailed(savedToHistory: false),
            .recognitionFailed(savedToHistory: true), .promptFailed(.invalidResult),
            .promptNotDelivered(.insertionFailed), .promptSavedAfterFocusChange,
            .refused(.secureInputActive),
        ]
        for stage in stages {
            #expect(dictationHUDFormShowsChip(dictationHUDVisual(for: stage).form)
                    == dictationHUDStageIsTerminal(stage),
                    "стадия \(stage) рисуется не тем объектом")
        }
    }

    @Test func каждаяСтадияИмеетЯвнуюФормуИАкцент() {
        let cases: [(DictationHUDStage, DictationHUDVisual)] = [
            (.listening(.dictation), .init(form: .waveform, accent: .red,
                                           mark: .none, flow: .symmetric, halo: .even)),
            (.listening(.prompt), .init(form: .waveform, accent: .violet,
                                        mark: .chevron, flow: .forward, halo: .traveling)),
            (.recognizing, .init(form: .processing, accent: .blue)),
            (.buildingPrompt, .init(form: .processing, accent: .cyan)),
            (.inserted, .init(form: .line, accent: .green)),
            (.notDelivered(.insertionFailed), .init(form: .exclamation, accent: .yellow)),
            (.nothingRecognized(savedToHistory: false), .init(form: .line, accent: .neutral)),
            (.nothingRecognized(savedToHistory: true), .init(form: .historyLine, accent: .neutral)),
            (.recognitionTimedOut, .init(form: .ellipsis, accent: .yellow)),
            (.recognitionFailed(savedToHistory: false), .init(form: .exclamation, accent: .yellow)),
            (.recognitionFailed(savedToHistory: true), .init(form: .exclamation, accent: .yellow)),
            (.promptFailed(.invalidResult), .init(form: .exclamation, accent: .yellow)),
            (.promptNotDelivered(.insertionFailed), .init(form: .exclamation, accent: .yellow)),
            (.promptSavedAfterFocusChange, .init(form: .historyLine, accent: .green)),
            (.refused(.secureInputActive), .init(form: .slash, accent: .orange)),
        ]

        for (stage, expected) in cases {
            #expect(dictationHUDVisual(for: stage) == expected)
        }
    }

    @Test func контентНесётНепрерывныйУровеньИСловаVoiceOver() {
        let content = dictationHUDContent(stage: .listening(.dictation),
                                          level: 0.72,
                                          reduceMotion: false,
                                          historyHint: "")
        #expect(content.visual == .init(form: .waveform, accent: .red,
                                        mark: .none, flow: .symmetric, halo: .even))
        #expect(content.level == 0.72)
        #expect(content.title == "слушаю")
        #expect(content.accessibilityLabel.contains("слушаю"))
    }

    @Test func мусорныйУровеньВКонтентеБезопасноОбнуляется() {
        #expect(dictationHUDContent(stage: .listening(.dictation), level: .nan,
                                   reduceMotion: false, historyHint: "").level == 0)
        #expect(dictationHUDContent(stage: .listening(.dictation), level: -.infinity,
                                   reduceMotion: false, historyHint: "").level == 0)
        #expect(dictationHUDContent(stage: .listening(.dictation), level: 5,
                                   reduceMotion: false, historyHint: "").level == 1)
    }

    @Test func скоростьФазыЗависитОтГолосаТолькоПриЗаписи() {
        #expect(dictationHUDPhaseSpeed(stage: .listening(.dictation), level: 0) == 16.96)
        #expect(dictationHUDPhaseSpeed(stage: .listening(.dictation), level: 1) == 27.04)
        #expect(dictationHUDPhaseSpeed(stage: .recognizing, level: 1) == 10.2)
        #expect(dictationHUDPhaseSpeed(stage: .buildingPrompt, level: 1) == 10.2)
        #expect(dictationHUDPhaseSpeed(stage: .inserted, level: 1) == 0)
    }
}

/// Дефект, ради которого всё это: обычная диктовка и промпт-режим выглядели
/// одинаково, ПОКА владелец говорит. Режим проявлялся только на распознавании —
/// то есть когда решать что-то уже поздно.
@Suite("плашка: режим записи виден сразу")
struct DictationHUDPurposeModelTests {

    private let dictation = dictationHUDVisual(for: .listening(.dictation))
    private let prompt = dictationHUDVisual(for: .listening(.prompt))

    /// Четыре независимые оси. Не одна: цвет не работает при дальтонизме и
    /// тонет на светлом фоне, знак не виден боковым зрением, движение
    /// выключается системной настройкой.
    @Test func режимыРазличаютсяПоВсемЧетырёмОсям() {
        #expect(dictation.accent != prompt.accent)
        #expect(dictation.mark != prompt.mark)
        #expect(dictation.flow != prompt.flow)
        #expect(dictation.halo != prompt.halo)
        // Форма при этом ОДНА: обе записи — живая волна, и подменять её
        // значило бы сказать, что происходит что-то другое.
        #expect(dictation.form == prompt.form)
    }

    @Test func промптНесётХолодныйЦветИШеврон() {
        #expect(prompt.accent == .violet)
        #expect(prompt.mark == .chevron)
        #expect(dictation.accent == .red)
        #expect(dictation.mark == .none)
    }

    /// Главное свойство: различие режимов НЕ зависит от анимации. При
    /// «уменьшении движения» движение выключено целиком, а цвет и знак на месте.
    @Test func уменьшениеДвиженияНеСтираетРазличиеРежимов() {
        let still = { (purpose: DictationRecordingPurpose) in
            dictationHUDContent(stage: .listening(purpose),
                                level: 0.6,
                                reduceMotion: true,
                                historyHint: "")
        }
        let quiet = still(.dictation)
        let loud = still(.prompt)
        #expect(!quiet.animatesLevel)
        #expect(!loud.animatesLevel)
        #expect(quiet.visual.accent != loud.visual.accent)
        #expect(quiet.visual.mark != loud.visual.mark)
        #expect(quiet.visual.halo != loud.visual.halo)
    }

    /// Слова тоже разные: цвет и знак видит зрячий, а голосовому доступу режим
    /// положен ровно так же.
    @Test func голосовойДоступТожеСлышитРежим() {
        let plain = dictationHUDContent(stage: .listening(.dictation), level: 0,
                                        reduceMotion: false, historyHint: "")
        let prompt = dictationHUDContent(stage: .listening(.prompt), level: 0,
                                         reduceMotion: false, historyHint: "")
        #expect(plain.title == "слушаю")
        #expect(prompt.title == "слушаю для промпта")
        #expect(plain.accessibilityLabel != prompt.accessibilityLabel)
    }

    /// Режим меняет только внешность. Всё остальное поведение записи — общее,
    /// и разъехаться оно не должно.
    @Test func режимНеТрогаетПоведениеЗаписи() {
        for purpose in [DictationRecordingPurpose.dictation, .prompt] {
            let stage = DictationHUDStage.listening(purpose)
            #expect(dictationHUDIsListening(stage))
            #expect(dictationHUDPollsLevel(stage))
            #expect(!dictationHUDStageIsTerminal(stage))
            #expect(dictationHUDDismissDelay(for: stage) == nil)
            #expect(dictationHUDPhaseSpeed(stage: stage, level: 0) == 16.96)
            #expect(dictationHUDAnimatesLevel(stage: stage, reduceMotion: false))
        }
    }

    /// Шеврон сдвигает волну вправо ровно на половину занятого им места:
    /// «шеврон + волна» стоят по центру ОКНА как одна композиция и не
    /// упираются в его край.
    @Test func шевронИВолнаСтоятПоЦентруОкна() {
        let window = CGRect(origin: .zero, size: DICTATION_HUD_BASE_SIZE)
        let waveStart = window.midX - (DICTATION_HUD_WAVEFORM_WIDTH / 2) + DICTATION_HUD_MARK_SHIFT
        let markLeft = waveStart - DICTATION_HUD_MARK_GAP - DICTATION_HUD_MARK_WIDTH
        let waveEnd = waveStart + DICTATION_HUD_WAVEFORM_WIDTH
        #expect(markLeft > window.minX)
        #expect(waveEnd < window.maxX)
        #expect(abs((markLeft - window.minX) - (window.maxX - waveEnd)) < 0.0001)
    }

    /// Аура сменила ореол по канту: кольца вокруг пилюли нет, свечение обнимает
    /// саму ленту. Смысл прежний, и прежнее ограничение тоже: на полном голосе
    /// оно обязано умереть ВНУТРИ окна, иначе панель срежет его ровно там,
    /// где оно самое яркое.
    /// Ровно ноль на кромке окна обеспечивает поперечное затухание в шейдере
    /// (см. `аураНеДоживаетДоКромкиОкна`). Здесь проверяется, что оно —
    /// СТРАХОВКА, а не костыль: аура обязана сойти на нет сама, иначе затухание
    /// начнёт срезать живое свечение и лента станет плоской у краёв.
    /// Гребень ведёт саму ленту, а не одну юбку свечения: в юбке он тонет
    /// в лоренцевом хвосте нитей, и ось «ход свечения» умирает на экране,
    /// оставаясь живой в модели. Множитель обязан ходить ВОКРУГ ЕДИНИЦЫ —
    /// иначе промпт поедет по общей яркости, а она занята голосом.
    @Test func гребеньПерекладываетСветНеМеняяСреднююЯркость() {
        let mean = dictationHUDHaloRidgeMean()
        #expect(mean > DICTATION_HUD_HALO_FLOOR)
        #expect(mean < 1)
        // Средняя яркость ленты под гребнем — ровно прежняя.
        #expect(abs(dictationHUDHaloRidgeGain(mean) - 1) < 0.0001)
        let trough = dictationHUDHaloRidgeGain(DICTATION_HUD_HALO_FLOOR)
        let crest = dictationHUDHaloRidgeGain(1)
        #expect(trough < 1)
        #expect(crest > 1)
        // Контраст виден глазу, но лента на впадине не проваливается: провал
        // читался бы разрывом, а не течением света.
        #expect(crest / trough > 1.4)
        #expect(crest / trough < 2.0)
        // Мусор на входе не должен ни гасить ленту, ни жечь её.
        #expect(dictationHUDHaloRidgeGain(.nan) == 1)
        #expect(dictationHUDHaloRidge(at: .nan, head: 0) == 1)
    }

    /// Гребень действительно ЕДЕТ: при сдвиге головы максимум яркости уезжает
    /// туда же и ровно на столько же.
    @Test func гребеньЕдетВдольЛентыВместеСГоловой() {
        for head in stride(from: CGFloat(0), to: 1, by: 0.125) {
            let sampled = stride(from: CGFloat(0), to: 1, by: 0.002).map {
                (position: $0, ridge: dictationHUDHaloRidge(at: $0, head: head))
            }
            let brightest = sampled.max { $0.ridge < $1.ridge }?.position ?? -1
            #expect(abs(brightest - head) < 0.01, "гребень не там, где голова: \(head)")
        }
    }

    @Test func аураГаснетСамаНеДожидаясьКромки() {
        let spread = DICTATION_HUD_HALO_SPREAD * (1 + DICTATION_HUD_HALO_VOICE_SPREAD)
        // От гребня ленты до края окна при самом большом размахе.
        let room = (DICTATION_HUD_BASE_SIZE.height / 2)
            - (DICTATION_HUD_RIBBON_PROCESSING_SPAN / 2)
        #expect(room > 0)
        #expect(exp(-room / spread) < 0.10)
    }

}

/// Лента вместо восьми столбиков. Рисование под `swift test` не поднять, но вся
/// математика ленты — чистые функции, и держать её надо здесь.
@Suite("плашка: лента волны")
struct DictationHUDRibbonModelTests {
    @Test func колоколГаситЛентуККраямИНеУходитВМинус() {
        #expect(abs(dictationHUDRibbonEnvelope(x: 0) - 1) < 0.0001)
        #expect(dictationHUDRibbonEnvelope(x: 1) < 0.0001)
        #expect(dictationHUDRibbonEnvelope(x: -1) < 0.0001)
        // Монотонно от центра к краю: лента растворяется, а не гуляет ярусами.
        var previous = dictationHUDRibbonEnvelope(x: 0)
        for step in 1...20 {
            let value = dictationHUDRibbonEnvelope(x: CGFloat(step) / 20)
            #expect(value <= previous + 0.0001)
            #expect(value >= 0)
            previous = value
        }
        // Мусор на входе не должен рисовать ничего.
        #expect(dictationHUDRibbonEnvelope(x: .nan) == 0)
    }

    /// Ось «ход волны» держится САМОЙ формой кривой, а не подсветкой: у обычной
    /// диктовки лента зеркальна относительно центра, у промпта — нет. Поэтому
    /// различие видно и на стоп-кадре, когда движение выключено.
    /// Зеркальность держится на уровне ЛЕНТЫ, а не отдельной нити: нити
    /// разведены по фазе встречно, и при отражении нить `+s` переходит
    /// в нить `−s`. Набор нитей симметричен, поэтому симметрична и лента.
    @Test func симметричныйХодЗеркаленАНаправленныйНет() {
        for phase in stride(from: CGFloat(0), through: 12, by: 0.37) {
            for x in stride(from: CGFloat(0.05), through: 0.95, by: 0.1) {
                for strand in dictationHUDRibbonStrandParameters() {
                    let left = dictationHUDRibbonSample(x: -x, phase: phase, amplitude: 0.7,
                                                        flow: .symmetric, strand: strand)
                    let mirrored = dictationHUDRibbonSample(x: x, phase: phase, amplitude: 0.7,
                                                            flow: .symmetric, strand: -strand)
                    #expect(abs(left - mirrored) < 0.0001)
                }
            }
        }
        // Набор нитей обязан быть симметричным — иначе зеркальность нитей
        // не даёт зеркальности ленты.
        let strands = dictationHUDRibbonStrandParameters()
        for (index, strand) in strands.enumerated() {
            #expect(abs(strand + strands[strands.count - 1 - index]) < 0.0001)
        }

        let asymmetry = stride(from: CGFloat(0.05), through: 0.95, by: 0.1).map { x in
            abs(dictationHUDRibbonSample(x: -x, phase: 0, amplitude: 0.7,
                                         flow: .forward, strand: 0)
                - dictationHUDRibbonSample(x: x, phase: 0, amplitude: 0.7,
                                           flow: .forward, strand: 0))
        }.max() ?? 0
        #expect(asymmetry > 0.2)
    }

    /// Лента никогда не вырождается в прямую на живой записи: плоский кадр
    /// читался бы как «звук пропал», а он не пропадал. Порог 0,3 от полувысоты —
    /// замеренный минимум, не пожелание: у зеркального хода он держится
    /// положительными множителями мод (см. `dictationHUDRibbonSample`).
    ///
    /// Мерится ЛЕНТА целиком, а не каждая нить: развод нитей по вертикали может
    /// погасить одну из крайних, и это нормально — плоской лента станет, только
    /// если лягут все три.
    @Test func лентаНеВыпрямляетсяНиНаОднойФазе() {
        for flow in [DictationHUDWaveFlow.symmetric, .forward] {
            for phase in stride(from: CGFloat(0), through: 60, by: 0.11) {
                let peak = dictationHUDRibbonStrandParameters().flatMap { strand in
                    stride(from: CGFloat(-1), through: 1, by: 0.02).map { x in
                        abs(dictationHUDRibbonSample(x: x, phase: phase, amplitude: 1,
                                                     flow: flow, strand: strand))
                    }
                }.max() ?? 0
                #expect(peak > 0.3)
            }
        }
    }

    /// Главный тест этой правки. Нити разведены ПО ФАЗЕ, и это не то же самое,
    /// что развод по вертикали: вертикальный давал постоянный зазор везде,
    /// то есть одну волну, нарисованную несколько раз рядом — цветную верёвку.
    ///
    /// Фазовый развод обязан давать три вещи разом, и все три проверяются:
    /// где-то нити расходятся во всю высоту, где-то ПЕРЕСЕКАЮТСЯ (зазор меняет
    /// знак), а у торцов сходятся обратно в одну нить. Пропадёт пересечение —
    /// значит развод снова стал параллельным, и владелец снова увидит верёвку.
    @Test func нитиРазведеныПоФазеПересекаютсяИСходятсяУКраёв() {
        let strands = dictationHUDRibbonStrandParameters()
        guard let first = strands.first, let last = strands.last else {
            Issue.record("нитей нет")
            return
        }
        for flow in [DictationHUDWaveFlow.symmetric, .forward] {
            for phase in stride(from: CGFloat(0), through: 30, by: 0.31) {
                let gaps = stride(from: CGFloat(-0.9), through: 0.9, by: 0.01).map { x in
                    dictationHUDRibbonSample(x: x, phase: phase, amplitude: 0.8,
                                             flow: flow, strand: last)
                        - dictationHUDRibbonSample(x: x, phase: phase, amplitude: 0.8,
                                                   flow: flow, strand: first)
                }
                let spread = gaps.map(abs).max() ?? 0
                #expect(spread > 0.25, "нити не расходятся: \(flow) на фазе \(phase)")
                let crosses = zip(gaps, gaps.dropFirst()).contains { $0 * $1 < 0 }
                #expect(crosses, "нити не пересекаются: \(flow) на фазе \(phase)")
                // У самого торца огибающая уже погасила обе, и лента сходится
                // в одну нить — иначе у неё был бы виден расщеплённый конец.
                let edge = abs(dictationHUDRibbonSample(x: 0.995, phase: phase, amplitude: 0.8,
                                                        flow: flow, strand: last)
                               - dictationHUDRibbonSample(x: 0.995, phase: phase, amplitude: 0.8,
                                                          flow: flow, strand: first))
                #expect(edge < 0.01)
            }
        }
    }

    /// Размах не выходит за отведённую полувысоту ни на одной фазе: иначе лента
    /// упёрлась бы в кант пилюли и обрезалась там, где должна быть красивой.
    @Test func лентаНеВыходитЗаСвоюПолувысоту() {
        for flow in [DictationHUDWaveFlow.symmetric, .forward] {
            for strand in dictationHUDRibbonStrandParameters() {
                for phase in stride(from: CGFloat(0), through: 60, by: 0.17) {
                    for x in stride(from: CGFloat(-1), through: 1, by: 0.02) {
                        let value = dictationHUDRibbonSample(x: x, phase: phase, amplitude: 1,
                                                             flow: flow, strand: strand)
                        #expect(abs(value) <= 1.0001)
                    }
                }
            }
        }
    }

    @Test func размахВедётГолосИОнВсегдаЗажат() {
        let quiet = dictationHUDRibbonAmplitude(audio: 0, phase: 0, motion: true)
        let loud = dictationHUDRibbonAmplitude(audio: 1, phase: 0, motion: true)
        #expect(quiet > 0.2)
        #expect(loud > quiet)
        #expect(loud <= 1)
        // Мусор на входе не должен раздувать ленту за пилюлю.
        #expect(dictationHUDRibbonAmplitude(audio: .nan, phase: .nan, motion: true) > 0)
        #expect(dictationHUDRibbonAmplitude(audio: 9, phase: 3, motion: true) <= 1)
        // Без движения дыхания нет, а голос остаётся: уровень видно и на
        // замершей плашке.
        let stillQuiet = dictationHUDRibbonAmplitude(audio: 0, phase: 5, motion: false)
        let stillLoud = dictationHUDRibbonAmplitude(audio: 1, phase: 5, motion: false)
        #expect(stillQuiet == dictationHUDRibbonAmplitude(audio: 0, phase: 99, motion: false))
        #expect(stillLoud > stillQuiet)
    }

    @Test func нитиРазложеныСимметричноАЯдроЯрчеКрыльев() {
        let strands = dictationHUDRibbonStrandParameters()
        #expect(strands.count == DICTATION_HUD_RIBBON_STRANDS)
        #expect(strands.first == -1)
        #expect(strands.last == 1)
        // Ровный шаг и симметрия: на них держится и зеркальность ленты,
        // и то, что выбеленное ядро стоит посередине, а не сбоку.
        for (index, strand) in strands.enumerated() {
            #expect(abs(strand + strands[strands.count - 1 - index]) < 0.0001)
            if index > 0 { #expect(strand > strands[index - 1]) }
        }
        #expect(dictationHUDRibbonStrandParameters(count: 1) == [0])
        #expect(dictationHUDRibbonStrandWeight(0) == 1)
        #expect(dictationHUDRibbonStrandWeight(1) < dictationHUDRibbonStrandWeight(0))
        #expect(dictationHUDRibbonStrandWeight(-1) == dictationHUDRibbonStrandWeight(1))
        #expect(dictationHUDRibbonStrandWeight(1) > 0)
    }

    /// Палитра — выбор владельца, но различие режимов она не отменяет. Разлёт
    /// тонов обязан остаться внутри своего семейства: уползи он на четверть
    /// круга, и промпт оказался бы в цвете диктовки.
    @Test func разлётТоновНеВыводитПалитруИзСвоегоСемейства() {
        for palette in DictationHUDWavePalette.allCases {
            for accent in [DictationHUDAccent.red, .violet, .blue, .cyan,
                           .green, .yellow, .orange, .neutral] {
                for strand in dictationHUDRibbonStrandParameters() {
                    let offset = dictationHUDRibbonHueOffset(palette: palette,
                                                             accent: accent,
                                                             strand: strand)
                    // Четверть круга — предел, за которым тон уезжает
                    // в чужое семейство. Сам разлёт широкий: на нём держится
                    // призма, ради которой всё и делается.
                    #expect(abs(offset) <= 0.23)
                }
            }
        }
    }

    /// Семейства режимов НЕ ПЕРЕСЕКАЮТСЯ по кругу. Цвет — одна из четырёх осей
    /// различия диктовки и промпта, и широкий разлёт не имеет права её съесть:
    /// диктовка обязана остаться тёплой целиком, промпт холодным целиком.
    ///
    /// Базовые тона сняты с `color(for:)` (DictationHUDCapsule.swift) —
    /// systemRed и фиолетовый промпта. Меняете акцент — меняйте и здесь: тест
    /// проверяет РАЗЛЁТ, а не саму палитру.
    @Test func семействаРежимовНеПересекаютсяПоКругу() {
        let dictationHue: CGFloat = 0.009
        let promptHue: CGFloat = 0.691
        func family(_ base: CGFloat, _ accent: DictationHUDAccent) -> [CGFloat] {
            dictationHUDRibbonStrandParameters().map { strand in
                let shifted = base + dictationHUDRibbonHueOffset(palette: .spectral,
                                                                 accent: accent,
                                                                 strand: strand)
                let wrapped = shifted.truncatingRemainder(dividingBy: 1)
                return wrapped < 0 ? wrapped + 1 : wrapped
            }
        }
        func distance(_ one: CGFloat, _ other: CGFloat) -> CGFloat {
            let raw = abs(one - other).truncatingRemainder(dividingBy: 1)
            return min(raw, 1 - raw)
        }
        let warm = family(dictationHue, .red)
        let cold = family(promptHue, .violet)
        let gap = warm.flatMap { one in cold.map { distance(one, $0) } }.min() ?? 0
        // Десятая круга (36°) — запас, а не совпадение: на кадрах раскадровки
        // зазор 0,14 круга, и тёплое от холодного видно без сомнений.
        #expect(gap > 0.10, "семейства сошлись: зазор \(gap)")
        // И ни одна нить промпта не заходит в тёплую половину круга.
        for hue in cold { #expect(hue > 0.4 && hue < 0.85) }
        for hue in warm { #expect(hue > 0.85 || hue < 0.25) }
    }

    @Test func монохромНеРасслаиваетсяАСпокойнаяУжеПереливов() {
        let strands = dictationHUDRibbonStrandParameters()
        for strand in strands {
            #expect(dictationHUDRibbonHueOffset(palette: .mono, accent: .red,
                                                strand: strand) == 0)
        }
        let spectral = strands.map {
            abs(dictationHUDRibbonHueOffset(palette: .spectral, accent: .red, strand: $0))
        }.max() ?? 0
        let calm = strands.map {
            abs(dictationHUDRibbonHueOffset(palette: .calm, accent: .red, strand: $0))
        }.max() ?? 0
        #expect(spectral > calm)
        #expect(calm > 0)
    }

    /// Тёплые тона разлетаются в обе стороны, холодные — только внутрь холодной
    /// половины. Симметричный разлёт увёл бы фиолетовый промпта в пурпур, то
    /// есть вплотную к розовому краю диктовки.
    @Test func холодныеТонаНеУползаютВПурпур() {
        let strands = dictationHUDRibbonStrandParameters()
        let warm = strands.map {
            dictationHUDRibbonHueOffset(palette: .spectral, accent: .red, strand: $0)
        }
        // Тёплое идёт в ОБЕ стороны — иначе это не разлёт, а простой сдвиг
        // тона, — но к янтарю дальше, чем к пурпуру: пурпур уже пограничье
        // с холодным семейством.
        #expect(warm.first! < 0)
        #expect(warm.last! > 0)
        #expect(warm.last! > abs(warm.first!))
        #expect(warm.last! < abs(warm.first!) * 2)

        // Фиолетовому вниз — к синему и голубому: вверх от него пурпур.
        let violet = strands.map {
            dictationHUDRibbonHueOffset(palette: .spectral, accent: .violet, strand: $0)
        }
        #expect(abs(violet.first!) > abs(violet.last!) * 2)
        // Синему и голубому наоборот вверх: под голубым начинается зелень,
        // а она уже занята исходом «вставил».
        for accent in [DictationHUDAccent.blue, .cyan] {
            let cool = strands.map {
                dictationHUDRibbonHueOffset(palette: .spectral, accent: accent, strand: $0)
            }
            #expect(abs(cool.last!) > abs(cool.first!))
        }
    }

    /// Ядро ленты подмешано к белому, крылья — нет. Пересечение выбеленных
    /// нитей глаз читает светом; четыре одинаково насыщенные читаются краской.
    @Test func кБеломуПодмешаныТолькоВнутренниеНити() {
        let strands = dictationHUDRibbonStrandParameters()
        #expect(dictationHUDRibbonWhiteMix(strand: 1) == 0)
        #expect(dictationHUDRibbonWhiteMix(strand: -1) == 0)
        #expect(dictationHUDRibbonWhiteMix(strand: 0) == DICTATION_HUD_RIBBON_CORE_WHITE)
        for strand in strands where abs(strand) < 1 {
            #expect(dictationHUDRibbonWhiteMix(strand: strand) > 0)
            // Выбеливание никогда не съедает тон целиком: иначе лента стала бы
            // белой, а вместе с тоном ушла бы и ось различия режимов.
            #expect(dictationHUDRibbonWhiteMix(strand: strand) < 0.5)
        }
        #expect(dictationHUDRibbonWhiteMix(strand: .nan) == 0)
    }

    @Test func укаждойПалитрыЕстьЧестноеРусскоеИмя() {
        var titles: Set<String> = []
        for palette in DictationHUDWavePalette.allCases {
            let title = dictationHUDWavePaletteTitle(palette)
            #expect(!title.isEmpty)
            #expect(!dictationHUDHasLatin(title))
            titles.insert(title)
        }
        #expect(titles.count == DictationHUDWavePalette.allCases.count)
        #expect(DICTATION_HUD_DEFAULT_WAVE_PALETTE == .spectral)
    }
}

@Suite("плашка: подсказки")
struct DictationHUDHintModelTests {
    private func lines(_ stage: DictationHUDStage,
                       mode: TriggerMode = .toggle,
                       drag: Bool = false) -> [String] {
        dictationHUDHintLines(stage: stage,
                             triggerMode: mode,
                             hotkeyLabel: "правый ⌘",
                             historyLabel: "правый ⌘ + ⇧",
                             showsDragHint: drag)
    }

    @Test func записьОбъясняетToggleИHoldБезЛожногоДействияМышью() {
        #expect(lines(.listening(.dictation), mode: .toggle, drag: true)
                == ["правый ⌘ — закончить", "Esc — отменить"])
        #expect(lines(.listening(.dictation), mode: .hold, drag: true)
                == ["отпустите правый ⌘", "Esc — отменить"])
    }

    @Test func всеРабочиеИТерминальныеСтадииИмеютПравдивыеСтроки() {
        let expected: [(DictationHUDStage, [String])] = [
            (.recognizing, ["идёт распознавание"]),
            (.buildingPrompt, ["собираю промпт"]),
            (.inserted, ["вставил"]),
            (.notDelivered(.insertionFailed), ["текст не вставился", "правый ⌘ + ⇧ — история"]),
            (.nothingRecognized(savedToHistory: true), ["ничего не разобрал", "правый ⌘ + ⇧ — история"]),
            (.nothingRecognized(savedToHistory: false), ["ничего не услышал"]),
            (.recognitionTimedOut, ["не успел распознать"]),
            (.recognitionFailed(savedToHistory: true), ["сбой распознавания", "правый ⌘ + ⇧ — история"]),
            (.recognitionFailed(savedToHistory: false), ["сбой распознавания", "запись не сохранилась"]),
            (.promptFailed(.invalidResult), ["ответ агента отклонён", "повторите; надиктовка в истории (правый ⌘ + ⇧)"]),
            (.promptNotDelivered(.insertionFailed), ["промпт сохранён", "скопируйте из истории: правый ⌘ + ⇧"]),
            (.promptSavedAfterFocusChange, ["промпт сохранён", "окно сменилось; история: правый ⌘ + ⇧"]),
            (.refused(.modelNotReady), ["модель ещё греется"]),
        ]

        for (stage, expectedLines) in expected {
            #expect(lines(stage) == expectedLines)
        }
    }

    @Test func подсказкаПеретаскиванияТолькоЗаполняетСвободнуюВторуюСтроку() {
        #expect(lines(.recognizing, drag: true)
                == ["идёт распознавание", "мышью — переставить"])
        #expect(lines(.notDelivered(.insertionFailed), drag: true).count == 2)
        #expect(dictationHUDShowsDragHint(shownCount: 4))
        #expect(!dictationHUDShowsDragHint(shownCount: 5))
    }

    @Test func пустыеПодписиКлавишНеСоздаютОборваннуюФразу() {
        let toggle = dictationHUDHintLines(stage: .listening(.dictation),
                                           triggerMode: .toggle,
                                           hotkeyLabel: "",
                                           historyLabel: "",
                                           showsDragHint: false)
        let failed = dictationHUDHintLines(stage: .notDelivered(.insertionFailed),
                                           triggerMode: .toggle,
                                           hotkeyLabel: "",
                                           historyLabel: "",
                                           showsDragHint: false)
        #expect(toggle == ["закончить запись", "Esc — отменить"])
        #expect(failed == ["текст не вставился", "запись в истории"])
    }
}

@Suite("плашка: геометрия позиции")
struct DictationHUDPositionModelTests {
    private let screen = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
    private let size = CGSize(width: 73.6, height: 43.7)

    @Test func отсутствующийСохранённыйМониторЗаменяетсяЭкраномПодКурсором() {
        let position = CGPoint(x: 0.25, y: 0.75)
        #expect(dictationHUDRestoredDisplayID(savedPosition: position,
                                              savedDisplayID: 42,
                                              availableDisplayIDs: [7, 9],
                                              cursorDisplayID: 9) == 9)
        #expect(dictationHUDRestoredDisplayID(savedPosition: position,
                                              savedDisplayID: 7,
                                              availableDisplayIDs: [7, 9],
                                              cursorDisplayID: 9) == 7)
        #expect(dictationHUDRestoredDisplayID(savedPosition: nil,
                                              savedDisplayID: 7,
                                              availableDisplayIDs: [7, 9],
                                              cursorDisplayID: 9) == 9)
    }

    @Test func долиИВосстановлениеДаютОбратимыйПуть() {
        let original = CGRect(x: -1200, y: 420, width: size.width, height: size.height)
        let fraction = dictationHUDPositionFraction(frame: original, in: screen)
        let restored = dictationHUDRestoredFrame(size: size, fraction: fraction, in: screen)
        #expect(abs(restored.midX - original.midX) < 0.0001)
        #expect(abs(restored.midY - original.midY) < 0.0001)
    }

    @Test func восстановлениеМусорнойДолиВсегдаВозвращаетПлашкуНаЭкран() {
        let restored = dictationHUDRestoredFrame(size: size,
                                                 fraction: CGPoint(x: 4, y: -3),
                                                 in: screen)
        #expect(screen.contains(restored))
        #expect(restored.minX >= screen.minX + DICTATION_HUD_EDGE_INSET)
        #expect(restored.minY >= screen.minY + DICTATION_HUD_EDGE_INSET)
    }

    @Test func уменьшениеЭкранаНеВыкидываетПлашку() {
        let small = CGRect(x: 0, y: 0, width: 640, height: 360)
        let restored = dictationHUDRestoredFrame(size: size,
                                                 fraction: CGPoint(x: 0.91, y: 0.88),
                                                 in: small)
        #expect(small.contains(restored))
    }

    @Test func огромныйКадрНеДаётОтрицательныхРазмеров() {
        let tiny = CGRect(x: 10, y: 20, width: 16, height: 9)
        let clamped = dictationHUDClampedFrame(CGRect(x: -100, y: -100,
                                                      width: 1000, height: 1000),
                                               in: tiny)
        #expect(clamped.width >= 0)
        #expect(clamped.height >= 0)
        #expect(tiny.contains(clamped))
    }

    @Test func близкаяКромкаПрилипаетКДвенадцатиПунктам() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let left = dictationHUDSnappedFrame(CGRect(x: 7, y: 300,
                                                   width: size.width, height: size.height),
                                            in: visible)
        let top = dictationHUDSnappedFrame(CGRect(x: 300,
                                                  y: visible.maxY - size.height - 5,
                                                  width: size.width, height: size.height),
                                           in: visible)
        #expect(left.minX == 12)
        #expect(top.maxY == visible.maxY - 12)
    }
}

@Suite("плашка: движение модели")
struct DictationHUDAnimationModelTests {
    @Test func smootherstepЗажатИСимметричен() {
        #expect(dictationHUDSmootherstep(edge0: 0, edge1: 1, value: -1) == 0)
        #expect(dictationHUDSmootherstep(edge0: 0, edge1: 1, value: 2) == 1)
        #expect(abs(dictationHUDSmootherstep(edge0: 0, edge1: 1, value: 0.5) - 0.5) < 0.0001)
    }

    @Test func revealПерелетаетИОседаетВЕдиницу() {
        let hidden = dictationHUDRevealLayers(progress: 0)
        let overshoot = dictationHUDRevealLayers(progress: 0.68)
        let shown = dictationHUDRevealLayers(progress: 1)
        #expect(hidden.scale == 0)
        #expect(abs(overshoot.scale - 1.1) < 0.0001)
        #expect(abs(shown.scale - 1) < 0.0001)
        #expect(shown.backgroundAlpha == 1)
        #expect(shown.contentAlpha == 1)
        #expect(shown.breathAlpha == 1)
    }

    @Test func hoverОткрываетПлитуПослеНачалаТаймлайна() {
        #expect(dictationHUDHoverLayers(progress: 0).plateAlpha == 0)
        let shown = dictationHUDHoverLayers(progress: 1)
        #expect(shown.plateAlpha == 1)
        #expect(shown.plateOffset == 6)
        #expect(shown.windowProgress == 1)
    }

    @Test func прерваннаяАнимацияМасштабируетсяПоОстаткуПути() {
        let duration = dictationHUDAnimationDuration(base: 0.23, from: 0.4, to: 0)
        #expect(abs(duration - 0.092) < 0.0001)
        #expect(dictationHUDAnimationDuration(base: 0.23, from: 1, to: 1) == 1.0 / 120)
    }

    @Test func displayLinkНеЖивётНаСтатичномИсходе() {
        #expect(dictationHUDNeedsDisplayLink(stage: .listening(.dictation),
                                            revealAnimating: false,
                                            hoverAnimating: false,
                                            reduceMotion: false))
        #expect(!dictationHUDNeedsDisplayLink(stage: .inserted,
                                             revealAnimating: false,
                                             hoverAnimating: false,
                                             reduceMotion: false))
        #expect(dictationHUDNeedsDisplayLink(stage: .inserted,
                                            revealAnimating: true,
                                            hoverAnimating: false,
                                            reduceMotion: false))
        #expect(!dictationHUDNeedsDisplayLink(stage: .listening(.dictation),
                                             revealAnimating: true,
                                             hoverAnimating: true,
                                             reduceMotion: true))
        #expect(!dictationHUDNeedsDisplayLink(stage: nil,
                                             revealAnimating: true,
                                             hoverAnimating: true,
                                             reduceMotion: false))
    }

    @Test func уровеньБыстроАтакуетИПлавнееСпадает() {
        let rising = dictationHUDSmoothedLevel(previous: 0, raw: 1)
        let falling = dictationHUDSmoothedLevel(previous: 1, raw: 0)
        #expect(abs(rising - 0.65) < 0.0001)
        #expect(abs(falling - 0.72) < 0.0001)
        #expect(rising > 0)
        #expect(falling > rising)
    }

    @Test func залипшийSequenceПротухаетТолькоПослеВосьмиТиков() {
        #expect(!dictationHUDLevelIsStale(sameSequenceTicks: 8))
        #expect(dictationHUDLevelIsStale(sameSequenceTicks: 9))
    }
}

@Suite("плашка: сохранённая позиция")
struct DictationHUDSettingsModelTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "ru.smltlk.hud-model-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { removeSuiteFile(named: name, defaults: defaults) }
        body(defaults)
    }

    @Test func пустыеНастройкиНеПритворяютсяСохранённойПозицией() {
        withDefaults { defaults in
            let settings = DictationSettings(defaults: defaults)
            #expect(settings.dictationHUDPositionFraction == nil)
            #expect(settings.dictationHUDPositionDisplayID == nil)
            #expect(settings.dictationHUDHintShownCount == 0)
        }
    }

    @Test func позицияИДисплейСохраняютсяВместеИДолиЗажимаются() {
        withDefaults { defaults in
            let settings = DictationSettings(defaults: defaults)
            settings.saveDictationHUDPosition(fraction: CGPoint(x: -2, y: 3), displayID: 42)
            #expect(settings.dictationHUDPositionFraction == CGPoint(x: 0, y: 1))
            #expect(settings.dictationHUDPositionDisplayID == 42)
        }
    }

    @Test func частичнаяИлиМусорнаяПозицияЧитаетсяКакОтсутствующая() {
        withDefaults { defaults in
            defaults.set(0.4, forKey: "dictation_hud_position_fraction_x")
            #expect(DictationSettings(defaults: defaults).dictationHUDPositionFraction == nil)

            defaults.set(Double.nan, forKey: "dictation_hud_position_fraction_y")
            #expect(DictationSettings(defaults: defaults).dictationHUDPositionFraction == nil)
        }
    }

    @Test func очисткаУдаляетВесьЯкорь() {
        withDefaults { defaults in
            let settings = DictationSettings(defaults: defaults)
            settings.saveDictationHUDPosition(fraction: CGPoint(x: 0.3, y: 0.8), displayID: 7)
            settings.clearDictationHUDPosition()
            #expect(settings.dictationHUDPositionFraction == nil)
            #expect(settings.dictationHUDPositionDisplayID == nil)
        }
    }

    @Test func счётчикПодсказкиНеУходитВМинусИИнкрементируется() {
        withDefaults { defaults in
            let settings = DictationSettings(defaults: defaults)
            settings.dictationHUDHintShownCount = -4
            #expect(settings.dictationHUDHintShownCount == 0)
            settings.incrementDictationHUDHintShownCount()
            #expect(settings.dictationHUDHintShownCount == 1)
        }
    }

    /// Мусор в ключе палитры не должен молча менять вид плашки: неизвестное
    /// значение читается как заводское, а не как «что-нибудь».
    @Test func палитраЛентыХранитсяИПадаетНаЗаводскуюПриМусоре() {
        withDefaults { defaults in
            let settings = DictationSettings(defaults: defaults)
            #expect(settings.dictationHUDWavePalette == DICTATION_HUD_DEFAULT_WAVE_PALETTE)
            settings.dictationHUDWavePalette = .mono
            #expect(DictationSettings(defaults: defaults).dictationHUDWavePalette == .mono)

            defaults.set("радуга", forKey: "dictation_hud_wave_palette_v1")
            #expect(DictationSettings(defaults: defaults).dictationHUDWavePalette
                    == DICTATION_HUD_DEFAULT_WAVE_PALETTE)
        }
    }
}
