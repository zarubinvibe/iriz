// Все тексты окна первого запуска в ОДНОМ месте.
//
// Не ради красоты: локализации в проекте нет вовсе - ни одного .lproj, ни
// одного Localizable.strings, - а владелец требует три языка. Тексты, живущие
// одной таблицей, переезжают в локализацию заменой источника; тексты,
// рассыпанные по вьюхам, переезжают переписыванием вьюх.
//
// Формулировки не выдуманы здесь. Они пришли из карты путей четырёх разных
// людей и правились судьями. Три места, где слово решает, останется человек
// или уйдёт:
//   - «Мониторинг ввода»: система говорит «сможет читать все нажатия клавиш», и
//     это самая страшная дверь продукта. Молчать здесь нельзя;
//   - самоперезапуск после него читается как вылет ровно в тот момент, когда
//     человек максимально насторожен. Предупреждаем заранее;
//   - слова «карантин», «нотаризация», «сертификат» не употребляются вовсе:
//     их не понимает тот, ради кого написан этот экран.
import Foundation
import IrizCore

enum FirstRunCopy {
    static var windowTitle: String { L("firstrun.windowTitle", "Знакомство с \(IRIZ_NAME)") }

    static var next: String { L("firstrun.next", "Дальше") }
    static var back: String { L("firstrun.back", "Назад") }
    static var done: String { L("firstrun.done", "Готово") }
    static var skip: String { L("firstrun.skip", "Пропустить пока") }
    static var openSystemSettings: String { L("firstrun.openSystemSettings", "Открыть настройки системы") }
    static var granted: String { L("firstrun.granted", "Готово") }

    /// Подпись у стрелки. Говорит, ЧТО случится от нажатия, а не «нажмите
    /// кнопку»: человек и так видит кнопку, ему нужна причина.
    static var hintModel: String { L("firstrun.hintModel", "нажми сюда, качать примерно пять минут") }
    static var hintMicrophone: String { L("firstrun.hintMicrophone", "нажми сюда") }
    static var hintAccessibility: String { L("firstrun.hintAccessibility", "нажми сюда, откроются настройки системы") }
    static var hintInputMonitoring: String { L("firstrun.hintInputMonitoring", "нажми сюда, откроются настройки системы") }

    static var trialFieldPlaceholder: String { L("firstrun.trialFieldPlaceholder", "тут появится то, что ты скажешь") }
    static var trialThinking: String { L("firstrun.trialThinking", "разбираю сказанное") }
    static var trialPressKey: String { L("firstrun.trialPressKey", "нажми эту клавишу и скажи что-нибудь") }
    static var trialSample: String { L("firstrun.trialSample", "Например: «Привет, это проверка. Слышишь меня хорошо?»") }
    static var trialDone: String { L("firstrun.trialDone", "Получилось. Так же будет везде, где мигает курсор.") }
    /// Клавиша физически не слышна: без разрешения на клавиши нажатие не
    /// доходит до приложения вовсе. Молчать тут нельзя - человек жмёт, ничего
    /// не происходит, и он решает, что продукт сломан.
    static var trialDeaf: String { L("firstrun.trialDeaf", "Клавишу я пока не слышу: разрешение на клавиши не выдано.") }
    static var trialBackToPermission: String { L("firstrun.trialBackToPermission", "Вернуться к разрешению") }
    static var trialFallback: String { L("firstrun.trialFallback", "Слушать без клавиши") }
    static var trialListening: String { L("firstrun.trialListening", "слушаю, говори") }
    static var changeKey: String { L("firstrun.changeKey", "Клавиша занята? Поменять") }

    struct Step {
        let title: String
        let body: String
        /// Вторая мысль. Отдельным абзацем, а не через точку: одна мысль на
        /// строку читается, две в строке - нет.
        var note: String?
        var action: String?
    }

    static var welcome: Step { Step(
        title: L("firstrun.welcome.title", "Ты говоришь, я печатаю"),
        body: L("firstrun.welcome.body", "Нажми клавишу, скажи фразу, нажми еще раз. Текст появится там, где стоял "
            + "курсор: в письме, в чате, в терминале."),
        note: L("firstrun.welcome.note", "Все считается прямо на твоем Маке. Ни звук, ни текст никуда не отправляются.")
    ) }

    static var whereItLives: Step { Step(
        title: L("firstrun.whereItLives.title", "Я живу в строке меню"),
        body: L("firstrun.whereItLives.body", "Отдельного окна у меня нет, в доке тоже не ищи. Мой значок наверху справа, "
            + "рядом с часами."),
        note: L("firstrun.whereItLives.note", "Оттуда открываются история, словарь и настройки.\n\n"
            + "Запускаюсь вместе с Маком. Если не надо, выключи это в настройках.")
    ) }

    static var model: Step { Step(
        title: L("firstrun.model.title", "Скачаем распознавание"),
        body: L("firstrun.model.body", "Речь я разбираю прямо у тебя на Маке, без интернета. Для этого нужна модель: "
            + "полгигабайта, качается один раз."),
        note: L("firstrun.model.note", "В образе ее нет намеренно. Модель обновляется чаще, чем выходит программа, и "
            + "лучше взять свежую сейчас, чем возить с собой прошлогоднюю.\n\n"
            + "Пока она едет, иди дальше: разрешения можно выдать прямо сейчас."),
        action: L("firstrun.model.action", "Скачать модель")
    ) }

    static var modelReady: String { L("firstrun.modelReady", "Модель на месте") }
    static var modelFailedRetry: String { L("firstrun.modelFailedRetry", "Попробовать снова") }

    static var microphone: Step { Step(
        title: L("firstrun.microphone.title", "Нужен микрофон"),
        body: L("firstrun.microphone.body", "Без него я не услышу ни слова, так что начнем с него."),
        note: L("firstrun.microphone.note", "Звук нигде не сохраняется: он живет ровно столько, сколько нужно, чтобы "
            + "разобрать сказанное."),
        action: L("firstrun.microphone.action", "Разрешить микрофон")
    ) }

    static var accessibility: Step { Step(
        title: L("firstrun.accessibility.title", "Нужно разрешение вставлять текст"),
        body: L("firstrun.accessibility.body", "Чтобы вставить готовый текст в письмо или чат, macOS требует отдельное "
            + "разрешение. Называется «Универсальный доступ»."),
        note: L("firstrun.accessibility.note", "Без него я разберу речь, но вставить ее будет некуда. В открывшемся списке "
            + "найди iriz и включи переключатель: система не дает сделать это за меня."),
        action: openSystemSettings
    ) }

    static var inputMonitoring: Step { Step(
        title: L("firstrun.inputMonitoring.title", "Осталось разрешение на клавиши"),
        body: L("firstrun.inputMonitoring.body", "macOS назовет его «Мониторинг ввода» и предупредит, что я смогу видеть нажатия "
            + "клавиш во всех программах. Формулировка ее, не моя."),
        note: L("firstrun.inputMonitoring.note", "Мне нужны две вещи: понять, что ты нажал клавишу диктовки, и заметить, что "
            + "фраза набрана не в той раскладке. Нажатия вижу только здесь, на твоем Маке: "
            + "ничего не сохраняю и никуда не отправляю, а в полях пароля не работаю вовсе."
            + "\n\n"
            + "Сразу после этого я перезапущусь. Так требует macOS, это не поломка."),
        action: openSystemSettings
    ) }

    static var tryIt: Step { Step(
        title: L("firstrun.tryIt.title", "Попробуй прямо сейчас"),
        body: L("firstrun.tryIt.body", "Вот твоя клавиша диктовки. Нажми ее, скажи что-нибудь, нажми еще раз."),
        note: L("firstrun.tryIt.note", "Текст появится в поле ниже и больше никуда не попадет: пока открыто это окно, "
            + "я пишу только сюда.")
    ) }

    static var plate: Step { Step(
        title: L("firstrun.plate.title", "Плашка всегда на экране"),
        body: L("firstrun.plate.body", "Внизу висит стеклянная капля. Пока ты молчишь, она маленькая и ничего не делает. "
            + "Заговорил - в ней бежит волна: это и есть ответ на «слышит ли меня»."),
        note: L("firstrun.plate.note", "Наведи мышь - капля раскроется в ряд кнопок: запись, промпт, перевод, язык, "
            + "история, настройки. Щёлкни по ней - откроется панель с текстом.\n\n"
            + "Плашку можно перетащить: она примагнитится к одному из двенадцати мест по краям экрана. "
            + "Выйти из раскрытой панели можно тремя способами - крестиком, Escape и щелчком мимо кнопок.")
    ) }

    static var agent: Step { Step(
        title: L("firstrun.agent.title", "Речь можно превратить в задание"),
        body: L("firstrun.agent.body", "Отдельная клавиша отправляет сказанное не в поле, а внешнему агенту: он собирает "
            + "из сбивчивой речи готовое задание и возвращает текст."),
        note: L("firstrun.agent.note", "Тут кончается «все считается у тебя на Маке»: агент живет отдельной программой, "
            + "и сказанное уходит туда. Поэтому режим выключен, пока ты сам его не включишь.\n\n"
            + "Я поискал агентов, которые уже стоят у тебя. Можно ничего не выбирать и вернуться "
            + "к этому в настройках.")
    ) }

    static var agentNotFound: String { L("firstrun.agentNotFound", "Ни одного агента не нашел. Ничего страшного: диктовка и раскладка "
        + "работают без него, а подключить можно потом в настройках.") }
    static var agentConnected: String { L("firstrun.agentConnected", "Подключен") }
    static var agentConnect: String { L("firstrun.agentConnect", "Подключить") }

    static var translate: Step { Step(
        title: L("firstrun.translate.title", "Скажи по-русски, получи по-английски"),
        body: L("firstrun.translate.body", "Вторая клавиша делает то же, что диктовка, но текст приходит на другом языке."),
        note: L("firstrun.translate.note", "Перевод идет через того же агента, что и задания: без него клавиша молчит.")
    ) }

    static var translateEnable: String { L("firstrun.translateEnable", "Включить перевод") }
    static var translateNeedsAgent: String { L("firstrun.translateNeedsAgent", "Сначала подключи агента на прошлом шаге.") }
    static var translateFieldPlaceholder: String { L("firstrun.translateFieldPlaceholder", "тут появится перевод") }
    static var translatePressKey: String { L("firstrun.translatePressKey", "нажми эту клавишу и скажи что-нибудь по-русски") }

    static var whenItBreaks: Step { Step(
        title: L("firstrun.whenItBreaks.title", "Если пойдет не так"),
        body: L("firstrun.whenItBreaks.body", "Текст не вставился? Он не потерян. Плашка развернется и покажет его, оттуда "
            + "можно скопировать."),
        note: L("firstrun.whenItBreaks.note", "Расслышал слово неправильно? Поправь его в словаре, дальше буду писать как надо."
            + "\n\nЭто окно, настройки и история открываются из значка в строке меню.")
    ) }

    /// Состояния разрешения. Цвет НЕ единственный носитель: у каждого состояния
    /// своё слово. Правило уже стоит в FamilyAccent.swift и держится тестом.
    static func permissionState(granted: Bool) -> String {
        granted ? "разрешено" : "пока нет"
    }
}
