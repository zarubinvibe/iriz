// Звуковая волна: столбики, которые ведёт голос.
//
// Решение владельца 03.09.2026, вечер: «отказываемся от этих вот линий красных
// и фиолетовых... давай вернём вот эти вот звуковые волны. Просто сделай это
// красиво. Они могут быть на прозрачном стекле... зелёные или синие и красные,
// если вдруг что-то оборвалось... чтобы они действительно двигались за голосом
// и чтобы они были показательными».
//
// Ключевое слово - ПОКАЗАТЕЛЬНЫЕ. Столбик, высота которого взята из текущего
// уровня и продублирована по всей ширине, показывает одно число двадцать восемь
// раз - это украшение. Показательна ИСТОРИЯ: самый правый столбик - то, что
// сказано сейчас, левые - то, что сказано до, и вся фраза видна целиком, как в
// диктофоне. Поэтому вход тут - кольцо уровней, а не одно число.
import CoreGraphics
import Foundation

/// Столбиков в волне. На 114 pt ширины при шаге 4,05 их укладывается 28:
/// меньше - и волна становится эквалайзером из восьми полосок, больше - и
/// отдельный столбик перестаёт читаться на ретине в натуральную величину.
public let DICTATION_HUD_BAR_COUNT = 28
/// Толщина столбика и просвет между ними.
/// Толщина ядра столбика. Тоньше, чем кажется нужным: свет у диода даёт не
/// ядро, а ореол вокруг него, и толстое ядро съедает разлёт. Решение
/// владельца по кадру: «и линию саму тоньше, и ореол чуть пошире».
public let DICTATION_HUD_BAR_WIDTH: CGFloat = 1.3
public let DICTATION_HUD_BAR_GAP: CGFloat = 2.75
/// Столбик тишины. Не ноль: волна, севшая в прямую линию, читается как
/// «записи нет», а запись идёт. Это та же ошибка, что уже была на ленте.
public let DICTATION_HUD_BAR_MIN_HEIGHT: CGFloat = 2.4

/// Высоты столбиков из истории уровней, в долях полувысоты 0…1.
///
/// `levels` идёт от старого к новому. Коротка история - недостающее слева
/// добивается тишиной, и волна «въезжает» справа, а не прыгает целиком.
public func dictationHUDWaveBarHeights(levels: [Float],
                                       count: Int = DICTATION_HUD_BAR_COUNT) -> [CGFloat] {
    guard count > 0 else { return [] }
    var out = [CGFloat](repeating: 0, count: count)
    let tail = levels.suffix(count)
    let offset = count - tail.count
    for (index, level) in tail.enumerated() {
        let clamped = dictationHUDPerceptualLevel(level)
        out[offset + index] = CGFloat(clamped)
    }
    return out
}

/// Высота столбика в пунктах. Отдельной функцией, потому что «минимум не ноль»
/// - правило, а не деталь рисования, и оно обязано быть под тестом.
public func dictationHUDWaveBarLength(fraction: CGFloat, span: CGFloat) -> CGFloat {
    let f = fraction.isFinite ? min(1, max(0, fraction)) : 0
    return max(DICTATION_HUD_BAR_MIN_HEIGHT, span * f)
}

/// Насколько волна должна СЛИТЬСЯ В ПОЛОСУ от тишины.
///
/// Слова владельца: «когда тишина была полоса, а не маленькие круглые точечки;
/// полоса может сливаться просто в отдельную длинную полосу». Отдельные
/// столбики минимальной высоты и правда читаются цепочкой точек - это дефект,
/// а не покой.
///
/// Считается по САМОМУ ГРОМКОМУ из недавних, а не по среднему: в живой речи
/// паузы между словами короткие, и среднее в них проваливается - полоса
/// мигала бы на каждом вдохе.
public func dictationHUDSilenceCollapse(levels: [Float],
                                        window: Int = 6) -> CGFloat {
    guard !levels.isEmpty else { return 1 }
    let recent = levels.suffix(max(1, window))
    let peak = recent.reduce(Float(0)) { max($0, $1) }
    let loud = dictationHUDPerceptualLevel(peak)
    // Полностью полоса ниже 0,06 перцептивных, полностью волна выше 0,22:
    // между ними плавный переход, поэтому слияние читается движением, а не
    // переключателем.
    let low: CGFloat = 0.06
    let high: CGFloat = 0.22
    let t = (CGFloat(loud) - low) / (high - low)
    return 1 - min(1, max(0, t))
}

/// Волна работы: голоса уже нет, а работа идёт.
///
/// Без неё «распознаёт» выглядит точно как «записывает», только застывшим -
/// и владелец не может отличить работу от зависания. Уровни тут не от
/// микрофона, а собственные: три синуса разной частоты, взвешенные к центру.
/// Приём взят у живой волны ElevenLabs на 21st.dev; числа свои, под наш размер.
public func dictationHUDWorkingLevels(phase: CGFloat, count: Int) -> [Float] {
    guard count > 0 else { return [] }
    return (0..<count).map { index in
        let position = (CGFloat(index) - CGFloat(count) / 2) / (CGFloat(count) / 2)
        // К центру волна выше: работа идёт «внутри», а не по всей ширине.
        let centre = 1 - (abs(position) * 0.55)
        let a = sin((phase * 1.5) + position * 3.0) * 0.25
        let b = sin((phase * 0.8) - position * 2.0) * 0.20
        let c = cos((phase * 2.0) + position) * 0.15
        return Float(min(1, max(0.04, (0.22 + a + b + c) * centre)))
    }
}

/// Кольцо уровней. Держит ровно столько, сколько показывает волна: хранить
/// больше незачем, а меньше - значит терять начало фразы.
public struct DictationHUDLevelTrail: Equatable, Sendable {
    private(set) var levels: [Float] = []
    private let capacity: Int

    public init(capacity: Int = DICTATION_HUD_BAR_COUNT) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ level: Float) {
        let value = level.isFinite ? min(1, max(0, level)) : 0
        levels.append(value)
        if levels.count > capacity { levels.removeFirst(levels.count - capacity) }
    }

    public mutating func reset() { levels.removeAll(keepingCapacity: true) }

    public var heights: [CGFloat] { dictationHUDWaveBarHeights(levels: levels, count: capacity) }
}
