// Форма плашки: где стоит тело и где спутник в каждом состоянии.
//
// Решение владельца 03.09.2026, вечер: плашка-бабл возвращается, и главное её
// свойство названо дословно - «баблы плавно перетекали из одного в другое».
// Значит состояния не подменяют друг друга кадром, а ПЕРЕТЕКАЮТ: те же два
// стекла едут, меняя размер и место.
//
// Механизм перетекания - не наш: `NSGlassEffectContainerView` сливает соседние
// стёкла, когда они ближе `spacing`, и разводит, когда дальше. Тело и спутник
// сходятся в одну каплю и снова расходятся сами. Нам остаётся сказать, ГДЕ они
// стоят; слияние делает система.
//
// Числа живут здесь, в чистой функции под тестом, а не в рисующем коде: у
// геометрии плашки уже есть история из пяти отказов подряд, и разъехаться
// модели с картинкой нельзя.
import CoreGraphics
import Foundation

/// Что показывает плашка. Не то же самое, что стадия конвейера: несколько
/// стадий дают одну форму, и это правильно - форма про ВИД, а не про этап.
public enum DictationHUDGlassForm: String, CaseIterable, Sendable {
    /// Покой: та же пилюля, но короче. Окно в покое меньше рабочего, и это не
    /// косметика - постоянная плашка перехватывает щелчки всей своей рамкой,
    /// а значит её площадь и есть цена постоянства.
    case resting
    /// Идёт запись: широкое тело, внутри лента. Спутника нет.
    case listening
    /// Думает: та же плашка, синяя волна. Спутника НЕТ.
    ///
    /// Здесь была отделяющаяся капля - тело поджималось, справа отходил
    /// шарик. Владелец увидел это живьём и отверг: «после этого опять
    /// разделяется на две части, так не должно быть». Работа показывается
    /// цветом и ходом волны, а не распадом плашки надвое.
    case thinking
    /// Дошло: спутник вернулся в тело, тело собралось в круг со знаком.
    case done
    /// Текст не доехал: плашка РАЗВОРАЧИВАЕТСЯ в панель, где он напечатан и
    /// откуда его можно забрать. Слова владельца: «эта плашка трансформируется
    /// в зону, где текст напечатан, и я его могу копировать».
    ///
    /// Это продолжение того же движения, а не чужой диалог поверх. Прежде
    /// спасение жило отдельным окном истории: оно открывалось само по себе,
    /// и связь с только что не доехавшей надиктовкой держалась только в голове.
    case transcript
    /// Кончилось ничем: плашка собралась в точку и уходит. Слова владельца:
    /// «она потом может сама плашка собраться в маленький кружочек и
    /// исчезнуть вообще, что не получилось».
    case vanishing
}

/// Форма плашки. Тело и только тело.
///
/// Спутник - вторая капля рядом - здесь был и удалён: ни одна форма его больше
/// не использует, а живая проверка показала, почему. Плашка, распадающаяся
/// надвое, читается поломкой, а не работой. Механизм слияния стёкол при этом
/// никуда не делся: он в `NSGlassEffectContainerView` и пригодится, когда
/// понадобится вторая капля по делу.
public struct DictationHUDGlassShape: Equatable, Sendable {
    public var body: CGRect
    public var bodyRadius: CGFloat

    public init(body: CGRect, bodyRadius: CGFloat) {
        self.body = body
        self.bodyRadius = bodyRadius
    }
}

/// Поле от стекла до кромки окна. Только чтобы кромка стекла не срезалась
/// обрезом окна: сама кромка и есть то, чем стекло читается стеклом.
///
/// Было 5,0 и высота 26,8 из 36,8 - стекла в кадре оставалось меньше половины,
/// и переливов под ним видно не было. Решение владельца по кадру: плашку
/// побольше, «чтобы было видно, каким образом под ней всё переливается».
/// Поле - ДОЛЯ высоты окна, а не пункты. Пока размер плашки был один, разницы
/// не было. С выбором размера константа ломает две трети вариантов: у малого
/// окна 99 x 29 стекло высотой 32,8 ВЫШЕ окна и срезается обрезом, у большого
/// 161 x 48 оно той же высоты с пустым полем 7,6 сверху и снизу - «большая»
/// плашка получается не крупнее, а шире с дыркой внутри.
let DICTATION_HUD_GLASS_INSET_SHARE: CGFloat = 2.0 / 36.8

/// Скругление панели расшифровки. Не половина высоты: у высокой панели это
/// дало бы стадион вместо прямоугольника со скруглёнными углами.
let DICTATION_HUD_TRANSCRIPT_RADIUS: CGFloat = 18

/// Поле стекла для окна этого размера.
func dictationHUDGlassInset(for size: CGSize) -> CGFloat {
    max(1, (size.height * DICTATION_HUD_GLASS_INSET_SHARE).rounded(.toNearestOrEven))
}

/// Геометрия плашки для формы. `size` - размер окна.
public func dictationHUDGlassShape(form: DictationHUDGlassForm,
                                   in size: CGSize) -> DictationHUDGlassShape {
    let inset = dictationHUDGlassInset(for: size)
    let height = size.height - inset * 2
    let y = (size.height - height) / 2
    let full = size.width - inset * 2
    let radius = height / 2

    switch form {
    case .resting:
        // Геометрия та же, что у записи: разницу несёт РАЗМЕР ОКНА, а не форма
        // внутри него. Так покой и запись остаются одной пилюлей, которая
        // растёт и сжимается, - перетекание, а не подмена кадра.
        return DictationHUDGlassShape(
            body: CGRect(x: inset, y: y, width: full, height: height),
            bodyRadius: radius
        )

    case .listening:
        return DictationHUDGlassShape(
            body: CGRect(x: inset, y: y, width: full, height: height),
            bodyRadius: radius
        )

    case .thinking:
        // Та же геометрия, что у записи: плашка не делится. Меняется только
        // то, что в ней горит.
        return DictationHUDGlassShape(
            body: CGRect(x: inset, y: y, width: full, height: height),
            bodyRadius: radius
        )

    case .done:
        // Круг по центру: спутник вернулся в тело, и тело собралось. Ширина
        // равна высоте - это круг, а не короткая пилюля.
        let side = height
        return DictationHUDGlassShape(
            body: CGRect(x: (size.width - side) / 2, y: y, width: side, height: height),
            bodyRadius: side / 2
        )

    case .transcript:
        // Панель занимает всё окно: размер окна к этому моменту уже посчитан
        // под текст функцией dictationHUDTranscriptSize. Скругление меньше
        // капсульного - у прямоугольной панели половина высоты дала бы стадион.
        return DictationHUDGlassShape(
            body: CGRect(x: inset, y: inset,
                         width: size.width - inset * 2, height: size.height - inset * 2),
            bodyRadius: min(DICTATION_HUD_TRANSCRIPT_RADIUS, (size.height - inset * 2) / 2)
        )

    case .vanishing:
        let side = DICTATION_HUD_BAR_MIN_HEIGHT * 3
        return DictationHUDGlassShape(
            body: CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                         width: side, height: side),
            bodyRadius: side / 2
        )
    }
}

/// Какая форма у стадии конвейера. Стадий больше, чем форм, и это осознанно:
/// «не услышал», «таймаут» и «сбой» показывают одно и то же - работа кончилась
/// ничем, - и разводить их разной ГЕОМЕТРИЕЙ значит просить владельца различать
/// то, что он различать не обязан. Различает их знак внутри.
func dictationHUDGlassForm(for stage: DictationHUDStage) -> DictationHUDGlassForm {
    switch stage {
    case .resting:
        return .resting
    case .listening:
        return .listening
    case .recognizing, .buildingPrompt:
        return .thinking
    case .inserted, .promptSavedAfterFocusChange:
        return .done
    case .notDelivered, .promptNotDelivered, .promptFailed,
         .nothingRecognized, .recognitionTimedOut, .recognitionFailed, .refused:
        // Любой отказ собирается в кружок, и в нём горит крестик. Слова
        // владельца 04.09.2026: волна «должна из линий потом также схлопнуться
        // в кружочек, в котором будет красный крестик». Прежде часть отказов
        // оставалась широкой плашкой - формой успеха, - и отличалась только
        // цветом; теперь неудача отличается и формой.
        return .done
    }
}

/// Линейная развёртка формы в форму. Перетекание - это интерполяция ГЕОМЕТРИИ,
/// а не кроссфейд двух картинок: кроссфейд глаз читает как подмену, а движение
/// одного и того же стекла - как одно непрерывное действие.
public func dictationHUDGlassShape(from: DictationHUDGlassShape,
                                   to: DictationHUDGlassShape,
                                   progress: CGFloat) -> DictationHUDGlassShape {
    let t = min(1, max(0, progress.isFinite ? progress : 0))
    func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
    func lerp(_ a: CGRect, _ b: CGRect) -> CGRect {
        CGRect(x: lerp(a.origin.x, b.origin.x), y: lerp(a.origin.y, b.origin.y),
               width: lerp(a.width, b.width), height: lerp(a.height, b.height))
    }
    return DictationHUDGlassShape(
        body: lerp(from.body, to.body),
        bodyRadius: lerp(from.bodyRadius, to.bodyRadius)
    )
}
