// Тесты плашки «идёт голос».
//
// Живую панель под тест-раннером не поднять (нет NSApplication, нет
// WindowServer у ad-hoc бинаря `swift test`), поэтому проверяются РЕШЕНИЯ
// (DictationHUD.swift) и ПОРЯДОК показа (DictationHUDPresenter.swift) через
// заглушку поверхности. Живьём плашку смотрит координатор.
import IrizCore
import CoreGraphics
import Foundation
import Testing

@testable import IrizDictate

// MARK: - Состояние конвейера → плашка

@Suite("плашка: состояние конвейера")
struct DictationHUDPresentationTests {

    @Test func записьПоказываетУровень() {
        #expect(dictationHUDPresentation(pipelineState: .recording, purpose: .dictation, current: nil)
                == .visible(.listening(.dictation)))
    }

    @Test func распознаваниеПоказываетОжидание() {
        #expect(dictationHUDPresentation(pipelineState: .transcribing, purpose: .dictation, current: .listening(.dictation))
                == .visible(.recognizing))
    }

    @Test func сборкаПромптаИмеетСвоёСостояние() {
        #expect(dictationHUDPresentation(pipelineState: .generatingPrompt, purpose: .dictation, current: .recognizing)
                == .visible(.buildingPrompt))
        #expect(!dictationHUDStageIsTerminal(.buildingPrompt))
        #expect(dictationHUDAnimatesWaiting(stage: .buildingPrompt, reduceMotion: false))
    }

    /// Работы нет - плашка стоит в покое. Решение владельца 06.09.2026:
    /// «Она должна быть всегда». Прежде эта же проба требовала обратного -
    /// `.hidden`, то есть снос окна; правило перевёрнуто целиком, а не снято.
    @Test func безРаботыПлашкаСтоитВПокое() {
        #expect(dictationHUDPresentation(pipelineState: .ready, purpose: .dictation, current: nil)
                == .visible(.resting))
        #expect(dictationHUDPresentation(pipelineState: .warmingUp, purpose: .dictation, current: nil)
                == .visible(.resting))
        #expect(dictationHUDPresentation(pipelineState: .unavailable("нет разрешения"), purpose: .dictation, current: nil)
                == .visible(.resting))
    }

    /// Ни одно состояние конвейера не имеет права дать пустоту: пустота для
    /// презентера значит снос окна, и «всегда» кончилось бы на первом же таком
    /// исходе. Проба перебирает ВСЕ состояния во ВСЕХ режимах.
    @Test func ниОдноСостояниеНеГаситПлашку() {
        let states: [DictationController.State] = [
            .ready, .warmingUp, .unavailable("нет разрешения"),
            .recording, .transcribing, .generatingPrompt,
        ]
        let stages: [DictationHUDStage?] = [
            nil, .resting, .listening(.dictation), .recognizing, .buildingPrompt,
            .inserted, .notDelivered(.insertionFailed), .refused(.secureInputActive),
        ]
        for state in states {
            for stage in stages {
                #expect(dictationHUDPresentation(pipelineState: state,
                                                 purpose: .dictation,
                                                 current: stage) != .hidden)
            }
        }
    }

    /// Покой не уходит по таймеру: у него нет срока жизни.
    @Test func уПокояНетСрокаЖизни() {
        #expect(dictationHUDDismissDelay(for: .resting) == nil)
        #expect(!dictationHUDStageIsTerminal(.resting))
        // И не крутит display link: постоянная плашка с дыханием ленты стоила
        // бы 120 Гц круглосуточно.
        #expect(dictationHUDPhaseSpeed(stage: .resting, level: 1) == 0)
        #expect(!dictationHUDPollsLevel(.resting))
    }

    /// `.ready` приходит сразу за вердиктом доставки. Если бы он гасил плашку,
    /// «не вставилось» мигнуло бы на кадр — то есть главное сообщение продукта
    /// владелец бы не прочитал.
    @Test func покойНеГаситТерминальнуюПлашку() {
        let terminal: [DictationHUDStage] = [
            .inserted,
            .notDelivered(.targetNeverRequestedText),
            .nothingRecognized(savedToHistory: true),
            .recognitionTimedOut,
            .recognitionFailed(savedToHistory: false),
            .refused(.secureInputActive),
        ]
        for stage in terminal {
            #expect(dictationHUDPresentation(pipelineState: .ready, purpose: .dictation, current: stage)
                    == .visible(stage))
        }
    }

    /// Рабочая плашка на покое обязана СМЕНИТЬСЯ покоем, а не исчезнуть.
    @Test func рабочаяПлашкаСменяетсяПокоем() {
        #expect(dictationHUDPresentation(pipelineState: .ready, purpose: .dictation, current: .listening(.dictation))
                == .visible(.resting))
        #expect(dictationHUDPresentation(pipelineState: .ready, purpose: .dictation, current: .recognizing)
                == .visible(.resting))
    }

    @Test func новаяЗаписьСменяетСтаруюТерминальнуюПлашку() {
        #expect(dictationHUDPresentation(pipelineState: .recording, purpose: .dictation, current: .notDelivered(.insertionFailed))
                == .visible(.listening(.dictation)))
    }

    @Test func терминальностьРазделенаВерно() {
        #expect(!dictationHUDStageIsTerminal(.listening(.dictation)))
        #expect(!dictationHUDStageIsTerminal(.recognizing))
        #expect(dictationHUDStageIsTerminal(.inserted))
        #expect(dictationHUDStageIsTerminal(.notDelivered(.deliveryNotObservable)))
        #expect(dictationHUDStageIsTerminal(.nothingRecognized(savedToHistory: false)))
        #expect(dictationHUDStageIsTerminal(.recognitionTimedOut))
        #expect(dictationHUDStageIsTerminal(.recognitionFailed(savedToHistory: true)))
        #expect(dictationHUDStageIsTerminal(.promptFailed(.invalidResult)))
        #expect(dictationHUDStageIsTerminal(.promptNotDelivered(.insertionFailed)))
        #expect(dictationHUDStageIsTerminal(.promptSavedAfterFocusChange))
        #expect(dictationHUDStageIsTerminal(.refused(.modelNotReady)))
    }
}

// MARK: - Вердикт доставки и отказы

@Suite("плашка: вердикт и отказы")
struct DictationHUDVerdictTests {

    @Test func подтверждённаяДоставкаПоказываетВставил() {
        #expect(dictationHUDStage(forDeliveryVerdict: .delivered) == .inserted)
    }

    /// Каждый вид провала доставки — «не вставилось», с сохранением класса
    /// провала: он уходит в подпись голосового доступа и в лог.
    @Test func каждыйПровалДоставкиГоворитНеВставилось() {
        let failures: [TextInsertionFailure] = [
            .insertionFailed, .targetNeverRequestedText, .deliveryNotObservable,
        ]
        for failure in failures {
            #expect(dictationHUDStage(forDeliveryVerdict: .notDelivered(failure))
                    == .notDelivered(failure))
        }
    }

    /// Неразрешённый вердикт для владельца — то же «не вставилось»: цель текст
    /// так и не забрала.
    @Test func неразрешённыйВердиктЭтоТожеНеВставилось() {
        #expect(dictationHUDStage(forDeliveryVerdict: .waiting)
                == .notDelivered(.targetNeverRequestedText))
    }

    /// Причина названа у ВСЕХ отказов - она идёт в лог и в историю. Но плашкой
    /// показываются только настоящие: `transcriptionInFlight` отсюда убран
    /// 04.09.2026, после того как владелец увидел живьём красную ошибку и
    /// следом зелёную галочку успешной вставки. Он нажал клавишу второй раз во
    /// время расшифровки первой; работа шла и дошла, а плашка соврала, что всё
    /// сорвалось.
    @Test func каждыйОтказПоказываетПричину() {
        let shown: [DictationStartRefusal] = [.secureInputActive, .modelNotReady]
        for refusal in shown {
            #expect(dictationHUDStage(forStartRefusal: refusal) == .refused(refusal))
        }
        for refusal in [DictationStartRefusal.secureInputActive, .modelNotReady,
                        .transcriptionInFlight, .alreadyRecording] {
            #expect(!dictationHUDRefusalReason(refusal).isEmpty, "\(refusal) без причины в логе")
        }
    }

    /// «Уже записываю» плашкой не показывается: запись идёт, на экране «слушаю»,
    /// и подменять его отказом значит соврать, что запись прервалась.
    ///
    /// Утверждение переписано: раньше тест требовал `.hidden`, то есть закреплял
    /// в контракте гашение живой панели посреди идущей записи — ровно обратное
    /// собственному комментарию. `nil` — «оставить как есть», и это ровно то, что
    /// комментарий и обещает.
    @Test func отказУжеЗаписываюПлашкуНеМеняет() {
        #expect(dictationHUDStage(forStartRefusal: .alreadyRecording) == nil)
    }
}

// MARK: - Опрос непрерывного уровня

@Suite("плашка: уровень голоса")
struct DictationHUDLevelTests {
    @Test func уровеньОпрашиваетсяТолькoВЗаписи() {
        #expect(dictationHUDPollsLevel(.listening(.dictation)))
        #expect(!dictationHUDPollsLevel(.recognizing))
        #expect(!dictationHUDPollsLevel(.inserted))
        #expect(!dictationHUDPollsLevel(.recognitionFailed(savedToHistory: false)))
        #expect(!dictationHUDPollsLevel(.notDelivered(.insertionFailed)))
        #expect(!dictationHUDPollsLevel(.refused(.modelNotReady)))
    }
}

// MARK: - Уменьшение движения

@Suite("плашка: уменьшение движения")
struct DictationHUDMotionTests {

    @Test func приУменьшенииДвиженияАнимацияНеЗапрашивается() {
        #expect(!dictationHUDAnimatesLevel(stage: .listening(.dictation), reduceMotion: true))
        #expect(!dictationHUDAnimatesWaiting(stage: .recognizing, reduceMotion: true))
        let content = dictationHUDContent(stage: .listening(.dictation),
                                          level: 0.7,
                                          reduceMotion: true,
                                          historyHint: "правый ⌘ + ⇧")
        #expect(!content.animatesLevel)
        #expect(!content.animatesWaiting)
        // Уровень при этом всё равно показывается — просто без анимации.
        #expect(content.level == 0.7)
    }

    @Test func безУменьшенияДвиженияАнимацияТолькоГдеНужна() {
        #expect(dictationHUDAnimatesLevel(stage: .listening(.dictation), reduceMotion: false))
        #expect(!dictationHUDAnimatesLevel(stage: .recognizing, reduceMotion: false))
        #expect(dictationHUDAnimatesWaiting(stage: .recognizing, reduceMotion: false))
        #expect(!dictationHUDAnimatesWaiting(stage: .listening(.dictation), reduceMotion: false))
    }

    /// Распознавание не принимает голосовой уровень ни при каком режиме движения.
    @Test func распознаваниеНеПринимаетГолосовойУровень() {
        for reduceMotion in [true, false] {
            let content = dictationHUDContent(stage: .recognizing,
                                              level: 0.9,
                                              reduceMotion: reduceMotion,
                                              historyHint: "")
            #expect(content.level == 0)
            #expect(!content.animatesLevel)
        }
    }
}

// MARK: - Слова

@Suite("плашка: слова")
struct DictationHUDTextTests {

    @Test func каждоеСостояниеИмеетКороткийРусскийЗаголовок() {
        let stages: [DictationHUDStage] = [
            .listening(.dictation), .listening(.prompt),
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
            let title = dictationHUDTitle(for: stage)
            #expect(!title.isEmpty)
            #expect(title.count <= 24)
            // Латиница допустима только в собственных именах продуктов и клавиши fn.
            #expect(!hasForeignWords(title))
        }
    }

    /// Прежний тест на латиницу прогонял только заголовки, а они собраны
    /// вручную. Английское имя клавиши приезжает во ВТОРУЮ строку из настроек
    /// хоткея, поэтому проверяем деталь — и по всем клавишам, какие владелец
    /// вообще может назначить на историю.
    @Test func деталиПлашкиБезЛатиницыПриЛюбойКлавише() {
        let stages: [DictationHUDStage] = [
            .notDelivered(.insertionFailed),
            .nothingRecognized(savedToHistory: true),
            .recognitionFailed(savedToHistory: true),
            .recognitionFailed(savedToHistory: false),
            .refused(.transcriptionInFlight),
        ]
        for raw in 0...255 {
            let hint = dictationHUDHistoryHint(keycode: CGKeyCode(raw),
                                               modifiers: [.maskCommand, .maskShift])
            #expect(!hasForeignWords(hint))
            for stage in stages {
                let content = dictationHUDContent(stage: stage, level: 0,
                                                  reduceMotion: false, historyHint: hint)
                #expect(!dictationHUDHasLatin(content.title))
                #expect(!hasForeignWords(content.detail ?? ""))
                #expect(!hasForeignWords(content.accessibilityLabel))
            }
        }
    }

    /// Латиница, которую владелец видит законно: имя самого продукта и `fn` —
    /// так эта клавиша напечатана на Mac, и «фн» было бы переводом того, чего на
    /// клавиатуре нет. Всё прочее английское в плашке — дефект.
    private func hasForeignWords(_ text: String) -> Bool {
        let cleaned = text
            .replacingOccurrences(of: IRIZ_NAME, with: "")
            .replacingOccurrences(of: "fn", with: "")
        return dictationHUDHasLatin(cleaned)
    }

    /// Упавшее распознавание — сообщение об утрате, а не о задержке, и про
    /// историю оно врать не имеет права: при `savedToHistory: false` сырья на
    /// диске нет вообще.
    @Test func сбойРаспознаванияПроИсториюНеВрёт() throws {
        let saved = dictationHUDContent(stage: .recognitionFailed(savedToHistory: true),
                                        level: 0, reduceMotion: false, historyHint: "правый ⌘")
        let lost = dictationHUDContent(stage: .recognitionFailed(savedToHistory: false),
                                       level: 0, reduceMotion: false, historyHint: "правый ⌘")
        #expect(try #require(saved.detail).contains("истории"))
        let lostDetail = try #require(lost.detail)
        #expect(!lostDetail.contains("истории"))
        // Молчать тоже нельзя: экран обязан сказать, что надиктовки не осталось.
        #expect(!lostDetail.isEmpty)
        #expect(saved.visual == .init(form: .exclamation, accent: .yellow))
        #expect(lost.visual == .init(form: .exclamation, accent: .yellow))
        // «Сбой» и «не успел» — разные факты и разные слова.
        #expect(saved.title != dictationHUDTitle(for: .recognitionTimedOut))
    }

    @Test func исходыПромптаГоворятПравду() throws {
        let failed = dictationHUDContent(stage: .promptFailed(.invalidResult),
                                         level: 0, reduceMotion: false, historyHint: "правый ⌘ + ⇧")
        #expect(failed.title == "ответ агента отклонён")
        #expect(try #require(failed.detail).contains("истории"))
        #expect(failed.visual == .init(form: .exclamation, accent: .yellow))

        let saved = dictationHUDContent(stage: .promptSavedAfterFocusChange,
                                        level: 0, reduceMotion: false, historyHint: "")
        #expect(saved.title == "промпт сохранён")
        #expect(try #require(saved.detail).contains("окно сменилось"))
        #expect(saved.visual == .init(form: .historyLine, accent: .green))
    }

    @Test func каждыйСбойПромптаГоворитЧтоСлучилосьИЧтоДелать() throws {
        let expected: [(PromptFailureKind, String, String)] = [
            (.executableConfiguration, "агент не настроен", "проверьте путь в настройках"),
            (.launchRuntime, "агент не сработал", "повторите"),
            (.timeout, "агент не успел", "повторите"),
            (.invalidResult, "ответ агента отклонён", "повторите"),
            (.artifactConflict, "промпт уже сохранён", "ничего не заменил"),
        ]

        for (kind, title, action) in expected {
            let content = dictationHUDContent(
                stage: .promptFailed(kind),
                level: 0,
                reduceMotion: false,
                historyHint: "правый ⌘ + ⇧"
            )
            #expect(content.title == title)
            let detail = try #require(content.detail)
            #expect(detail.contains(action))
            #expect(detail.contains("истори"))
            for forbidden in ["stderr", "JSON", "{", "}", "СЕКРЕТ"] {
                #expect(!content.title.contains(forbidden))
                #expect(!detail.contains(forbidden))
                #expect(!content.accessibilityLabel.contains(forbidden))
            }
        }
    }

    @Test func провалВставкиПромптаОтделёнОтСменыФокуса() throws {
        for verdict in [
            TextInsertionVerdict.waiting,
            .notDelivered(.insertionFailed),
            .notDelivered(.deliveryNotObservable),
        ] {
            let stage = dictationHUDStage(forPromptDeliveryVerdict: verdict)
            guard case .promptNotDelivered = stage else {
                Issue.record("провал вставки подменён другим исходом: \(stage)")
                continue
            }
            let content = dictationHUDContent(stage: stage,
                                              level: 0,
                                              reduceMotion: false,
                                              historyHint: "правый ⌘ + ⇧")
            #expect(content.title == "промпт сохранён")
            #expect(try #require(content.detail).contains("скопируйте"))
        }

        #expect(dictationHUDStage(forPromptDeliveryVerdict: .delivered) == .inserted)
        #expect(DictationHUDStage.promptSavedAfterFocusChange
                != .promptNotDelivered(.insertionFailed))
    }

    /// «Не вставилось» обязано сказать это словами и подсказать, где лежит запись.
    @Test func неВставилосьГоворитПроИсториюИХоткей() throws {
        let content = dictationHUDContent(stage: .notDelivered(.targetNeverRequestedText),
                                          level: 0,
                                          reduceMotion: false,
                                          historyHint: "правый ⌘ + ⇧")
        #expect(content.title == "не вставилось")
        let detail = try #require(content.detail)
        #expect(detail.contains("истории"))
        #expect(detail.contains("правый ⌘ + ⇧"))
        #expect(content.visual == .init(form: .exclamation, accent: .yellow))
    }

    /// Тишина в микрофон каталога не заводит — и плашка НЕ отправляет владельца
    /// искать в истории то, чего там нет.
    @Test func проНесохранённуюЗаписьПлашкаНеВрёт() {
        let saved = dictationHUDContent(stage: .nothingRecognized(savedToHistory: true),
                                        level: 0, reduceMotion: false, historyHint: "правый ⌘ + ⇧")
        let lost = dictationHUDContent(stage: .nothingRecognized(savedToHistory: false),
                                       level: 0, reduceMotion: false, historyHint: "правый ⌘ + ⇧")
        #expect(saved.detail?.contains("истории") == true)
        #expect(lost.detail == nil)
        #expect(saved.title != lost.title)
    }

    @Test func подписьГолосовогоДоступаНесётСлова() {
        let content = dictationHUDContent(stage: .refused(.secureInputActive),
                                          level: 0, reduceMotion: false, historyHint: "")
        #expect(content.accessibilityLabel.contains(content.title))
        #expect(content.accessibilityLabel.contains("поле пароля"))
    }

    @Test func пустаяПодсказкаХоткеяНеДаётПустыхСкобок() throws {
        let content = dictationHUDContent(stage: .notDelivered(.insertionFailed),
                                          level: 0, reduceMotion: false, historyHint: "")
        let detail = try #require(content.detail)
        #expect(!detail.contains("()"))
        #expect(detail.contains("истории"))
    }

    @Test func знакиСостоянийРазведены() {
        #expect(dictationHUDVisual(for: .listening(.dictation)).form == .waveform)
        #expect(dictationHUDVisual(for: .recognizing).form == .processing)
        #expect(dictationHUDVisual(for: .inserted).form == .line)
        #expect(dictationHUDVisual(for: .notDelivered(.insertionFailed)).form == .exclamation)
        #expect(dictationHUDVisual(for: .inserted).accent == .green)
        #expect(dictationHUDVisual(for: .notDelivered(.insertionFailed)).accent == .yellow)
        #expect(dictationHUDVisual(for: .nothingRecognized(savedToHistory: true)).accent == .neutral)
    }

    /// Подсказка берётся из НАСТРОЕННОГО хоткея: владелец мог его сменить.
    @Test func подсказкаХоткеяИсторииИзНастроек() {
        #expect(dictationHUDHistoryHint(keycode: RIGHT_COMMAND_KEYCODE, modifiers: .maskShift)
                == "правый ⌘ + ⇧")
        #expect(dictationHUDHistoryHint(keycode: 62, modifiers: [.maskShift, .maskAlternate])
                == "правый ⌃ + ⌥⇧")
        // Свой же модификатор в подсказке не удваивается.
        #expect(dictationHUDHistoryHint(keycode: RIGHT_COMMAND_KEYCODE, modifiers: [.maskCommand])
                == "правый ⌘")
        // Не модификатор — по-русски, а не английским именем из таблицы проекта.
        #expect(dictationHUDHistoryHint(keycode: 105, modifiers: []) == "функциональная 13")
        #expect(dictationHUDHistoryHint(keycode: 49, modifiers: [.maskCommand]) == "пробел + ⌘")
        #expect(dictationHUDHistoryHint(keycode: 36, modifiers: []) == "⏎")
        // Буквенной клавише честного русского имени нет (статическая карта
        // ЙЦУКЕН в проекте запрещена — расходится с раскладкой машины), поэтому
        // подсказка молчит, а не печатает `V`.
        #expect(dictationHUDHistoryHint(keycode: 9, modifiers: [.maskCommand]).isEmpty)
    }
}

// MARK: - Сколько плашка живёт

@Suite("плашка: время жизни")
struct DictationHUDDismissTests {

    @Test func рабочаяПлашкаСамаНеУходит() {
        #expect(dictationHUDDismissDelay(for: .listening(.dictation)) == nil)
        #expect(dictationHUDDismissDelay(for: .recognizing) == nil)
        #expect(dictationHUDDismissDelay(for: .buildingPrompt) == nil)
    }

    @Test func терминальнаяПлашкаУходитСама() throws {
        let terminal: [DictationHUDStage] = [
            .inserted, .notDelivered(.insertionFailed),
            .nothingRecognized(savedToHistory: true), .recognitionTimedOut,
            .recognitionFailed(savedToHistory: false), .promptFailed(.invalidResult),
            .promptNotDelivered(.insertionFailed), .promptSavedAfterFocusChange,
            .refused(.modelNotReady),
        ]
        for stage in terminal {
            let delay = try #require(dictationHUDDismissDelay(for: stage))
            #expect(delay > 0)
        }
    }

    /// «Вставил» не задерживается, «не вставилось» живёт дольше всех: это
    /// единственное сообщение, которое владелец обязан успеть прочитать.
    @Test func подтверждениеКороткоеАПровалСамыйДолгий() throws {
        let inserted = try #require(dictationHUDDismissDelay(for: .inserted))
        let failed = try #require(dictationHUDDismissDelay(for: .notDelivered(.insertionFailed)))
        #expect(inserted < failed)
        #expect(inserted <= 1)
        #expect(failed >= 4)
    }
}

// MARK: - Место на экране

@Suite("плашка: место на экране")
struct DictationHUDFrameTests {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func плашкаВнизуПоЦентруИВнутриЭкрана() {
        let frame = dictationHUDFrame(size: CGSize(width: 260, height: 56), in: screen)
        #expect(frame.midX == screen.midX)
        #expect(screen.contains(frame))
        #expect(frame.minY > screen.minY)
        // Низ экрана, а не середина: поле ввода не перекрывается.
        #expect(frame.maxY < screen.midY)
    }

    @Test func плашкаНеВылезаетНаКрошечномЭкране() {
        let tiny = CGRect(x: 100, y: 100, width: 120, height: 40)
        let frame = dictationHUDFrame(size: CGSize(width: 400, height: 200), in: tiny)
        #expect(tiny.contains(frame))
    }

    @Test func плашкаУчитываетСмещениеЭкрана() {
        let second = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let frame = dictationHUDFrame(size: CGSize(width: 240, height: 56), in: second)
        #expect(second.contains(frame))
        #expect(frame.midX == second.midX)
    }
}

// MARK: - Порядок показа

/// Заглушка поверхности: живую панель под тест-раннером не поднять, а порядок
/// показа проверить надо.
@MainActor
private final class RecordingHUDSurface: DictationHUDSurface {
    var presented: [DictationHUDContent] = []
    var hints: [[String]] = []
    var dismissCount = 0
    var prewarmCount = 0
    /// Обработчик «текст забрали», который поверхность получила от презентера.
    var transcriptCopied: (() -> Void)?

    func present(_ content: DictationHUDContent) { presented.append(content) }
    func updateHintLines(_ lines: [String]) { hints.append(lines) }
    func dismiss() { dismissCount += 1 }
    func prewarm() { prewarmCount += 1 }
    func setTranscriptCopiedHandler(_ handler: @escaping () -> Void) { transcriptCopied = handler }
}

/// Счётчик заведённых поверхностей: прогрев обязан греть ТУ поверхность,
/// на которой потом покажут, иначе он греет мусор.
@MainActor
private final class SurfaceFactory {
    let surface = RecordingHUDSurface()
    private(set) var created = 0

    func make() -> DictationHUDSurface {
        created += 1
        return surface
    }
}

/// Панель с не доехавшим текстом уходит, как только текст забрали. Владелец
/// сказал прямо: копирую, а она висит и убрать её нечем. Правило машинное, а
/// не на словах: живьём это проверяется кликом по экрану, а тут - вызовом.
@Suite("плашка: панель уходит, когда текст забрали")
@MainActor
struct DictationHUDTranscriptDismissTests {
    @Test func copyingTheTextClosesThePanel() {
        let surface = RecordingHUDSurface()
        let presenter = DictationHUDPresenter(level: { 0 },
                                             pipelineState: { .ready },
                                             historyHint: { "" },
                                             reduceMotion: { true },
                                             surface: { surface })
        presenter.deliveryFinished(.notDelivered(.targetNeverRequestedText),
                                   text: "текст, который не доехал")
        #expect(surface.presented.last?.transcript == "текст, который не доехал",
                "панель не подняли с текстом")
        let handler = surface.transcriptCopied
        #expect(handler != nil, "презентер не сказал поверхности, кого звать после копирования")

        handler?()
        // Панель закрылась, но плашка НЕ снесена: текст забрали - значит работы
        // больше нет, а «нет работы» с 06.09.2026 значит покой, а не пустота.
        #expect(surface.dismissCount == 0, "плашку снесли вместо возврата в покой")
        #expect(surface.presented.last?.stage == .resting, "после копирования плашка не вернулась в покой")

        // И текст забыт: иначе следующая же перерисовка подняла бы панель заново.
        presenter.nothingRecognized(savedToHistory: false)
        #expect(surface.presented.last?.transcript == nil, "текст всплыл обратно после копирования")
    }
}

@Suite("плашка: порядок показа")
@MainActor
struct DictationHUDPresenterTests {

    private func makePresenter(level: @escaping () -> Float = { 0.5 },
                               pipelineState: @escaping () -> DictationController.State = { .ready })
        -> (DictationHUDPresenter, RecordingHUDSurface) {
        let surface = RecordingHUDSurface()
        let presenter = DictationHUDPresenter(level: level,
                                             pipelineState: pipelineState,
                                             historyHint: { "правый ⌘ + ⇧" },
                                             reduceMotion: { false },
                                             surface: { surface })
        return (presenter, surface)
    }

    /// Прогрев обязан собрать ровно ту поверхность, на которой потом покажут:
    /// греть отдельный экземпляр, а показывать на свежем — это тот же холодный
    /// первый показ, только с лишней панелью в памяти.
    @Test func прогревГотовитТуЖеПоверхностьЧтоИПоказ() {
        let factory = SurfaceFactory()
        let presenter = DictationHUDPresenter(level: { 0 },
                                              pipelineState: { .ready },
                                              historyHint: { "" },
                                              reduceMotion: { false },
                                              surface: { factory.make() })
        presenter.prewarm()
        #expect(factory.created == 1)
        #expect(factory.surface.prewarmCount == 1)
        // Прогрев теперь И ПОКАЗЫВАЕТ: плашка обязана стоять на экране с
        // запуска приложения, а не с первого нажатия.
        #expect(factory.surface.presented.count == 1)
        #expect(factory.surface.presented.last?.stage == .resting)

        presenter.pipelineStateChanged(.recording)
        #expect(factory.created == 1)
        #expect(factory.surface.presented.count == 2)
    }

    /// Прогрев ставит плашку в покой. Прежде эта проба требовала обратного -
    /// «прогрев ничего не показывает», - и была машинной записью прежнего
    /// решения владельца. Новое решение (06.09.2026) отменяет прежнее целиком:
    /// плашка на экране с запуска.
    ///
    /// Что осталось прежним и обязано остаться: опрос уровня в покое НЕ идёт.
    /// Постоянная плашка не имеет права стоить постоянного расхода.
    @Test func прогревСтавитПлашкуВПокой() {
        let (presenter, surface) = makePresenter()
        presenter.prewarm()
        #expect(surface.presented.count == 1)
        #expect(surface.presented.last?.stage == .resting)
        #expect(surface.dismissCount == 0)
        #expect(presenter.stage == .resting)
        #expect(!presenter.isPollingLevel)
    }

    @Test func записьПоказываетПлашкуИЗаводитОпросУровня() throws {
        let (presenter, surface) = makePresenter()
        presenter.pipelineStateChanged(.recording)
        #expect(presenter.stage == .listening(.dictation))
        #expect(presenter.isPollingLevel)
        #expect(surface.presented.count == 1)
        #expect(try #require(surface.presented.last).title == "слушаю")
    }

    /// Гейт этапа: таймер опроса гасится при выходе из записи. Иначе он молотил
    /// бы 20 раз в секунду на пустом экране до перезапуска приложения.
    @Test func опросУровняГаснетНаВыходеИзЗаписи() {
        let (presenter, _) = makePresenter()
        presenter.pipelineStateChanged(.recording)
        #expect(presenter.isPollingLevel)

        presenter.pipelineStateChanged(.transcribing)
        #expect(!presenter.isPollingLevel)
    }

    @Test func опросУровняГаснетИНаПокое() {
        let (presenter, surface) = makePresenter()
        presenter.pipelineStateChanged(.recording)
        presenter.pipelineStateChanged(.ready)
        #expect(!presenter.isPollingLevel)
        #expect(presenter.stage == .resting)
        #expect(surface.dismissCount == 0, "плашку снесли вместо возврата в покой")
    }

    /// Плашка и окно спасения говорят про один и тот же провал. Оставить
    /// РАЗВЁРНУТУЮ плашку поверх окна - сказать одно и то же дважды. Гейт:
    /// явный уход сворачивает плашку в покой и останавливает опрос уровня.
    ///
    /// Именно сворачивает, а не сносит: покоящаяся пилюля вчетверо уже рабочей
    /// и окну спасения не мешает, а снос нарушил бы «плашка всегда на экране».
    @Test func явныйУходСворачиваетПлашкуВПокойПередОкномСпасения() {
        let (presenter, surface) = makePresenter()
        presenter.pipelineStateChanged(.recording)
        #expect(presenter.stage == .listening(.dictation))
        #expect(presenter.isPollingLevel)

        presenter.dismiss()

        #expect(presenter.stage == .resting)
        #expect(!presenter.isPollingLevel)
        #expect(surface.dismissCount == 0)
        #expect(surface.presented.last?.stage == .resting)
    }

    /// Единственный случай, когда плашки на экране не остаётся: закрытие
    /// приложения. Отдельным входом - чтобы снос окна нельзя было позвать
    /// случайно из середины конвейера.
    @Test func сноситОкноТолькоЗакрытиеПриложения() {
        let (presenter, surface) = makePresenter()
        presenter.prewarm()
        #expect(surface.dismissCount == 0)

        presenter.shutDown()
        #expect(presenter.stage == nil)
        #expect(surface.dismissCount == 1)
    }

    @Test func опросУровняГаснетИПослеТерминальнойПлашки() {
        let (presenter, _) = makePresenter()
        presenter.pipelineStateChanged(.recording)
        presenter.deliveryFinished(.notDelivered(.insertionFailed))
        #expect(!presenter.isPollingLevel)
    }

    /// Отменённая диктовка (Escape) - плашка возвращается в покой, а не
    /// исчезает. Опрос уровня при этом стоит.
    @Test func безРаботыПлашкаВПокоеИНеОпрашиваетУровень() {
        let (presenter, surface) = makePresenter()
        presenter.pipelineStateChanged(.warmingUp)
        presenter.pipelineStateChanged(.ready)
        #expect(presenter.stage == .resting)
        #expect(surface.presented.last?.stage == .resting)
        #expect(!presenter.isPollingLevel)
    }

    /// Поверхность заводится ОДИН раз и живёт до конца процесса. Прежде она
    /// создавалась лениво, к первой надиктовке; теперь плашка на экране с
    /// запуска, значит и окно нужно с запуска. Проба стережёт единственность:
    /// второе окно разъехалось бы с первым по позиции и по монитору.
    @Test func поверхностьЗаводитсяОдинРазИНеПлодится() {
        var built = 0
        let presenter = DictationHUDPresenter(level: { 0 },
                                             pipelineState: { .ready },
                                             historyHint: { "" },
                                             reduceMotion: { false },
                                             surface: {
                                                 built += 1
                                                 return RecordingHUDSurface()
                                             })
        presenter.pipelineStateChanged(.ready)
        presenter.pipelineStateChanged(.warmingUp)
        presenter.pipelineStateChanged(.recording)
        presenter.pipelineStateChanged(.ready)
        #expect(built == 1)
    }

    /// Тот самый порядок из живого конвейера: вердикт, а сразу за ним `.ready`
    /// из defer. Плашка «не вставилось» обязана остаться на экране.
    @Test func провалДоставкиНеГаснетОтПокояСледомЗаНим() throws {
        let (presenter, surface) = makePresenter()
        presenter.pipelineStateChanged(.recording)
        presenter.pipelineStateChanged(.transcribing)
        presenter.deliveryFinished(.notDelivered(.targetNeverRequestedText))
        presenter.pipelineStateChanged(.ready)

        #expect(presenter.stage == .notDelivered(.targetNeverRequestedText))
        #expect(surface.dismissCount == 0)
        #expect(try #require(surface.presented.last).title == "не вставилось")
    }

    @Test func отказПоказываетПричину() {
        let (presenter, surface) = makePresenter()
        presenter.startRefused(.modelNotReady)
        #expect(presenter.stage == .refused(.modelNotReady))

        // Повторное нажатие на непрогретую модель показывает плашку заново, а не
        // молчит: владелец нажал ещё раз и должен снова увидеть причину.
        presenter.startRefused(.modelNotReady)
        #expect(surface.presented.count == 2)
    }

    /// «Уже записываю» приходит, когда запись ИДЁТ. Живую панель «слушаю» такой
    /// отказ не сносит и опрос уровня не останавливает — иначе индикатор умирал
    /// бы посреди надиктовки от лишнего нажатия хоткея.
    @Test func отказУжеЗаписываюЖивуюПлашкуНеТрогает() {
        let (presenter, surface) = makePresenter(pipelineState: { .recording })
        presenter.pipelineStateChanged(.recording)
        let shown = surface.presented.count

        presenter.startRefused(.alreadyRecording)
        #expect(presenter.stage == .listening(.dictation))
        #expect(presenter.isPollingLevel)
        #expect(surface.dismissCount == 0)
        #expect(surface.presented.count == shown)
    }

    /// Тот же дефект чинится здесь во второй раз, и второй раз - до конца.
    ///
    /// Первый заход: идёт распознавание, владелец от нетерпения давит хоткей
    /// ещё раз, «распознаю» подменяется отказом с отсчётом 2 с, а по истечении
    /// отсчёта экран становился пустым до самого вердикта - на длинной
    /// надиктовке это десятки секунд. Починили последствие: плашка стала
    /// пересчитываться от состояния.
    ///
    /// Второй заход, 04.09.2026: владелец увидел живьём красную ошибку и
    /// следом зелёную галочку успешной вставки и сказал прямо, что так нельзя.
    /// Дело было не в отсчёте, а в самой подмене: «я уже это делаю» показывалось
    /// языком «не получилось». Теперь такой отказ не трогает экран вовсе, и
    /// «распознаю» остаётся стоять.
    @Test func отказПоЗанятостиНеТрогаетЭкран() throws {
        var state: DictationController.State = .transcribing
        let (presenter, surface) = makePresenter(pipelineState: { state })
        presenter.pipelineStateChanged(.recording)
        presenter.pipelineStateChanged(.transcribing)
        presenter.startRefused(.transcriptionInFlight)
        #expect(presenter.stage == .recognizing, "занятость подменила живую работу отказом")
        #expect(surface.dismissCount == 0)
        #expect(try #require(surface.presented.last).title == "распознаю")

        // А когда работа кончилась — истёкшая плашка честно уходит с экрана.
        state = .ready
        presenter.deliveryFinished(.delivered)
        presenter.dismissIfStillShowing(.inserted)
        #expect(presenter.stage == .resting, "истёкшая плашка не вернулась в покой")
        #expect(surface.dismissCount == 0)
    }

    /// Упавшее распознавание обязано быть ВИДНО: `defer` в конвейере тут же
    /// ставит `.ready`, рабочая плашка гаснет, и без своего сообщения владелец
    /// увидел бы то же самое, что при удачной вставке.
    @Test func упавшееРаспознаваниеВидноИПослеПокоя() throws {
        let (presenter, surface) = makePresenter(pipelineState: { .ready })
        presenter.pipelineStateChanged(.recording)
        presenter.pipelineStateChanged(.transcribing)

        presenter.recognitionFailed(savedToHistory: false)
        #expect(presenter.stage == .recognitionFailed(savedToHistory: false))
        let content = try #require(surface.presented.last)
        #expect(content.title == "сбой распознавания")
        // Сырья на диске нет — в историю не отправляем.
        #expect(try #require(content.detail).contains("истории") == false)

        presenter.pipelineStateChanged(.ready)
        #expect(presenter.stage == .recognitionFailed(savedToHistory: false))
        #expect(surface.dismissCount == 0)
    }

    /// Ошибка в хвосте задачи (сон перед Enter, запись `inserted.txt`) приходит
    /// в тот же `catch`. Уже сказанный исход она не перебивает: «вставил» —
    /// правда, а «сбой распознавания» поверх него — ложь.
    @Test func сбойНеПеребиваетСказанныйИсход() {
        let (presenter, _) = makePresenter()
        presenter.deliveryFinished(.delivered)
        presenter.recognitionFailed(savedToHistory: true)
        #expect(presenter.stage == .inserted)

        presenter.recognitionTimedOut()
        presenter.recognitionFailed(savedToHistory: true)
        #expect(presenter.stage == .recognitionTimedOut)
    }

    @Test func пустоеРаспознаваниеИТаймаутПоказываютСвоё() {
        let (presenter, _) = makePresenter()
        presenter.nothingRecognized(savedToHistory: true)
        #expect(presenter.stage == .nothingRecognized(savedToHistory: true))
        presenter.recognitionTimedOut()
        #expect(presenter.stage == .recognitionTimedOut)
    }

    /// Опрос уровня передаёт плашке свежее непрерывное значение.
    @Test func тикОпросаОбновляетУровень() throws {
        var level: Float = 0.1
        let surface = RecordingHUDSurface()
        let pump = DictationHUDLevelPump(interval: 60)
        let presenter = DictationHUDPresenter(level: { level },
                                             pipelineState: { .recording },
                                             historyHint: { "" },
                                             reduceMotion: { false },
                                             pump: pump,
                                             surface: { surface })
        presenter.pipelineStateChanged(.recording)
        let quiet = try #require(surface.presented.last).level

        level = 0.95
        pump.onTick?()
        let loud = try #require(surface.presented.last).level
        #expect(loud > quiet)
    }

    @Test func залипшаяSequenceГаситУровеньАСменаВосстанавливает() throws {
        var snapshot: (level: Float, sequence: UInt64) = (1, 7)
        let surface = RecordingHUDSurface()
        let pump = DictationHUDLevelPump(interval: 60)
        let presenter = DictationHUDPresenter(
            levelSnapshot: { snapshot },
            pipelineState: { .recording },
            historyHint: { "" },
            triggerMode: { .toggle },
            activeHotkeyHint: { "правый ⌘" },
            showsDragHint: { false },
            reduceMotion: { false },
            pump: pump,
            surface: { surface }
        )

        presenter.pipelineStateChanged(.recording)
        for _ in 0..<8 { pump.onTick?() }
        let beforeStale = try #require(surface.presented.last).level
        pump.onTick?()
        let stale = try #require(surface.presented.last).level
        #expect(stale < beforeStale)

        snapshot = (1, 8)
        pump.onTick?()
        let recovered = try #require(surface.presented.last).level
        #expect(recovered > stale)
    }

    @Test func listeningБерётПодписьФактическиАктивногоХоткея() throws {
        var activeHint = "правый ⌘"
        let surface = RecordingHUDSurface()
        let presenter = DictationHUDPresenter(
            levelSnapshot: { (0, 1) },
            pipelineState: { .recording },
            historyHint: { "правый ⌘ + ⇧" },
            triggerMode: { .toggle },
            activeHotkeyHint: { activeHint },
            showsDragHint: { false },
            reduceMotion: { false },
            surface: { surface }
        )

        presenter.pipelineStateChanged(.recording)
        #expect(try #require(surface.hints.last).first == "правый ⌘ — закончить")

        activeHint = "правый ⌥"
        presenter.pipelineStateChanged(.recording)
        #expect(try #require(surface.hints.last).first == "правый ⌥ — закончить")
    }

    /// Режим записи виден СРАЗУ, а не после распознавания: плашка берёт его из
    /// конвейера в момент показа.
    @Test func режимЗаписиДоходитДоПоверхности() throws {
        for (purpose, accent, mark) in [
            (DictationRecordingPurpose.dictation, DictationHUDAccent.red, DictationHUDMark.none),
            (DictationRecordingPurpose.prompt, DictationHUDAccent.violet, DictationHUDMark.chevron),
        ] {
            let surface = RecordingHUDSurface()
            let presenter = DictationHUDPresenter(
                levelSnapshot: { (0.4, 1) },
                pipelineState: { .recording },
                historyHint: { "" },
                triggerMode: { .toggle },
                activeHotkeyHint: { "правый ⌘" },
                showsDragHint: { false },
                recordingPurpose: { purpose },
                reduceMotion: { false },
                surface: { surface }
            )

            presenter.pipelineStateChanged(.recording)
            #expect(presenter.stage == .listening(purpose))
            let shown = try #require(surface.presented.last)
            #expect(shown.visual.accent == accent)
            #expect(shown.visual.mark == mark)
        }
    }

    /// Контроллер обнуляет `recordingPurpose` на отпускании клавиши. Стадия к
    /// этому моменту уже на экране и несёт режим ЗНАЧЕНИЕМ — поздний опрос не
    /// имеет права перекрасить промпт-запись в обычную посреди неё самой.
    @Test func обнулённыйРежимНеПерекрашиваетЖивуюПлашку() throws {
        var purpose = DictationRecordingPurpose.prompt
        let surface = RecordingHUDSurface()
        let pump = DictationHUDLevelPump(interval: 60)
        let presenter = DictationHUDPresenter(
            levelSnapshot: { (0.4, 1) },
            pipelineState: { .recording },
            historyHint: { "" },
            triggerMode: { .toggle },
            activeHotkeyHint: { "правый ⌥" },
            showsDragHint: { false },
            recordingPurpose: { purpose },
            reduceMotion: { false },
            pump: pump,
            surface: { surface }
        )

        presenter.pipelineStateChanged(.recording)
        purpose = .dictation
        pump.onTick?()

        #expect(presenter.stage == .listening(.prompt))
        #expect(try #require(surface.presented.last).visual.accent == .violet)
    }
}

// MARK: - Опрос уровня

@Suite("плашка: таймер уровня")
@MainActor
struct DictationHUDLevelPumpTests {

    @Test func таймерЗаводитсяИГаснетПоКоманде() {
        let pump = DictationHUDLevelPump(interval: 60)
        #expect(!pump.isRunning)
        pump.setRunning(true)
        #expect(pump.isRunning)
        pump.setRunning(false)
        #expect(!pump.isRunning)
    }

    @Test func повторныеКомандыБезопасны() {
        let pump = DictationHUDLevelPump(interval: 60)
        pump.setRunning(true)
        pump.setRunning(true)
        #expect(pump.isRunning)
        pump.setRunning(false)
        pump.setRunning(false)
        #expect(!pump.isRunning)
    }

    /// Гейт переделки: режим run loop у ОБОИХ таймеров плашки — `.common`.
    ///
    /// В режиме `.default` таймер молчит, пока крутится вложенный цикл
    /// отслеживания: открыто меню (в том числе наше, в строке меню) или зажата
    /// кнопка мыши. Терминальную плашку по замыслу не гасит `.ready`, поэтому с
    /// `.default` открытое меню оставляло её висеть поверх всех окон, а индикатор
    /// уровня замирал ровно при протяжке мышью. Режим живёт в одной константе и
    /// применяется в одной фабрике `dictationHUDTimer`, поэтому сравнение здесь
    /// закрывает оба таймера сразу.
    @Test func таймерыПлашкиНеЗависаютПриОткрытомМеню() {
        #expect(DICTATION_HUD_TIMER_MODE == .common)
        #expect(DICTATION_HUD_TIMER_MODE != .default)
    }

    /// Таймер из фабрики заведён и жив — то есть добавлен в run loop, а не
    /// потерян по дороге (`Timer(timeInterval:)` без `RunLoop.add` не стреляет
    /// никогда).
    @Test func фабрикаТаймеровВозвращаетЖивойТаймер() {
        let timer = dictationHUDTimer(after: 60, repeats: false) {}
        #expect(timer.isValid)
        timer.invalidate()
        #expect(!timer.isValid)
    }
}

// MARK: - Прогрев и замер первого показа

/// Жалоба владельца звучала как «она как будто бы тормозит в самом начале»,
/// и спорить с ней можно только числом. Число снимается техническим режимом
/// `--measure-hud-first-show` на живой панели; здесь под тестом лежит
/// арифметика, на которой это число стоит, — иначе замер соврал бы красиво.
@Suite("плашка: замер первого показа")
@MainActor
struct DictationHUDFirstShowTests {

    @Test func копилкаКадровСчитаетРазрывыИРаботу() {
        let frames = DictationHUDFrameLog()
        frames.add(gap: 0.008, work: 0.001)
        frames.add(gap: 0.030, work: 0.004)
        frames.add(gap: 0.008, work: 0.001)
        #expect(frames.count == 3)
        #expect(abs(frames.firstGap - 0.008) < 1e-9)
        #expect(abs(frames.worstGap - 0.030) < 1e-9)
        #expect(abs(frames.worstWork - 0.004) < 1e-9)
        #expect(abs(frames.meanWork - 0.002) < 1e-9)
    }

    /// Кадров не пришло вовсе — это тоже результат замера, а не деление на ноль.
    @Test func пустаяКопилкаНеДелитНаНоль() {
        let frames = DictationHUDFrameLog()
        #expect(frames.count == 0)
        #expect(frames.meanWork == 0)
    }

    @Test func строкаЗамераРазличаетПрогретыйИХолодныйПоказ() {
        let cold = DictationHUDFirstShowMetric(prewarmed: false,
                                               orderedSeconds: 0.012,
                                               paintedSeconds: 0.031)
        let warm = DictationHUDFirstShowMetric(prewarmed: true,
                                               orderedSeconds: 0.002,
                                               paintedSeconds: 0.011)
        #expect(cold.logLine.contains("31 ms"))
        #expect(cold.logLine.contains("прогрев не успел"))
        #expect(warm.logLine.contains("11 ms"))
        #expect(warm.logLine.contains("прогрев был"))
    }
}

/// Раскладка спрашивает размер подсказки на каждом кадре анимации, а замер
/// строки — это обращение к CoreText. Размер считается один раз на смену строк,
/// и вот тут проверяется, что кеш не залипает: залипший соврёт про ширину
/// плашки при смене подсказки.
@Suite("плашка: размер подсказки")
@MainActor
struct DictationHUDHintSizeTests {

    @Test func сменаСтрокПересчитываетРазмер() {
        let hint = DictationHUDHintView(frame: .zero)
        hint.lines = ["правый ⌘"]
        let short = hint.fittingHintSize
        hint.lines = ["правый ⌘ — остановить запись и отдать текст в поле ввода"]
        let long = hint.fittingHintSize
        #expect(long.width > short.width)
        hint.lines = ["правый ⌘"]
        #expect(hint.fittingHintSize == short)
    }

    @Test func втораяСтрокаПоднимаетВысоту() {
        let hint = DictationHUDHintView(frame: .zero)
        hint.lines = ["правый ⌘"]
        let one = hint.fittingHintSize
        hint.lines = ["правый ⌘", "мышью — переставить"]
        #expect(hint.fittingHintSize.height > one.height)
        hint.lines = []
        #expect(hint.fittingHintSize == .zero)
    }
}
