import Foundation
import Testing

@testable import IrizApp

@Suite("знакомство: решения, а не картинки")
struct FirstRunTests {
    /// Порядок шагов - это сценарий, а не список. Разрешения идут от самого
    /// понятного к самому пугающему: человеку, которому уже объяснили микрофон,
    /// спокойнее отвечать на «сможет читать все нажатия».
    @Test func stepsRunFromPlainToFrightening() {
        let steps = FirstRunStep.allCases
        #expect(steps.first == .welcome)
        #expect(steps.last == .whenItBreaks)
        let mic = steps.firstIndex(of: .microphone)!
        let ax = steps.firstIndex(of: .accessibility)!
        let input = steps.firstIndex(of: .inputMonitoring)!
        #expect(mic < ax, "микрофон обязан идти раньше универсального доступа")
        #expect(ax < input, "самая страшная дверь обязана быть последней из трёх")
        let tryIt = steps.firstIndex(of: .tryIt)!
        #expect(input < tryIt, "проба голосом идёт после разрешений, иначе она не сработает")
        // Модель качается ПОЛГИГАБАЙТА. Начинать её надо до разрешений: пока
        // человек щёлкает переключатели в системном окне, загрузка идёт, и
        // время тратится один раз, а не дважды.
        let model = steps.firstIndex(of: .model)!
        #expect(model < mic, "загрузка модели обязана начинаться раньше разрешений")
        #expect(model < tryIt, "проба без модели невозможна")
        // Агент уводит речь с этого Мака, поэтому он идёт ПОСЛЕ пробы: человек
        // сначала видит, что всё работает локально, и только потом решает,
        // включать ли путь наружу. Перевод идёт через того же агента, значит
        // после него.
        let agent = steps.firstIndex(of: .agent)!
        let translate = steps.firstIndex(of: .translate)!
        #expect(tryIt < agent, "агента предлагают раньше, чем показали локальную диктовку")
        #expect(agent < translate, "перевод предложили раньше агента, без которого он молчит")
    }

    /// Ни один шаг не запирает дверь. Заперев человека на «Мониторинге ввода»,
    /// продукт получил бы не согласие, а закрытое окно.
    @Test func noStepBlocksTheWay() {
        for step in FirstRunStep.allCases {
            #expect(firstRunCanAdvance(from: step), "\(step) заперт")
        }
    }

    /// Ходьба вперёд и назад согласована: последний шаг никуда не ведёт,
    /// первый не имеет предыдущего.
    @Test func walkingIsConsistent() {
        #expect(firstRunPreviousStep(before: .welcome) == nil)
        #expect(firstRunNextStep(after: .whenItBreaks) == nil)
        var step = FirstRunStep.welcome
        var seen = [step]
        while let next = firstRunNextStep(after: step) {
            #expect(firstRunPreviousStep(before: next) == step, "шаг назад не вернул откуда пришли")
            step = next
            seen.append(step)
        }
        #expect(seen.count == FirstRunStep.allCases.count, "часть шагов недостижима")
    }

    /// Знакомство показывается один раз - и не показывается тому, кто уже
    /// прошёл этот путь руками до того, как оно появилось в продукте.
    @Test func welcomeShowsOnceAndNotToVeterans() throws {
        let name = "ru.iriz.tests.firstRun.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(firstRunShouldShow(defaults: defaults, permissionsGranted: false),
                "новичку знакомство не показали")
        #expect(!firstRunShouldShow(defaults: defaults, permissionsGranted: true),
                "человеку с выданными разрешениями показали знакомство заново")
        // Разрешения есть, а модели нет: поставить её можно только из
        // знакомства, значит показать его обязаны.
        #expect(firstRunShouldShow(defaults: defaults,
                                   permissionsGranted: true,
                                   modelInstalled: false),
                "без модели знакомство не показали, и поставить её стало неоткуда")

        defaults.set(true, forKey: FIRST_RUN_COMPLETED_KEY)
        #expect(!firstRunShouldShow(defaults: defaults, permissionsGranted: false),
                "знакомство повторилось после прохождения")
    }

    /// Разрешение просит ровно тот шаг, который про него рассказывает.
    @Test func onlyPermissionStepsAskForPermission() {
        #expect(FirstRunStep.microphone.permission == .microphone)
        #expect(FirstRunStep.accessibility.permission == .accessibility)
        #expect(FirstRunStep.inputMonitoring.permission == .inputMonitoring)
        for step in [FirstRunStep.welcome, .whereItLives, .tryIt, .whenItBreaks] {
            #expect(step.permission == nil, "\(step) просит разрешение не по делу")
        }
    }

    /// Каждый шаг несёт заголовок и текст, а шаги с разрешением - ещё и
    /// действие. Пустой экран в знакомстве хуже отсутствующего.
    @Test func everyStepSpeaks() {
        for step in FirstRunStep.allCases {
            #expect(!step.copy.title.isEmpty, "\(step) без заголовка")
            #expect(!step.copy.body.isEmpty, "\(step) без текста")
            if step.permission != nil {
                #expect(step.copy.action?.isEmpty == false, "\(step) просит разрешение без кнопки")
            }
        }
    }

    /// Самая страшная дверь обязана сказать три вещи: что именно система
    /// спросит, зачем это нам, и что приложение сейчас перезапустится.
    /// Проверяется машиной, потому что именно эти три предложения решают,
    /// останется человек или уйдёт.
    @Test func theFrighteningDoorExplainsItself() {
        let text = (FirstRunCopy.inputMonitoring.body + " " + (FirstRunCopy.inputMonitoring.note ?? ""))
            .lowercased()
        #expect(text.contains("нажатия клавиш"), "не названо, что скажет система")
        // Смысл, а не буквы: формулировка меняется вместе с тоном, обещание -
        // нет. Тест на дословную фразу краснел бы на каждой редактуре и учил
        // бы не улучшать текст.
        // Обещание должно быть ЧЕСТНЫМ, а не сильным. «Не читаю нажатия»
        // противоречило бы починке раскладки: чтобы поправить набранное не в
        // той раскладке, нажатия приходится именно читать. Поэтому обещаем то,
        // что правда: не сохраняем, не отправляем, в полях пароля не работаем.
        #expect(text.contains("не сохраня"), "не обещано, что нажатия не сохраняются")
        #expect(text.contains("не отправля"), "не обещано, что нажатия никуда не уходят")
        #expect(text.contains("пароля"), "не сказано про поля пароля")
        #expect(text.contains("перезапущ") || (text.contains("закро") && text.contains("откро")),
                "не предупреждён самоперезапуск")
    }

    /// Длинного тире в текстах продукта нет. Правило дома, и оно машинное, а
    /// не на вкус: тире в кириллице растягивает строку и в интерфейсе читается
    /// типографским шумом. Точка, двоеточие и запятая делают ту же работу.
    @Test func noEmDashesInCopy() {
        for step in FirstRunStep.allCases {
            let text = step.copy.title + " " + step.copy.body + " " + (step.copy.note ?? "")
            #expect(!text.contains("\u{2014}"), "\(step): длинное тире в тексте")
            #expect(!text.contains("--"), "\(step): двойной дефис вместо тире")
        }
    }

    /// Заголовок обязан быть короче строки: он и есть та самая одна мысль, а
    /// мысль, которая не помещается в строку, уже не одна.
    @Test func titlesStayShort() {
        for step in FirstRunStep.allCases {
            #expect(step.copy.title.count <= 42,
                    "\(step): заголовок в \(step.copy.title.count) знаков")
        }
    }

    /// Слова, которых человек не понимает, в знакомстве не встречаются.
    @Test func noJargonAnywhere() {
        let banned = ["карантин", "нотариз", "сертификат", "энтайтл", "tcc"]
        for step in FirstRunStep.allCases {
            let text = (step.copy.title + " " + step.copy.body + " " + (step.copy.note ?? "")).lowercased()
            for word in banned {
                #expect(!text.contains(word), "\(step): в тексте слово «\(word)»")
            }
        }
    }
}
