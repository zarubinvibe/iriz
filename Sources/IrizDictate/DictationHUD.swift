// Части адаптированы из SuperDictate (форк Parakey), © 2026 Richard Courtman, лицензия MIT.
// Полный текст: THIRD-PARTY/SuperDictate-LICENSE
// Решения плашки «идёт голос» — чистые функции без AppKit.
//
// Почему отдельным файлом, тем же приёмом, что DictationDelivery.swift: живую
// панель под `swift test` не поднять (у ad-hoc бинаря нет NSApplication и
// WindowServer), поэтому все РЕШЕНИЯ вынесены сюда и покрыты тестами:
// какое состояние конвейера что показывает, какой уровень передать волне,
// когда плашка обязана уйти, просить ли анимацию. В
// DictationHUDPresenter остаётся порядок вызовов, в DictationHUDWindow —
// только рисование, там нет ни одного решения.
import IrizCore
import CoreGraphics
import Foundation

// MARK: - Что плашка показывает

/// Короткая безопасная таксономия. В ней нет stderr, сырья или внешнего
/// ответа, поэтому значение можно отдать HUD и в постоянный лог.
enum PromptFailureKind: CaseIterable, Equatable {
    case executableConfiguration
    case launchRuntime
    case timeout
    case invalidResult
    case artifactConflict
}

/// Состояние плашки. Ровно то, о чём есть что сказать; всё остальное — её
/// отсутствие (см. `DictationHUDPresentation.hidden`).
enum DictationHUDStage: Equatable {
    /// Идёт запись — живой уровень голоса, ради него всё и делается.
    ///
    /// Режим лежит В САМОЙ стадии, а не читается по ходу дела: пока плашка на
    /// экране, `recordingPurpose` контроллера уже успевает обнулиться на
    /// отпускании клавиши, и живой опрос вернул бы «обычная диктовка» посреди
    /// промпт-записи. Значение, снятое в момент показа, соврать не может.
    case listening(DictationRecordingPurpose)
    /// Распознавание: уровня уже нет, идёт работа.
    case recognizing
    /// Сырьё уже распознано; Codex собирает из него готовый промпт.
    case buildingPrompt
    /// Текст ушёл в поле — короткое подтверждение и уход.
    case inserted
    /// Текст НИКУДА не попал. Самое важное состояние плашки: молчать здесь
    /// нельзя, владелец решит, что вставилось.
    case notDelivered(TextInsertionFailure)
    /// Распознавание вернуло пустоту: тишина в микрофон (`savedToHistory` = false,
    /// каталога на диске нет) или словарь замен съел весь текст (= true, сырьё
    /// на диске лежит). Плашка обязана различать эти два случая, иначе она
    /// соврёт про сохранённую запись.
    case nothingRecognized(savedToHistory: Bool)
    /// Сторож распознавания закрыл попытку — ASR не успел.
    case recognitionTimedOut
    /// Распознавание упало ошибкой (модель отгрузилась, сбой CoreML) или сырьё
    /// не легло на диск (нет места, права). Текст не вставлен, и `savedToHistory`
    /// говорит, осталась ли от надиктовки хоть запись: при `false` она потеряна
    /// целиком, и обещать историю тут — ложь.
    case recognitionFailed(savedToHistory: Bool)
    /// Генератор не вернул готовый промпт. Сырьё осталось в истории.
    case promptFailed(PromptFailureKind)
    /// Промпт готов и лежит в истории, но в поле не попал.
    case promptNotDelivered(TextInsertionFailure)
    /// Промпт готов и сохранён, но за время генерации владелец сменил окно.
    /// Вставлять в новый фокус опасно, поэтому результат остаётся в истории.
    case promptSavedAfterFocusChange
    /// Запись не стартовала, причина известна.
    case refused(DictationStartRefusal)
}

// MARK: - Геометрия визуального контракта

let DICTATION_HUD_VISUAL_SCALE: CGFloat = 1.15

/// Окно плашки. Пилюли за лентой больше нет — «в этой плашке мне не нужна сзади
/// пузырек», 11.08.2026, — поэтому окно перестало быть «пилюля плюс поле под
/// ореол» и стало просто холстом под ленту.
///
/// Числа изменились именно из-за этого. Пилюля 73,6 × 43,7 была почти квадратной:
/// её распирала не волна, а собственный кант с полем под свечение. Свободная
/// лента хочет обратного — она ШИРЕ и НИЖЕ: 124,2 × 36,8 (108 × 32 при масштабе
/// 1,15). По площади это больше прежнего окна на 42 %, и это осознанная цена:
/// щелчок по плашке до приложения под ней не доходит (HUD_SPEC §8), зато волне
/// есть где течь, а не биться о кант.
/// Размер объявлен ОДИН раз - в DictationHUDSize.swift как DICTATION_HUD_BASE_SIZE.
/// Здесь он стоял вторым экземпляром того же числа: ворота грепали одно имя, а вся
/// арифметика размеров считала от другого. Четвёртый разъехавшийся источник правды
/// в этом проекте; предыдущие три уже стоили отказов.
/// Из чего разворачивается лента на входе. Прежде это был диаметр круга,
/// вырастающего в пилюлю; теперь — искра, из которой лента растёт вширь и ввысь.
let DICTATION_HUD_REVEAL_START_DIAMETER: CGFloat = 6.9

/// Сколько ленты видно в тишине, в долях полного размаха она пересчитывается
/// в `dictationHUDRibbonAmplitude`. Мёртвая прямая линия соврала бы, что записи нет.
let DICTATION_HUD_RIBBON_REST_SPAN: CGFloat = 5.5
/// Полный размах ленты на записи (от края до края).
let DICTATION_HUD_RIBBON_LISTENING_SPAN: CGFloat = 24.0
/// То же на распознавании: там голоса уже нет, и лента живёт своим ходом.
let DICTATION_HUD_RIBBON_PROCESSING_SPAN: CGFloat = 25.5

/// Ширина ленты целиком. Прежде она наследовалась от решётки восьми столбиков
/// (39,39 pt) — столбиков нет с 11.08.2026, а число за ними тянулось только
/// потому, что лента жила внутри пилюли и шире не помещалась.
///
/// Без пилюли ограничения нет: 96,6 pt (84 × 1,15) — это в 2,45 раза длиннее
/// прежнего. Форма кривой считается в нормированном x и от растяжения не
/// меняется: та же волна, только разложенная по длине. Ровно это и делает её
/// похожей на образец — там широкая текучая лента, а не короткий всплеск.
let DICTATION_HUD_WAVEFORM_WIDTH: CGFloat = 96.6

// Ведущий знак промпт-режима — шеврон слева от волны. Числа кратны 1,15, как
// вся геометрия плашки.
let DICTATION_HUD_MARK_WIDTH: CGFloat = 4.6
let DICTATION_HUD_MARK_HEIGHT: CGFloat = 9.2
let DICTATION_HUD_MARK_LINE_WIDTH: CGFloat = 1.725
let DICTATION_HUD_MARK_GAP: CGFloat = 3.45
/// На сколько знак сдвигает волну вправо: половина занятого им места, чтобы
/// «шеврон + волна» стояли по центру пилюли, а не волна сама по себе.
let DICTATION_HUD_MARK_SHIFT = (DICTATION_HUD_MARK_WIDTH + DICTATION_HUD_MARK_GAP) / 2

// Ореол. До 11.08.2026 это было кольцо по канту пилюли; канта нет, и кольца
// быть не может — оно и есть контур «пузырька». Ось при этом ЖИВА: ореол
// переехал с пилюли на саму ленту и стал её аурой — мягким свечением, которое
// обнимает ленту и сходит на нет. Смысл прежний («идёт запись», у промпта —
// с направлением), носитель другой.
/// Постоянная спада ауры в пунктах от края ленты. 3,45 = 3 × 1,15: на семи
/// пунктах наружу остаётся 13 %, на десяти — 5,5 %, то есть аура умирает
/// заведомо внутри окна и её нечему обрезать.
let DICTATION_HUD_HALO_SPREAD: CGFloat = 2.10
let DICTATION_HUD_HALO_IDLE_ALPHA: CGFloat = 0.04
let DICTATION_HUD_HALO_VOICE_ALPHA: CGFloat = 0.075
/// На столько аура раздаётся от голоса.
let DICTATION_HUD_HALO_VOICE_SPREAD: CGFloat = 0.12
/// Долей длины ленты за единицу фазы. При тишине (фаза 16,96 рад/с) гребень
/// проходит ленту за ~5,9 с, на полном голосе за ~3,7 с: медленно и текуче,
/// без мигания.
let DICTATION_HUD_HALO_TRAVEL_SPEED: CGFloat = 0.010
/// Насколько узкий гребень. Больше — острее пятно, меньше — ровнее свечение.
/// Пологий: гребень должен течь, а не бежать пятном.
let DICTATION_HUD_HALO_FALLOFF: CGFloat = 1.6
/// Ровная доля бегущей ауры: лента никогда не гаснет целиком, иначе пятно
/// читалось бы как мигание, а не как течение.
let DICTATION_HUD_HALO_FLOOR: CGFloat = 0.42
/// Бегущая аура светит ярче ровной. Без этого промпт-режим выглядел бы ТУСКЛЕЕ
/// обычной диктовки: у ровного свечения горит вся лента разом, у бегущего —
/// только гребень, и в среднем его меньше.
let DICTATION_HUD_HALO_TRAVEL_GAIN: CGFloat = 1.7

/// Насколько глубоко гребень ведёт саму ленту, 0 … 1.
///
/// Гребень обязан вести не только юбку свечения, но и ленту под ней. Замерено
/// на кадрах `motion-*-prompt-halo-*`: добавка к одной юбке тонет — там уже
/// горит лоренцев хвост нитей, и четверти его яркости глаз не видит. Ось «ход
/// свечения» была жива в модели и мертва на экране, а это одна из четырёх осей
/// различия режимов, и терять её нельзя.
///
/// 0,62 даёт контраст 1,7× между впадиной и гребнем: свет ТЕЧЁТ по ленте.
/// Единица дала бы 2,4× — лента на впадине проваливалась бы, и это читалось бы
/// уже не течением, а разрывом.
let DICTATION_HUD_HALO_RIDGE_DEPTH: CGFloat = 0.62

/// Средняя яркость гребня по длине ленты.
///
/// Нужна, чтобы модуляция не меняла СРЕДНЮЮ яркость: множитель ходит вокруг
/// единицы, а не вокруг чего придётся. Иначе промпт-лента поехала бы по общей
/// яркости вслед за формой гребня — а яркость здесь уже занята голосом.
func dictationHUDHaloRidgeMean(floor: CGFloat = DICTATION_HUD_HALO_FLOOR,
                               falloff: CGFloat = DICTATION_HUD_HALO_FALLOFF,
                               steps: Int = 2048) -> CGFloat {
    guard steps > 0 else { return 1 }
    var total: CGFloat = 0
    for step in 0..<steps {
        total += dictationHUDHaloRidge(at: CGFloat(step) / CGFloat(steps),
                                       head: 0,
                                       floor: floor,
                                       falloff: falloff)
    }
    return total / CGFloat(steps)
}

/// Яркость гребня в точке `position` (доля длины ленты) при голове `head`.
/// Ровная доля не даёт ленте гаснуть целиком: иначе бегущее пятно читалось бы
/// миганием, а не течением.
func dictationHUDHaloRidge(at position: CGFloat,
                           head: CGFloat,
                           floor: CGFloat = DICTATION_HUD_HALO_FLOOR,
                           falloff: CGFloat = DICTATION_HUD_HALO_FALLOFF) -> CGFloat {
    guard position.isFinite, head.isFinite else { return 1 }
    let wave = (cos((position - head) * 2 * .pi) + 1) / 2
    return floor + ((1 - floor) * pow(max(0, wave), falloff))
}

/// Множитель яркости ленты под гребнем. Среднее по длине ровно единица:
/// гребень перекладывает свет вдоль ленты, а не подкручивает её общую яркость —
/// та уже занята голосом.
func dictationHUDHaloRidgeGain(_ ridge: CGFloat,
                               depth: CGFloat = DICTATION_HUD_HALO_RIDGE_DEPTH,
                               mean: CGFloat = dictationHUDHaloRidgeMean()) -> CGFloat {
    guard ridge.isFinite, mean > 0.0001 else { return 1 }
    return (1 - depth) + (ridge * depth / mean)
}

// О ПОДЛОЖКЕ ПОД ЛЕНТОЙ — решено 11.08.2026, подложки НЕТ.
//
// Опасение было обоснованным: плашка висит поверх ЧУЖОГО содержимого, а пилюля
// раньше решала это грубой силой — почти непрозрачная плита сама задавала фон.
// Поэтому был сделан и отрисован второй вариант: мягкий эллиптический спад под
// лентой, чёрный в тёмной теме и белый в светлой, ровно ноль на кромке окна.
//
// Кадры решили спор против него. Лента отдаёт наружу ПОКРЫТИЕ, а не свет: её
// яркость становится её же альфой, поэтому наружу она ложится обычным
// source-over и от фона не зависит вовсе. На белом документе, на сером, на
// чёрном терминале и на странице с текстом она читается одинаково — проверено
// кадрами `over-*` и наложением на синтетический документ. Подложка при этом
// видна везде, кроме точного совпадения с фоном: на белом это грязное серое
// пятно, на среднем сером — тёмный эллипс. Она не добавляла читаемости и
// добавляла ровно то, от чего уезжали, — пятно позади волны.
//
// Останется соблазн вернуть её «на всякий случай»: не надо. Сначала кадр,
// на котором лента без неё не читается.

// MARK: - Плашка исхода

/// Исход — СООБЩЕНИЕ, а не индикатор. Живая запись висит на экране минутами и
/// не имеет права нести за собой рамку; «вставил» живёт 0,9 с, «не вставилось» —
/// 5 с, и у момента подложка защитима там, где у постоянного индикатора нет.
/// Поэтому исходы уехали в компактную плашку со своим фоном, а лента осталась
/// голой. Форма у плашки НЕ пилюля, а скруглённый квадрат: это другой объект,
/// и путать его с прежним «пузырьком» нельзя.
let DICTATION_HUD_CHIP_SIZE: CGFloat = 32.2
let DICTATION_HUD_CHIP_RADIUS: CGFloat = 10.35
let DICTATION_HUD_CHIP_BORDER_WIDTH: CGFloat = 1.15
/// Длина прямой линии исхода («вставил», «ничего не услышал») внутри плашки.
/// Прежде это была вся лента в 39,4 pt; в плашке 32,2 pt столько не влезает,
/// да и незачем: линия здесь знак, а не осевшая волна.
let DICTATION_HUD_CHIP_LINE_WIDTH: CGFloat = 18.4

// MARK: - Лента волны

/// Палитра ленты — выбор владельца в настройках.
///
/// Режим она НЕ отменяет. Цвет — одна из четырёх осей, по которым видно,
/// обычная это диктовка или промпт, и в любой палитре тон у режимов свой.
/// Поэтому «Монохром» — это отсутствие ПЕРЕЛИВОВ, а не серая лента: серой она
/// стёрла бы цветовую ось и оставила режимы на трёх осях вместо четырёх.
public enum DictationHUDWavePalette: String, CaseIterable, Sendable {
    /// Как в образце: тона разнесены по спектру, а не по соседним оттенкам.
    /// У диктовки лента идёт розовый → красный → оранжевый → янтарный,
    /// у промпта голубой → синий → индиго → фиолетовый.
    case spectral
    /// Те же нити, но разлёт тонов вдвое с лишним уже: переливы видно краем
    /// глаза, а лента читается почти одноцветной.
    case calm
    /// Переливов нет вовсе: все нити тона режима, остаётся только свечение
    /// и объём ленты.
    case mono
}

/// Заводская палитра. Отдельным именем, чтобы «по умолчанию» было в одном
/// месте, а не тремя литералами по файлам.
public let DICTATION_HUD_DEFAULT_WAVE_PALETTE = DictationHUDWavePalette.spectral

public func dictationHUDWavePaletteTitle(_ palette: DictationHUDWavePalette) -> String {
    switch palette {
    case .spectral: return "Переливы"
    case .calm: return "Спокойная"
    case .mono: return "Монохром"
    }
}

/// Точек, по которым строится кривая. Кадр экспорта рисуется в 4×, и на
/// 39,4 pt ширины этого хватает: дуги не ломаются в грани.
let DICTATION_HUD_RIBBON_SAMPLES = 56
/// Показатель колокола огибающей. Чем больше, тем раньше лента растворяется
/// у краёв — она не обрывается о кант пилюли, а сходит на нет.
let DICTATION_HUD_RIBBON_BELL: CGFloat = 1.85
/// Нитей в ленте. Четыре: две крайние держат хроматику и заливку между собой,
/// две внутренние — ядро. Трёх мало, потому что при разводе ПО ФАЗЕ середина
/// ленты пустеет ровно там, где крайние разошлись, и лента распадается на две
/// проволоки с дыркой посередине.
let DICTATION_HUD_RIBBON_STRANDS = 4
/// Слоёв свечения на нить: растущая толщина при падающей альфе вместо плоской
/// обводки. Так на 1,15 pt получается мягкое ядро с длинным хвостом.
let DICTATION_HUD_RIBBON_GLOW_LAYERS = 4
let DICTATION_HUD_RIBBON_CORE_WIDTH: CGFloat = 0.92
/// Во сколько раз каждый следующий слой свечения шире ядра.
let DICTATION_HUD_RIBBON_GLOW_STEP: CGFloat = 2.3
/// Насколько быстрее падает яркость слоя, чем растёт его толщина. Больше
/// единицы — иначе широкие слои забили бы ядро и лента стала бы плоской.
let DICTATION_HUD_RIBBON_GLOW_FALLOFF: CGFloat = 3.6
/// Заливка между крайними нитями. Слабее линий: из-за неё это читается лентой,
/// а не четырьмя проволоками.
let DICTATION_HUD_RIBBON_FILL_ALPHA: CGFloat = 0.34
/// Доля ширины, на которой лента проявляется и гаснет по краям.
let DICTATION_HUD_RIBBON_FADE: CGFloat = 0.17
/// Хроматический разлёт нитей — В РАДИАНАХ ФАЗЫ, на крайнюю нить.
///
/// Здесь была вертикальная раздвижка, и в этом была вся ошибка: параллельные
/// кривые дают одну волну, нарисованную несколько раз рядом, то есть толстую
/// цветную верёвку. Сдвиг по фазе даёт другое. На гребнях, где наклон нулевой,
/// сдвинутая кривая совпадает с исходной; на крутых участках она отходит от неё
/// во всю высоту и там же переходит на другую сторону. Нити расходятся,
/// пересекаются и снова сливаются — это глаз и читает как призму и как
/// жидкий свет.
///
/// Внутри одного хода волны число ОДНО на все моды, и это принципиально.
/// Одинаковый сдвиг вдоль X означал бы разный сдвиг фазы у мод разной частоты:
/// высокая мода уезжала бы на целую длину волны, нити наматывались друг
/// на друга, и лента превращалась в гребёнку. Одинаковая ФАЗА держит их вместе.
///
/// У бегущей волны разлёт меньше: её моды выше частотой и плотнее набиты
/// по длине, поэтому тот же разлёт даёт вдвое больше пересечений на той же
/// ширине — снова гребёнка. Числа подобраны глазами по кадрам.
///
/// У образца это 2,6 рад на квадратном холсте. У нас лента втрое мельче,
/// и на 15 pt высоты 2,6 рад дают кашу.
///
/// Огибающая от разлёта не зависит, поэтому у торцов нити снова сходятся.
let DICTATION_HUD_RIBBON_ABERRATION: CGFloat = 1.95
let DICTATION_HUD_RIBBON_ABERRATION_FORWARD: CGFloat = 1.25
/// Насколько нить подмешана к белому у ядра ленты. Крайние нити остаются
/// спектральными, внутренние выбелены: так пересечение читается светом,
/// а не краской. На светлом фоне не применяется — там лента ложится краской,
/// и белая краска это дырка.
let DICTATION_HUD_RIBBON_CORE_WHITE: CGFloat = 0.34
/// Насколько тон нити насыщеннее исходного акцента.
///
/// Сложение света съедает насыщенность: нити, сложившись, тянут цвет
/// к белому, и сильнее всего страдает фиолетовый — у него высокий минимальный
/// канал. Поднятая насыщенность опускает этот канал заранее, поэтому промпт
/// на нахлёсте остаётся фиолетовым, а не сиреневато-белым.
let DICTATION_HUD_RIBBON_SATURATION_GAIN: CGFloat = 1.32

/// Параметр нити: −1 … +1, ноль — ядро. Одно число задаёт и сдвиг фазы,
/// и сдвиг тона, и вес нити, поэтому нити не могут разъехаться между собой.
func dictationHUDRibbonStrandParameters(count: Int = DICTATION_HUD_RIBBON_STRANDS) -> [CGFloat] {
    guard count > 1 else { return [0] }
    let last = CGFloat(count - 1)
    return (0..<count).map { ((CGFloat($0) / last) * 2) - 1 }
}

/// Ядро ярче крыльев: без этого нити читаются набором проволок, а не лентой
/// с плотной серединой.
func dictationHUDRibbonStrandWeight(_ strand: CGFloat) -> CGFloat {
    guard strand.isFinite else { return 1 }
    return 1 - (0.44 * min(1, abs(strand)))
}

/// Колокол: 1 в центре, 0 на краях.
func dictationHUDRibbonEnvelope(x: CGFloat) -> CGFloat {
    guard x.isFinite else { return 0 }
    let clamped = min(1, max(-1, x))
    return pow(max(0, cos(clamped * .pi / 2)), DICTATION_HUD_RIBBON_BELL)
}

/// Отклонение нити от осевой линии в долях полувысоты, x ∈ [−1, 1].
///
/// Нить — это ОДНА кривая, сдвинутая по фазе на `strand · ABERRATION` радиан.
/// Больше нить не отличается ничем: ни своей частотой, ни своим дыханием.
/// Отсюда весь эффект. Сдвинутая по фазе кривая совпадает с исходной на
/// гребнях, где наклон нулевой, и отходит от неё на крутых участках — то есть
/// нити то сливаются в одну, то расходятся во всю высоту и меняются местами.
/// Развод по вертикали, который тут был раньше, давал ровно противоположное:
/// постоянный зазор везде, то есть одну волну, нарисованную несколько раз рядом.
///
/// Огибающая от разлёта не зависит, поэтому у торцов нити снова сходятся.
///
/// Симметричный ход — СТОЯЧАЯ волна: `cos` чётен, а разлёт у нитей встречный
/// (`strand` пробегает симметричный набор), поэтому ЛЕНТА зеркальна
/// относительно центра — при отражении нить `+s` переходит в нить `−s`.
/// Направленный — БЕГУЩАЯ: гребни идут слева направо, и по ленте видно, куда
/// она течёт. Ось «ход волны» держится самой формой кривой, а не подсветкой,
/// поэтому она жива и на стоп-кадре, когда движение выключено.
func dictationHUDRibbonSample(x: CGFloat,
                              phase: CGFloat,
                              amplitude: CGFloat,
                              flow: DictationHUDWaveFlow,
                              strand: CGFloat) -> CGFloat {
    guard x.isFinite, phase.isFinite, amplitude.isFinite, strand.isFinite else { return 0 }
    let clamped = min(1, max(-1, x))
    let envelope = dictationHUDRibbonEnvelope(x: clamped)
    let body: CGFloat
    switch flow {
    case .symmetric:
        // Обе моды дышат ПОЛОЖИТЕЛЬНЫМ множителем (0,2 … 1), а не свободной
        // синусоидой, и это не украшение. Зеркальность запрещает волне сдвигаться
        // по x, поэтому единственная свобода у неё — амплитуды мод; у свободных
        // синусоид они изредка проходят ноль одновременно, и лента на пару кадров
        // вырождается в прямую. На записи такой проблеск читался бы как «звук
        // пропал», хотя владелец говорит.
        //
        // Разнообразие формы даёт не знак, а ПЛЫВУЩАЯ ЧАСТОТА мод: центральный
        // горб то шире, то уже, фланги ходят по x. Косинус чётен при любой
        // частоте, поэтому зеркальность от этого не страдает.
        let broad = cos(((1.62 + (0.26 * sin(phase * 0.29))) * .pi * clamped)
                        + (strand * DICTATION_HUD_RIBBON_ABERRATION))
        let fine = cos(((3.95 + (0.40 * sin((phase * 0.19) + 1.7))) * .pi * clamped)
                       + (strand * DICTATION_HUD_RIBBON_ABERRATION))
        body = (0.74 * broad * (0.72 + (0.28 * sin(phase * 0.92))))
            + (0.24 * fine * (0.70 + (0.30 * sin((phase * 1.43) + 1.1))))
    case .forward:
        let lead = sin((2.30 * .pi * clamped) - (phase * 1.05)
                       + (strand * DICTATION_HUD_RIBBON_ABERRATION_FORWARD))
        let trail = sin((3.75 * .pi * clamped) - (phase * 0.61) + 0.8
                        + (strand * DICTATION_HUD_RIBBON_ABERRATION_FORWARD))
        body = (0.76 * lead) + (0.20 * trail)
    }
    return envelope * amplitude * body
}

/// Размах ленты в долях полувысоты. Ведёт его голос — ради этого всё
/// и делается; в тишине остаётся медленное дыхание, чтобы лента была живой.
/// `motion` = false («Уменьшение движения») убирает дыхание, но не голос:
/// уровень по-прежнему виден, просто без собственного хода.
func dictationHUDRibbonAmplitude(audio: CGFloat, phase: CGFloat, motion: Bool) -> CGFloat {
    let audio = audio.isFinite ? min(1, max(0, audio)) : 0
    let rest = DICTATION_HUD_RIBBON_REST_SPAN / DICTATION_HUD_RIBBON_LISTENING_SPAN
    guard motion, phase.isFinite else { return min(1, rest + (0.62 * audio)) }
    let breath = (sin(phase * 0.37) + 1) / 2
    return min(1, rest + (0.07 * breath) + (0.62 * audio))
}

/// Куда расслаивается тон нити от цвета режима, в долях цветового круга.
///
/// Разлёт широкий — на нём и держится призма: у диктовки лента идёт розовый →
/// красный → оранжевый → янтарный, у промпта голубой → синий → индиго →
/// фиолетовый. Это разные СЕМЕЙСТВА, а не соседние оттенки одной палитры.
///
/// Семейства не имеют права сойтись: цвет — одна из четырёх осей различия
/// режимов. Поэтому разлёт не симметричен, а перекошен от границы между ними:
/// тёплое уходит к янтарю сильнее, чем к пурпуру, холодное — к фиолетовому
/// сильнее, чем к зелени. Перекос задаёт `dictationHUDRibbonHueBias`,
/// а держит его тест «семейства режимов не пересекаются».
func dictationHUDRibbonHueOffset(palette: DictationHUDWavePalette,
                                 accent: DictationHUDAccent,
                                 strand: CGFloat) -> CGFloat {
    guard strand.isFinite else { return 0 }
    let spread: CGFloat
    switch palette {
    case .spectral: spread = 0.145
    case .calm: spread = 0.060
    case .mono: spread = 0
    }
    let bias = dictationHUDRibbonHueBias(for: accent)
    let parameter = min(1, max(-1, strand))
    return parameter * spread * (parameter < 0 ? 1 + bias : 1 - bias)
}

/// Перекос разлёта: положительный — вниз по кругу, отрицательный — вверх.
private func dictationHUDRibbonHueBias(for accent: DictationHUDAccent) -> CGFloat {
    switch accent {
    // Вниз от фиолетового — к синему и голубому. Вверх нельзя: там пурпур,
    // то есть розовый край диктовки.
    case .violet: return 0.55
    // Синий стоит ниже фиолетового, и ему вниз уже нельзя — под голубым
    // начинается зелень, а она занята исходом «вставил». Значит вверх.
    case .blue: return -0.40
    // Голубому тем более вверх: вниз от него зелень вплотную.
    case .cyan: return -0.58
    // Тёплые разлетаются в обе стороны, но к янтарю дальше, чем к пурпуру:
    // пурпур — это уже пограничье с холодным семейством.
    case .red, .orange: return -0.24
    case .green, .yellow, .neutral: return 0
    }
}

/// Насколько нить подмешана к белому. Крайние нити остаются спектральными,
/// внутренние выбелены: пересечение выбеленных нитей читается СВЕТОМ, а набор
/// одинаково насыщенных — краской. Ноль на краю ленты, максимум у ядра.
func dictationHUDRibbonWhiteMix(strand: CGFloat) -> CGFloat {
    guard strand.isFinite else { return 0 }
    let parameter = min(1, max(-1, strand))
    return DICTATION_HUD_RIBBON_CORE_WHITE * (1 - abs(parameter))
}

let DICTATION_HUD_HINT_GAP: CGFloat = 8
let DICTATION_HUD_HINT_HORIZONTAL_PADDING: CGFloat = 10
let DICTATION_HUD_HINT_VERTICAL_PADDING: CGFloat = 7
let DICTATION_HUD_HINT_LINE_HEIGHT: CGFloat = 15
let DICTATION_HUD_HINT_LINE_GAP: CGFloat = 3
let DICTATION_HUD_HINT_MIN_WIDTH: CGFloat = 120
let DICTATION_HUD_HINT_MAX_WIDTH: CGFloat = 240
let DICTATION_HUD_HINT_RADIUS: CGFloat = 10
let DICTATION_HUD_HINT_BORDER_WIDTH: CGFloat = 1

let DICTATION_HUD_DRAG_THRESHOLD: CGFloat = 3
let DICTATION_HUD_EDGE_INSET: CGFloat = 12

let DICTATION_HUD_HOVER_ENTER_DELAY: TimeInterval = 0.12
let DICTATION_HUD_HOVER_ENTER_DURATION: TimeInterval = 0.18
let DICTATION_HUD_HOVER_EXIT_DELAY: TimeInterval = 0.26
let DICTATION_HUD_HOVER_EXIT_DURATION: TimeInterval = 0.14
let DICTATION_HUD_REVEAL_IN_DURATION: TimeInterval = 0.32
let DICTATION_HUD_REVEAL_OUT_DURATION: TimeInterval = 0.23
let DICTATION_HUD_PROCESSING_TRANSITION_DURATION: TimeInterval = 0.20
let DICTATION_HUD_MINIMUM_PROCESSING_VISIBILITY: TimeInterval = 0.24
let DICTATION_HUD_DRAG_HINT_LIMIT = 5

// MARK: - Стадия → форма и акцент

/// Только геометрический смысл. Цвет живёт отдельно, поэтому новые состояния
/// можно группировать без AppKit и без ложного текстового символа.
enum DictationHUDForm: Equatable {
    case waveform
    case processing
    case line
    case historyLine
    case exclamation
    case ellipsis
    case slash
}

/// Рисуется ли форма в плашке исхода (со своей подложкой) или голой лентой
/// поверх чужого содержимого.
///
/// Разделение проходит ровно по границе «живой индикатор ↔ момент сообщения»,
/// то есть совпадает с `dictationHUDStageIsTerminal`. Совпадение держится
/// тестом: разъедься они — и либо у живой записи вернётся пузырёк, либо исход
/// потеряет подложку и станет нечитаемым поверх чужого окна.
func dictationHUDFormShowsChip(_ form: DictationHUDForm) -> Bool {
    switch form {
    case .waveform, .processing:
        return false
    case .line, .historyLine, .exclamation, .ellipsis, .slash:
        return true
    }
}

enum DictationHUDAccent: Equatable {
    case red
    /// Холодный сине-фиолетовый промпт-режима. Отдельный кейс, а не оттенок
    /// синего: с синим распознавания он не должен путаться.
    case violet
    case blue
    case cyan
    case green
    case yellow
    case orange
    case neutral
}

/// Ведущий знак слева от волны. Шеврон читается как «отсюда пойдёт указание» —
/// у обычной диктовки знака нет вовсе.
enum DictationHUDMark: Equatable {
    case none
    case chevron
}

/// Ход волны. Диктовка расходится симметрично от центра (голос как он есть),
/// промпт течёт слева направо (речь превращается в инструкцию, у неё есть
/// направление).
enum DictationHUDWaveFlow: Equatable {
    case symmetric
    case forward
}

/// Ореол по канту пилюли. Ровный — просто «идёт запись»; бегущий по кругу —
/// промпт-режим.
enum DictationHUDHalo: Equatable {
    case none
    case even
    case traveling
}

/// Четыре независимые оси различия. Одного цвета мало: он не работает при
/// дальтонизме и тонет на светлом фоне под плашкой, поэтому режим несут ещё
/// знак, ход волны и ореол. Ни одна ось не зависит от анимации — при
/// «уменьшении движения» цвет и знак остаются на месте.
struct DictationHUDVisual: Equatable {
    let form: DictationHUDForm
    let accent: DictationHUDAccent
    let mark: DictationHUDMark
    let flow: DictationHUDWaveFlow
    let halo: DictationHUDHalo

    /// Умолчания — «ничего лишнего»: состояния исхода несут только форму и
    /// цвет, и добавление осей не должно было переписывать их все.
    init(form: DictationHUDForm,
         accent: DictationHUDAccent,
         mark: DictationHUDMark = .none,
         flow: DictationHUDWaveFlow = .symmetric,
         halo: DictationHUDHalo = .none) {
        self.form = form
        self.accent = accent
        self.mark = mark
        self.flow = flow
        self.halo = halo
    }
}

/// Исчерпывающая таблица визуала. Prompt-состояния перечислены явно: добавление
/// промпт-режима не должно молча откатывать их к старому SF Symbol.
///
/// Две записи `listening` — это и есть весь смысл разделения: раньше обе
/// диктовки выглядели одинаково, пока владелец говорит, и режим проявлялся
/// только на распознавании, когда менять что-то уже поздно.
func dictationHUDVisual(for stage: DictationHUDStage) -> DictationHUDVisual {
    switch stage {
    case .listening(.dictation):
        return .init(form: .waveform, accent: .red,
                     mark: .none, flow: .symmetric, halo: .even)
    case .listening(.prompt):
        return .init(form: .waveform, accent: .violet,
                     mark: .chevron, flow: .forward, halo: .traveling)
    case .listening(.translation):
        return .init(form: .waveform, accent: .violet,
                     mark: .none, flow: .forward, halo: .even)
    case .recognizing:
        return .init(form: .processing, accent: .blue)
    case .buildingPrompt:
        return .init(form: .processing, accent: .cyan)
    case .inserted:
        return .init(form: .line, accent: .green)
    case .notDelivered, .recognitionFailed, .promptFailed, .promptNotDelivered:
        return .init(form: .exclamation, accent: .yellow)
    case .nothingRecognized(savedToHistory: false):
        return .init(form: .line, accent: .neutral)
    case .nothingRecognized(savedToHistory: true):
        return .init(form: .historyLine, accent: .neutral)
    case .recognitionTimedOut:
        return .init(form: .ellipsis, accent: .yellow)
    case .promptSavedAfterFocusChange:
        return .init(form: .historyLine, accent: .green)
    case .refused:
        return .init(form: .slash, accent: .orange)
    }
}

enum DictationHUDPresentation: Equatable {
    case hidden
    case visible(DictationHUDStage)
}

/// Идёт ли живая запись — любым режимом. Отдельной функцией, потому что после
/// `listening(purpose)` сравнение `stage == .listening` больше не компилируется,
/// а «идёт запись» спрашивают в пяти местах.
func dictationHUDIsListening(_ stage: DictationHUDStage) -> Bool {
    if case .listening = stage { return true }
    return false
}

/// Терминальная плашка сказала про исход и уходит по таймеру сама. Нетерминальная
/// (`listening`, `recognizing`) живёт ровно пока идёт работа.
func dictationHUDStageIsTerminal(_ stage: DictationHUDStage) -> Bool {
    switch stage {
    case .listening, .recognizing, .buildingPrompt:
        return false
    case .inserted, .notDelivered, .nothingRecognized, .recognitionTimedOut,
         .recognitionFailed, .promptFailed, .promptNotDelivered,
         .promptSavedAfterFocusChange, .refused:
        return true
    }
}

// MARK: - Состояние конвейера → плашка

/// Что показывать при таком состоянии конвейера, если сейчас видно `current`.
///
/// Ключевая тонкость: `.ready` приходит СРАЗУ за вердиктом доставки
/// (`finishTranscription` в defer той же задачи). Если бы `.ready` гасил плашку,
/// «не вставилось» мигнуло бы на один кадр и исчезло — то есть главное сообщение
/// продукта владелец бы не прочитал. Поэтому терминальную плашку `.ready` не
/// трогает: её снимает свой таймер или новая запись.
func dictationHUDPresentation(pipelineState state: DictationController.State,
                              purpose: DictationRecordingPurpose,
                              current: DictationHUDStage?) -> DictationHUDPresentation {
    switch state {
    case .recording:
        return .visible(.listening(purpose))
    case .transcribing:
        return .visible(.recognizing)
    case .generatingPrompt:
        return .visible(.buildingPrompt)
    case .ready, .warmingUp, .unavailable:
        // `unavailable` держится вечно (нет разрешения, модель не загрузилась) —
        // такое сообщение живёт в строке меню, а не плашкой поверх работы.
        guard let current, dictationHUDStageIsTerminal(current) else { return .hidden }
        return .visible(current)
    }
}

/// Вердикт доставки → плашка. `waiting` — окно подтверждения истекло, а цель
/// текст так и не забрала: для владельца это ровно «не вставилось».
func dictationHUDStage(forDeliveryVerdict verdict: TextInsertionVerdict) -> DictationHUDStage {
    switch verdict {
    case .delivered:
        return .inserted
    case .waiting:
        return .notDelivered(.targetNeverRequestedText)
    case .notDelivered(let failure):
        return .notDelivered(failure)
    }
}

/// Prompt уже сохранён до вставки, поэтому её провал нельзя показывать как
/// обычное «не вставилось»: владелец может скопировать готовый текст из истории.
func dictationHUDStage(forPromptDeliveryVerdict verdict: TextInsertionVerdict) -> DictationHUDStage {
    switch verdict {
    case .delivered:
        return .inserted
    case .waiting:
        return .promptNotDelivered(.targetNeverRequestedText)
    case .notDelivered(let failure):
        return .promptNotDelivered(failure)
    }
}

/// Отказ старта → плашка, или `nil` — «не трогать то, что на экране».
///
/// Два отказа из четырёх плашкой НЕ показываются, и это не послабление, а
/// разница по смыслу. `alreadyRecording` и `transcriptionInFlight` означают
/// «я уже это делаю», а не «не получилось»: работа идёт и вот-вот даст
/// результат. Подменить живое «слушаю» или «думаю» красным крестом значит
/// соврать, что всё сорвалось.
///
/// Поймано владельцем живьём 04.09.2026: он нажал клавишу второй раз, пока шла
/// расшифровка первой, увидел КРАСНУЮ ошибку, а через две секунды - зелёную
/// галочку успешной вставки. Два разных события подряд, читаются как одна ложь.
/// Правило для `alreadyRecording` тогда уже стояло, а `transcriptionInFlight`
/// в него не попал, хотя довод для обоих один и тот же.
///
/// Остальные два - настоящие отказы: `secureInputActive` (в поле пароля писать
/// нечем) и `modelNotReady` (распознавать нечем), их показывать обязательно.
///
/// Раньше здесь стоял `.hidden`, а `.hidden` для презентера — это `hide()`, то
/// есть снос живой панели и остановка опроса уровня посреди идущей записи.
/// Живого пути к этому в автомате хоткея нет, но исход «оставить как есть»
/// обязан быть отдельным от исхода «погасить», иначе следующая правка автомата
/// получит гаснущую посреди записи плашку и зелёный гейт.
func dictationHUDStage(forStartRefusal refusal: DictationStartRefusal) -> DictationHUDStage? {
    switch refusal {
    case .alreadyRecording, .transcriptionInFlight: return nil
    case .secureInputActive, .modelNotReady: return .refused(refusal)
    }
}

// MARK: - Сколько плашка живёт

let DICTATION_HUD_INSERTED_SECONDS: TimeInterval = 0.9
/// Сколько плашка держится, когда текст не доехал.
///
/// Дольше любого другого исхода, и намеренно: с 04.09.2026 плашка на этом
/// исходе не просто говорит «не вставилось», а РАЗВОРАЧИВАЕТСЯ в панель с
/// текстом, который надо успеть прочитать и забрать. Пяти секунд на это мало:
/// владелец ещё переводит взгляд, когда панель уже уходит.
let DICTATION_HUD_NOT_DELIVERED_SECONDS: TimeInterval = 20
let DICTATION_HUD_NOTHING_SECONDS: TimeInterval = 2.5
let DICTATION_HUD_TIMED_OUT_SECONDS: TimeInterval = 3
let DICTATION_HUD_REFUSED_SECONDS: TimeInterval = 2
/// Столько же, сколько «не вставилось»: это тот же класс беды — текста в поле нет.
let DICTATION_HUD_RECOGNITION_FAILED_SECONDS: TimeInterval = DICTATION_HUD_NOT_DELIVERED_SECONDS

/// Через сколько плашка уходит сама, или `nil` — держится, пока идёт работа.
/// «Не вставилось» живёт дольше всех: это единственное сообщение, которое
/// владелец обязан успеть прочитать целиком.
func dictationHUDDismissDelay(for stage: DictationHUDStage) -> TimeInterval? {
    switch stage {
    case .listening, .recognizing, .buildingPrompt:
        return nil
    case .inserted:
        return DICTATION_HUD_INSERTED_SECONDS
    case .notDelivered:
        return DICTATION_HUD_NOT_DELIVERED_SECONDS
    case .nothingRecognized:
        return DICTATION_HUD_NOTHING_SECONDS
    case .recognitionTimedOut:
        return DICTATION_HUD_TIMED_OUT_SECONDS
    case .recognitionFailed:
        return DICTATION_HUD_RECOGNITION_FAILED_SECONDS
    case .promptFailed:
        return DICTATION_HUD_NOT_DELIVERED_SECONDS
    case .promptNotDelivered:
        return DICTATION_HUD_NOT_DELIVERED_SECONDS
    case .promptSavedAfterFocusChange:
        return DICTATION_HUD_NOTHING_SECONDS
    case .refused:
        return DICTATION_HUD_REFUSED_SECONDS
    }
}

// MARK: - Уровень голоса

/// 20 Гц: глазу этого хватает, а процессору такой опрос незаметен. Таймер живёт
/// ТОЛЬКО в записи — гашение проверено тестом, иначе он молотил бы вечно.
let DICTATION_HUD_LEVEL_POLL_SECONDS: TimeInterval = 1.0 / 20

private func dictationHUDNormalizedLevel(_ level: Float) -> Float {
    guard level.isFinite else { return 0 }
    return min(1, max(0, level))
}

/// Перцептивная кривая уровня: столько ленты видно на слух, а не по RMS.
///
/// Здесь был обычный `clamp`, и это первый из четырёх дефектов ленты. Слух
/// логарифмический, RMS линейный, а владелец диктует не крича: на его обычном
/// уровне 0,04...0,3 линейная шкала оставляла ленту плоской светящейся нитью,
/// то есть плашка выглядела мёртвой ровно тогда, когда он говорит.
///
/// Показатель подобран глазами по кадрам в натуральную величину: 0,45 поднимает
/// тихую речь 0,04 до 0,23 размаха и не выжигает громкую - на единице кривая
/// по-прежнему единица, то есть громкость не теряет верх шкалы.
func dictationHUDPerceptualLevel(_ level: Float) -> Float {
    let clamped = dictationHUDNormalizedLevel(level)
    guard clamped > 0 else { return 0 }
    return pow(clamped, DICTATION_HUD_LEVEL_PERCEPTUAL_EXPONENT)
}

let DICTATION_HUD_LEVEL_PERCEPTUAL_EXPONENT: Float = 0.45

/// Голос вспыхивает быстро, но затухает плавно. Коэффициенты адаптированы к
/// нашему опросу 20 Гц; наружу всё равно выходит непрерывный Float 0...1.
func dictationHUDSmoothedLevel(previous: Float, raw: Float) -> Float {
    let previous = dictationHUDNormalizedLevel(previous)
    let raw = dictationHUDNormalizedLevel(raw)
    let coefficient: Float = raw > previous ? 0.65 : 0.28
    return previous + (raw - previous) * coefficient
}

/// Сколько тиков одной и той же sequence считаются залипшим потоком.
/// При опросе 20 Гц это ровно 400 мс тишины от аудиодвижка: меньше - обычная
/// пауза между пакетами, больше - лента застыла бы в воздухе на глазах.
/// Число было безымянной восьмёркой прямо в условии.
let DICTATION_HUD_STALE_LEVEL_TICKS = 8

/// Одна sequence дольше восьми тиков - аудиопоток залип примерно на 400 мс.
func dictationHUDLevelIsStale(sameSequenceTicks: Int) -> Bool {
    sameSequenceTicks > DICTATION_HUD_STALE_LEVEL_TICKS
}

private let DICTATION_HUD_LISTENING_PHASE_BASE: CGFloat = 16.96
private let DICTATION_HUD_LISTENING_PHASE_LEVEL: CGFloat = 10.08
private let DICTATION_HUD_PROCESSING_PHASE_SPEED: CGFloat = 10.2

func dictationHUDPhaseSpeed(stage: DictationHUDStage, level: Float) -> CGFloat {
    switch stage {
    case .listening:
        // Темп ведёт та же перцептивная шкала, что и размах: иначе тихая речь
        // поднимала бы ленту, но не ускоряла её, и лента читалась бы вялой.
        return DICTATION_HUD_LISTENING_PHASE_BASE
            + CGFloat(dictationHUDPerceptualLevel(level)) * DICTATION_HUD_LISTENING_PHASE_LEVEL
    case .recognizing, .buildingPrompt:
        return DICTATION_HUD_PROCESSING_PHASE_SPEED
    case .inserted, .notDelivered, .nothingRecognized, .recognitionTimedOut,
         .recognitionFailed, .promptFailed, .promptNotDelivered,
         .promptSavedAfterFocusChange, .refused:
        return 0
    }
}

/// Display link нужен только живой фазе или незавершённой анимации. В режиме
/// уменьшения движения он не запускается вообще.
func dictationHUDNeedsDisplayLink(stage: DictationHUDStage?,
                                  revealAnimating: Bool,
                                  hoverAnimating: Bool,
                                  reduceMotion: Bool) -> Bool {
    guard !reduceMotion, let stage else { return false }
    return revealAnimating || hoverAnimating || dictationHUDPhaseSpeed(stage: stage, level: 0) > 0
}

/// Опрашивать уровень только в записи. Вне неё уровня нет, и таймер обязан стоять.
func dictationHUDPollsLevel(_ stage: DictationHUDStage) -> Bool {
    dictationHUDIsListening(stage)
}

/// Просить ли анимацию уровня. «Уменьшение движения» → нет: полоски меняют
/// значение мгновенно, без пружин и переходов. Режим записи при этом виден
/// по-прежнему — цвет, знак и ореол движения не требуют.
func dictationHUDAnimatesLevel(stage: DictationHUDStage, reduceMotion: Bool) -> Bool {
    dictationHUDIsListening(stage) && !reduceMotion
}

/// Просить ли анимацию ожидания (крутилка распознавания). При «уменьшении
/// движения» вместо неё статичный знак.
func dictationHUDAnimatesWaiting(stage: DictationHUDStage, reduceMotion: Bool) -> Bool {
    (stage == .recognizing || stage == .buildingPrompt) && !reduceMotion
}

// MARK: - Слова

struct DictationHUDContent: Equatable {
    let stage: DictationHUDStage
    let visual: DictationHUDVisual
    /// Непрерывный уровень 0...1. Геометрию волны рисует AppKit-вид.
    let level: Float
    let title: String
    let detail: String?
    let animatesLevel: Bool
    let animatesWaiting: Bool
    let accessibilityLabel: String
    /// Текст, который не доехал. Не nil ровно тогда, когда плашка обязана
    /// РАЗВЕРНУТЬСЯ в панель и показать его: «эта плашка трансформируется в
    /// зону, где текст напечатан, и я его могу копировать».
    ///
    /// Едет тем же каналом, что и остальное содержимое плашки, а не отдельной
    /// дорожкой: два пути к одному экрану рано или поздно разъезжаются.
    var transcript: String?
}

func dictationHUDTitle(for stage: DictationHUDStage) -> String {
    switch stage {
    case .listening(.dictation):
        return "слушаю"
    case .listening(.prompt):
        // Цвет, знак и ореол видит зрячий. Голосовому доступу режим тоже
        // положен — иначе промпт-запись от обычной на слух не отличить.
        return "слушаю для промпта"
    case .listening(.translation):
        return "слушаю для перевода"
    case .recognizing:
        return "распознаю"
    case .buildingPrompt:
        return "собираю промпт"
    case .inserted:
        return "вставил"
    case .notDelivered:
        return "не вставилось"
    case .nothingRecognized(let savedToHistory):
        // Разные слова для разных фактов: в первом случае звук был и лежит на
        // диске, во втором ASR не услышал вообще ничего и сохранять было нечего.
        return savedToHistory ? "ничего не разобрал" : "ничего не услышал"
    case .recognitionTimedOut:
        return "не успел распознать"
    case .recognitionFailed:
        // Не «не успел» — распознавание сломалось, а не затянулось. Разные
        // слова, потому что разные факты.
        return "сбой распознавания"
    case .promptFailed(let kind):
        return dictationHUDPromptFailureTitle(kind)
    case .promptNotDelivered, .promptSavedAfterFocusChange:
        return "промпт сохранён"
    case .refused:
        return "не записываю"
    }
}

/// Вторая строка. Появляется только когда есть что добавить по делу.
func dictationHUDDetail(for stage: DictationHUDStage, historyHint: String) -> String? {
    switch stage {
    case .listening, .recognizing, .buildingPrompt, .inserted, .recognitionTimedOut:
        return nil
    case .notDelivered:
        // Сырьё к этому моменту уже на диске (иначе задача ушла бы в catch и до
        // вердикта не дошла), так что подсказка правдива всегда.
        return dictationHUDHistoryDetail(historyHint)
    case .nothingRecognized(let savedToHistory):
        return savedToHistory ? dictationHUDHistoryDetail(historyHint) : nil
    case .recognitionFailed(let savedToHistory):
        // Молчать про потерю нельзя, но и обещать историю, когда сырья на диске
        // нет, — тоже: этой ложью проект уже болел и второй раз не будет.
        return savedToHistory ? dictationHUDHistoryDetail(historyHint) : "запись не сохранилась"
    case .promptFailed(let kind):
        return dictationHUDPromptFailureRecovery(kind, historyHint: historyHint)
    case .promptNotDelivered:
        return historyHint.isEmpty
            ? "скопируйте из истории"
            : "скопируйте из истории: \(historyHint)"
    case .promptSavedAfterFocusChange:
        return historyHint.isEmpty
            ? "окно сменилось; промпт в истории"
            : "окно сменилось; история: \(historyHint)"
    case .refused(let refusal):
        return dictationHUDRefusalReason(refusal)
    }
}

/// Марку агента плашка не называет: он теперь выбирается владельцем, и
/// приколоченное «Codex» лгало бы всем, кто выбрал не Codex.
private func dictationHUDPromptFailureTitle(_ kind: PromptFailureKind) -> String {
    switch kind {
    case .executableConfiguration: return "агент не настроен"
    case .launchRuntime: return "агент не сработал"
    case .timeout: return "агент не успел"
    case .invalidResult: return "ответ агента отклонён"
    case .artifactConflict: return "промпт уже сохранён"
    }
}

private func dictationHUDPromptFailureRecovery(
    _ kind: PromptFailureKind,
    historyHint: String
) -> String {
    let action: String
    switch kind {
    case .executableConfiguration:
        action = "проверьте путь в настройках"
    case .artifactConflict:
        return historyHint.isEmpty
            ? "ничего не заменил; откройте историю"
            : "ничего не заменил; откройте историю (\(historyHint))"
    case .launchRuntime, .timeout, .invalidResult:
        action = "повторите"
    }
    return historyHint.isEmpty
        ? "\(action); надиктовка в истории"
        : "\(action); надиктовка в истории (\(historyHint))"
}

private func dictationHUDHistoryDetail(_ historyHint: String) -> String {
    historyHint.isEmpty
        ? "запись сохранил — она в истории"
        : "запись сохранил — она в истории (\(historyHint))"
}

func dictationHUDRefusalReason(_ refusal: DictationStartRefusal) -> String {
    switch refusal {
    case .secureInputActive:
        return "открыто поле пароля"
    case .modelNotReady:
        return "модель ещё греется"
    case .alreadyRecording:
        return "запись уже идёт"
    case .transcriptionInFlight:
        return "ещё распознаю прошлую"
    }
}

/// В свёрнутой плашке текста нет, но голосовой доступ получает полный смысл.
func dictationHUDAccessibilityLabel(title: String, detail: String?) -> String {
    guard let detail, !detail.isEmpty else { return "\(IRIZ_NAME): \(title)" }
    return "\(IRIZ_NAME): \(title). \(detail)"
}

func dictationHUDContent(stage: DictationHUDStage,
                         level: Float,
                         reduceMotion: Bool,
                         historyHint: String,
                         transcript: String? = nil) -> DictationHUDContent {
    let title = dictationHUDTitle(for: stage)
    let detail = dictationHUDDetail(for: stage, historyHint: historyHint)
    return DictationHUDContent(
        stage: stage,
        visual: dictationHUDVisual(for: stage),
        level: dictationHUDIsListening(stage) ? dictationHUDNormalizedLevel(level) : 0,
        title: title,
        detail: detail,
        animatesLevel: dictationHUDAnimatesLevel(stage: stage, reduceMotion: reduceMotion),
        animatesWaiting: dictationHUDAnimatesWaiting(stage: stage, reduceMotion: reduceMotion),
        accessibilityLabel: dictationHUDAccessibilityLabel(title: title, detail: detail),
        transcript: dictationHUDShowsTranscript(stage: stage) ? transcript : nil
    )
}

/// Разворачивается ли плашка в панель с текстом на этой стадии.
///
/// Только там, где текст СУЩЕСТВУЕТ, но не доехал. «Не услышал» и «отказ» сюда
/// не попадают: показывать пустую панель значит обещать текст, которого нет.
func dictationHUDShowsTranscript(stage: DictationHUDStage) -> Bool {
    switch stage {
    case .notDelivered, .promptNotDelivered, .promptSavedAfterFocusChange: return true
    default: return false
    }
}

// MARK: - Подпись хоткея истории

private let DICTATION_HUD_MODIFIER_LABELS: [CGKeyCode: String] = [
    59: "левый ⌃", 62: "правый ⌃",
    58: "левый ⌥", 61: "правый ⌥",
    56: "левый ⇧", 60: "правый ⇧",
    55: "левый ⌘", 54: "правый ⌘",
    63: "fn",
]

/// Клавиши, у которых есть честная русская подпись без латиницы. Символы взяты
/// те, что напечатаны на самой клавише (⏎, ⇥, ⌫), — читаются без перевода.
private let DICTATION_HUD_KEY_LABELS: [CGKeyCode: String] = [
    36: "⏎", 76: "⌤", 48: "⇥", 49: "пробел", 51: "⌫", 117: "⌦",
    115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 71: "⌧", 114: "справка",
    123: "←", 124: "→", 125: "↓", 126: "↑",
]

/// Русская подпись клавиши, или `nil` — честного русского имени нет.
///
/// В интерфейсе владельца английского быть не должно, а таблица имён проекта
/// английская (`Return`, `Space`, `Left Option`), поэтому её имя годится только
/// когда в нём нет латиницы: цифры и знаки пунктуации проходят, `Keypad 5` и
/// буквы — нет. Статическую карту ЙЦУКЕН для буквенных клавиш здесь не заводим:
/// проект уже ловил расхождение такой карты с реальной раскладкой машины
/// (см. `KeyMapping`), и лучше промолчать, чем назвать клавишу неверно.
private func dictationHUDKeyLabel(keycode: CGKeyCode) -> String? {
    if let modifier = DICTATION_HUD_MODIFIER_LABELS[keycode] { return modifier }
    if let russian = DICTATION_HUD_KEY_LABELS[keycode] { return russian }
    if let function = FUNCTION_KEY_NAMES_BY_KEYCODE[keycode] {
        return "функциональная \(function.dropFirst())"
    }
    let name = hotkeyChoice(forKeycode: keycode).name
    return dictationHUDHasLatin(name) ? nil : name
}

func dictationHUDHasLatin(_ text: String) -> Bool {
    text.range(of: "[A-Za-z]", options: .regularExpression) != nil
}

/// Подпись хоткея истории по НАСТРОЕННЫМ клавишам, а не по константе: владелец
/// мог их сменить, а плашка не имеет права отправлять его нажимать не то.
/// Пустая строка — клавишу назвать по-русски нечем; подсказка тогда обходится
/// без скобок вообще (см. `dictationHUDHistoryDetail`), а не печатает английское
/// имя вроде `Return` или `Left Option`.
func dictationHUDHistoryHint(keycode: CGKeyCode, modifiers: CGEventFlags) -> String {
    let normalized = modifiers.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
    guard let base = dictationHUDKeyLabel(keycode: keycode) else { return "" }
    let ownFlag = MODIFIER_HOTKEY_CHOICES.first { $0.keycode == keycode }?.modifierFlag
    let extra = normalized.subtracting(ownFlag ?? [])
    let symbols = dictationHUDModifierSymbols(extra)
    return symbols.isEmpty ? base : "\(base) + \(symbols)"
}

private func dictationHUDModifierSymbols(_ flags: CGEventFlags) -> String {
    var result = ""
    if flags.contains(.maskControl) { result += "⌃" }
    if flags.contains(.maskAlternate) { result += "⌥" }
    if flags.contains(.maskShift) { result += "⇧" }
    if flags.contains(.maskCommand) { result += "⌘" }
    if flags.contains(.maskSecondaryFn) { result += "fn" }
    return result
}

// MARK: - Подсказка при наведении

private func dictationHUDHistoryHintLine(_ historyLabel: String,
                                         fallback: String = "запись в истории") -> String {
    historyLabel.isEmpty ? fallback : "\(historyLabel) — история"
}

/// Не больше двух коротких строк. `hotkeyLabel` уже выбран вызывающим кодом
/// для обычной диктовки или prompt-режима — модель не подменяет его дефолтом.
func dictationHUDHintLines(stage: DictationHUDStage,
                           triggerMode: TriggerMode,
                           hotkeyLabel: String,
                           historyLabel: String,
                           showsDragHint: Bool) -> [String] {
    var lines: [String]
    switch stage {
    case .listening:
        let finish: String
        switch triggerMode {
        case .toggle:
            finish = hotkeyLabel.isEmpty ? "закончить запись" : "\(hotkeyLabel) — закончить"
        case .hold:
            finish = hotkeyLabel.isEmpty ? "отпустите клавишу" : "отпустите \(hotkeyLabel)"
        }
        lines = [finish, "Esc — отменить"]
    case .recognizing:
        lines = ["идёт распознавание"]
    case .buildingPrompt:
        lines = ["собираю промпт"]
    case .inserted:
        lines = ["вставил"]
    case .notDelivered:
        lines = ["текст не вставился", dictationHUDHistoryHintLine(historyLabel)]
    case .nothingRecognized(savedToHistory: true):
        lines = ["ничего не разобрал", dictationHUDHistoryHintLine(historyLabel)]
    case .nothingRecognized(savedToHistory: false):
        lines = ["ничего не услышал"]
    case .recognitionTimedOut:
        lines = ["не успел распознать"]
    case .recognitionFailed(savedToHistory: true):
        lines = ["сбой распознавания", dictationHUDHistoryHintLine(historyLabel)]
    case .recognitionFailed(savedToHistory: false):
        lines = ["сбой распознавания", "запись не сохранилась"]
    case .promptFailed, .promptNotDelivered, .promptSavedAfterFocusChange:
        lines = [dictationHUDTitle(for: stage)]
        if let detail = dictationHUDDetail(for: stage, historyHint: historyLabel) {
            lines.append(detail)
        }
    case .refused(let refusal):
        lines = [dictationHUDRefusalReason(refusal)]
    }

    if showsDragHint, lines.count < 2 {
        lines.append("мышью — переставить")
    }
    return Array(lines.prefix(2))
}

func dictationHUDShowsDragHint(shownCount: Int) -> Bool {
    max(0, shownCount) < DICTATION_HUD_DRAG_HINT_LIMIT
}

// MARK: - Где плашка стоит

/// Выбирает сохранённый монитор только вместе с валидной сохранённой позицией.
/// Если монитор отключён, доли применяются к экрану под курсором.
func dictationHUDRestoredDisplayID(savedPosition: CGPoint?,
                                   savedDisplayID: UInt32?,
                                   availableDisplayIDs: [UInt32],
                                   cursorDisplayID: UInt32) -> UInt32 {
    guard savedPosition != nil,
          let savedDisplayID,
          availableDisplayIDs.contains(savedDisplayID) else {
        return cursorDisplayID
    }
    return savedDisplayID
}

/// Отступ от низа видимой области. Владелец смотрит в поле ввода — плашка
/// попадает в периферийное зрение и не перекрывает само поле.
let DICTATION_HUD_BOTTOM_MARGIN: CGFloat = 96

/// Плашка по центру внизу видимой области экрана, целиком внутри неё.
func dictationHUDFrame(size: CGSize,
                       in visibleFrame: CGRect,
                       bottomMargin: CGFloat = DICTATION_HUD_BOTTOM_MARGIN) -> CGRect {
    let width = min(max(0, size.width), visibleFrame.width)
    let height = min(max(0, size.height), visibleFrame.height)
    let x = visibleFrame.midX - width / 2
    let highestY = visibleFrame.maxY - height
    let y = min(max(visibleFrame.minY, visibleFrame.minY + bottomMargin), max(visibleFrame.minY, highestY))
    return CGRect(x: x, y: y, width: width, height: height)
}

func dictationHUDPositionFraction(frame: CGRect, in visibleFrame: CGRect) -> CGPoint {
    let x = visibleFrame.width > 0 && frame.midX.isFinite
        ? (frame.midX - visibleFrame.minX) / visibleFrame.width
        : 0.5
    let y = visibleFrame.height > 0 && frame.midY.isFinite
        ? (frame.midY - visibleFrame.minY) / visibleFrame.height
        : 0.5
    return CGPoint(x: min(1, max(0, x.isFinite ? x : 0.5)),
                   y: min(1, max(0, y.isFinite ? y : 0.5)))
}

func dictationHUDRestoredFrame(size: CGSize,
                               fraction: CGPoint,
                               in visibleFrame: CGRect) -> CGRect {
    let fractionX = fraction.x.isFinite ? min(1, max(0, fraction.x)) : 0.5
    let fractionY = fraction.y.isFinite ? min(1, max(0, fraction.y)) : 0.5
    let center = CGPoint(x: visibleFrame.minX + visibleFrame.width * fractionX,
                         y: visibleFrame.minY + visibleFrame.height * fractionY)
    let proposed = CGRect(x: center.x - max(0, size.width) / 2,
                          y: center.y - max(0, size.height) / 2,
                          width: size.width,
                          height: size.height)
    return dictationHUDClampedFrame(proposed, in: visibleFrame)
}

private func dictationHUDClampedAxis(origin: CGFloat,
                                     length: CGFloat,
                                     visibleOrigin: CGFloat,
                                     visibleLength: CGFloat,
                                     edgeInset: CGFloat) -> (origin: CGFloat, length: CGFloat) {
    let visibleLength = visibleLength.isFinite ? max(0, visibleLength) : 0
    let requestedLength = length.isFinite ? max(0, length) : 0
    let requestedInset = edgeInset.isFinite ? max(0, edgeInset) : 0
    // На области меньше двойного отступа важнее сохранить валидный кадр, чем
    // имитировать невозможные 12 pt с обеих сторон.
    let inset = visibleLength >= requestedInset * 2 ? requestedInset : 0
    let availableLength = max(0, visibleLength - inset * 2)
    let resultLength = min(requestedLength, availableLength)
    let minimum = visibleOrigin + inset
    let maximum = visibleOrigin + visibleLength - inset - resultLength
    let candidate = origin.isFinite ? origin : minimum
    return (min(maximum, max(minimum, candidate)), resultLength)
}

/// Через этот клэмп проходят восстановление, drag и смена конфигурации экранов.
func dictationHUDClampedFrame(_ frame: CGRect,
                              in visibleFrame: CGRect,
                              edgeInset: CGFloat = DICTATION_HUD_EDGE_INSET) -> CGRect {
    let horizontal = dictationHUDClampedAxis(origin: frame.origin.x,
                                             length: frame.size.width,
                                             visibleOrigin: visibleFrame.minX,
                                             visibleLength: visibleFrame.width,
                                             edgeInset: edgeInset)
    let vertical = dictationHUDClampedAxis(origin: frame.origin.y,
                                           length: frame.size.height,
                                           visibleOrigin: visibleFrame.minY,
                                           visibleLength: visibleFrame.height,
                                           edgeInset: edgeInset)
    return CGRect(x: horizontal.origin, y: vertical.origin,
                  width: horizontal.length, height: vertical.length)
}

/// Если drag подвёл любую кромку ближе порога, она садится ровно на тот же
/// отступ, который использует клэмп.
func dictationHUDSnappedFrame(_ frame: CGRect,
                              in visibleFrame: CGRect,
                              edgeInset: CGFloat = DICTATION_HUD_EDGE_INSET) -> CGRect {
    let inset = max(0, edgeInset)
    var snapped = frame
    if abs(frame.minX - visibleFrame.minX) <= inset {
        snapped.origin.x = visibleFrame.minX + inset
    }
    if abs(frame.maxX - visibleFrame.maxX) <= inset {
        snapped.origin.x = visibleFrame.maxX - inset - frame.width
    }
    if abs(frame.minY - visibleFrame.minY) <= inset {
        snapped.origin.y = visibleFrame.minY + inset
    }
    if abs(frame.maxY - visibleFrame.maxY) <= inset {
        snapped.origin.y = visibleFrame.maxY - inset - frame.height
    }
    return dictationHUDClampedFrame(snapped, in: visibleFrame, edgeInset: inset)
}

// MARK: - Чистая математика движения

struct DictationHUDRevealLayers: Equatable {
    let scale: CGFloat
    let backgroundAlpha: CGFloat
    let contentAlpha: CGFloat
    let breathAlpha: CGFloat
}

struct DictationHUDHoverLayers: Equatable {
    let plateAlpha: CGFloat
    let plateOffset: CGFloat
    let windowProgress: CGFloat
}

func dictationHUDSmootherstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
    guard edge0.isFinite, edge1.isFinite, value.isFinite, edge1 > edge0 else {
        return value >= edge1 ? 1 : 0
    }
    let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
    return t * t * t * (t * (t * 6 - 15) + 10)
}

func dictationHUDRevealLayers(progress: CGFloat) -> DictationHUDRevealLayers {
    let progress = progress.isFinite ? min(1, max(0, progress)) : 0
    let scale: CGFloat
    if progress <= 0.68 {
        scale = 1.10 * dictationHUDSmootherstep(edge0: 0, edge1: 0.68, value: progress)
    } else {
        scale = 1.10
            - 0.10 * dictationHUDSmootherstep(edge0: 0.68, edge1: 1, value: progress)
    }
    return .init(
        scale: scale,
        backgroundAlpha: dictationHUDSmootherstep(edge0: 0, edge1: 0.34, value: progress),
        contentAlpha: dictationHUDSmootherstep(edge0: 0.16, edge1: 0.78, value: progress),
        breathAlpha: dictationHUDSmootherstep(edge0: 0.82, edge1: 1, value: progress)
    )
}

func dictationHUDHoverLayers(progress: CGFloat) -> DictationHUDHoverLayers {
    let progress = progress.isFinite ? min(1, max(0, progress)) : 0
    return .init(
        plateAlpha: dictationHUDSmootherstep(edge0: 0, edge1: 0.6, value: progress),
        plateOffset: 6 * dictationHUDSmootherstep(edge0: 0.1, edge1: 1, value: progress),
        windowProgress: progress
    )
}

func dictationHUDAnimationDuration(base: TimeInterval,
                                   from: CGFloat,
                                   to: CGFloat) -> TimeInterval {
    let distance = from.isFinite && to.isFinite ? abs(to - from) : 1
    return max(1.0 / 120, max(0, base) * TimeInterval(distance))
}
