// Волна плашки на GPU: лента света вместо набора обводок.
//
// ПОЧЕМУ ШЕЙДЕР. Красота образца попиксельная: яркость точки =
// интенсивность / (расстояние до кривой + толщина). Это лоренцев спад,
// посчитанный ДЛЯ КАЖДОГО пикселя, и несколько хроматически сдвинутых нитей,
// сложенных светом. Слоёные обводки NSBezierPath такого не выражают в
// принципе — они дают проволоки, а не ленту света, и владелец реагировал
// именно на это. Плюс цена: три нити × четыре обводки × 57 точек + заливка +
// слой прозрачности каждый тик считались на главном потоке, где уже живут
// перехват клавиатуры, захват звука и прогрев ASR.
//
// ЧЬЯ ЗДЕСЬ МАТЕМАТИКА. Своя. Из платного образца взят ПРИЁМ — колокол
// огибающей, хроматическое расслоение, лоренцев спад, лента между нитями, —
// и это обычная графика, ничьей интеллектуальной собственностью не являющаяся
// (`05_next/WAVE_REFERENCE.md` §1-2). Ни строки чужого GLSL в проекте нет.
// Сама кривая — та же `dictationHUDRibbonSample`, что лежит под тестами,
// слово в слово перенесённая в MSL: рисование не имеет права разойтись
// с моделью.
//
// ОДИН ПУТЬ, А НЕ ДВА. Шейдер рендерит в офскрин-текстуру, и живая плашка,
// и раскадровка `--export-hud-animation` берут один и тот же кадр одним и тем
// же кодом. Раздельные пути «живой CAMetalLayer + офскрин для пруфа» дали бы
// приёмку по картинке, которой на экране никто не увидит.
import CoreGraphics
import Foundation
import Metal
import simd

// MARK: - Числа ленты света

/// Толщина ядра нити в пунктах — знаменатель лоренцева спада. Меньше — тоньше
/// и горячее ядро, длиннее хвост.
let DICTATION_HUD_WAVE_THICKNESS: Float = 0.72
/// Яркость нити в ядре. Сумма нитей на пересечении обязана уходить за единицу:
/// именно пережог даёт белое ядро с цветной бахромой — то, ради чего всё
/// и затевалось.
let DICTATION_HUD_WAVE_INTENSITY: Float = 1.18
/// Квадратичная добавка в знаменателе спада. Чистый 1/d затягивает дымкой всю
/// пилюлю; возле ядра эта добавка не значит ничего, далеко — рубит хвост.
let DICTATION_HUD_WAVE_TAIL: Float = 0.19
/// С какой яркости нить начинает выгорать в белое и как быстро. Свет такой
/// силы глаз видит белым, и без пережога лента остаётся цветной верёвкой.
///
/// Порог высокий НАМЕРЕННО: белеть имеет право только само ядро. На пороге
/// 0,52 белым становилась вся нить целиком, и промпт-режим переставал быть
/// фиолетовым — то есть терялась цветовая ось различия режимов, а она
/// отдельное требование и красотой не отменяется.
let DICTATION_HUD_WAVE_HOT_START: Float = 0.88
let DICTATION_HUD_WAVE_HOT_GAIN: Float = 1.15
/// Предел поправки на наклон. Точная перпендикулярная дистанция на крутом
/// участке уводит в бесконечность весь столбец пикселей, и вокруг гребня
/// вырастает прямоугольное зарево. Ограничение оставляет поправку осмысленной
/// на пологом и не даёт ей врать на отвесном.
let DICTATION_HUD_WAVE_SLOPE_LIMIT: Float = 0.9
/// Заливка между крайними нитями. Слабее линий, но НЕ на грани видимости:
/// именно она превращает набор нитей в ленту. При разводе по фазе нити стоят
/// далеко друг от друга, и без плотной заливки между ними виден фон — то есть
/// четыре проволоки вместо одной ленты света.
///
/// 1,55 было подобрано на ленте в 39,4 pt, зажатой в пилюлю. Свободная лента
/// в 96,6 pt разносит пересечения нитей по длине, площадь заливки растёт, и
/// то же число выжигает середину в белое: у промпта пропадал фиолетовый,
/// у распознавания лента становилась сплошным брусом. Проверено кадрами.
let DICTATION_HUD_WAVE_BAND_ALPHA: Float = 1.02
/// Мягкость края заливки в пунктах.
let DICTATION_HUD_WAVE_BAND_FEATHER: Float = 0.85
/// Гамма. Больше единицы душит длинный хвост свечения и оставляет ядро —
/// без неё лента расплывается дымкой на всю пилюлю.
let DICTATION_HUD_WAVE_GAMMA: Float = 1.28
/// На светлом фоне лента ложится краской, а не светом, и тот же хвост читается
/// уже не свечением, а грязью на белой плите. Поэтому там и гамма злее,
/// и хвост режется раньше — приём один, числа разные.
let DICTATION_HUD_WAVE_LIGHT_GAMMA: Float = 2.05
let DICTATION_HUD_WAVE_LIGHT_TAIL: Float = 0.58
let DICTATION_HUD_WAVE_LIGHT_BAND_ALPHA: Float = 0.22
/// Резкость краевого затухания. Лента растворяется у торцов, а не обрывается.
let DICTATION_HUD_WAVE_EDGE: Float = 1.02
/// Во сколько раз аура ярче своей номинальной альфы. Альфы 0,04 … 0,115 были
/// подобраны для кольца на почти чёрной плите; аура лежит рядом с горящей
/// лентой, и на том же числе её просто не видно.
let DICTATION_HUD_WAVE_HALO_GAIN: CGFloat = 2.6
/// Ширина полосы перехода у фронта перекраски, в долях длины волны. Одно число
/// на оба пути рисования — GPU и Core Graphics.
let DICTATION_HUD_WAVE_FRONT_BAND: CGFloat = 0.26

// MARK: - Данные, которые уезжают в шейдер

/// Раскладка обязана совпадать с `Uniforms` в MSL один в один. Порядок полей
/// не косметика: сначала все `float4` (выравнивание 16), потом `float2`, потом
/// скаляры — так между полями не заводится скрытых дыр, и обе стороны считают
/// смещения одинаково.
///
/// Разъехавшаяся раскладка не падает — она тихо рисует не то. Поэтому её
/// держит тест `раскладкаОдинаковаяВSwiftИВШейдере`: он берёт имена полей
/// отражением, вытаскивает объявление `Uniforms` из исходника MSL и сверяет
/// порядок и размер. Добавили поле в один список — тест краснеет, пока
/// не добавите во второй.
struct DictationHUDWaveUniforms {
    var strandParameter = SIMD4<Float>(repeating: 0)
    var strandWeight = SIMD4<Float>(repeating: 0)
    var strandColor0 = SIMD4<Float>(repeating: 0)
    var strandColor1 = SIMD4<Float>(repeating: 0)
    var strandColor2 = SIMD4<Float>(repeating: 0)
    var strandColor3 = SIMD4<Float>(repeating: 0)
    var bandColor = SIMD4<Float>(repeating: 0)
    var frontNear = SIMD4<Float>(repeating: 0)
    var frontFar = SIMD4<Float>(repeating: 0)
    var haloColor = SIMD4<Float>(repeating: 0)

    var viewSize = SIMD2<Float>(repeating: 0)

    var scale: Float = 1
    var alpha: Float = 1
    var waveStartX: Float = 0
    var waveWidth: Float = 1
    var waveMidY: Float = 0
    var halfHeight: Float = 0
    var amplitude: Float = 0
    var phase: Float = 0
    var flow: Float = 0
    var bell: Float = Float(DICTATION_HUD_RIBBON_BELL)
    var thickness: Float = DICTATION_HUD_WAVE_THICKNESS
    var intensity: Float = DICTATION_HUD_WAVE_INTENSITY
    var bandAlpha: Float = DICTATION_HUD_WAVE_BAND_ALPHA
    var bandFeather: Float = DICTATION_HUD_WAVE_BAND_FEATHER
    var gamma: Float = DICTATION_HUD_WAVE_GAMMA
    var edge: Float = DICTATION_HUD_WAVE_EDGE
    var strandCount: Float = 0
    var lightBackground: Float = 0
    var frontEnabled: Float = 0
    var frontHead: Float = 0
    var frontBand: Float = 0
    var haloStrength: Float = 0
    var haloSpread: Float = 1
    var haloTraveling: Float = 0
    var haloHead: Float = 0
    var haloFloor: Float = Float(DICTATION_HUD_HALO_FLOOR)
    var haloFalloff: Float = Float(DICTATION_HUD_HALO_FALLOFF)
    /// Модуляция ленты гребнем: `haloRidgeBase + ridge · haloRidgeScale`.
    /// Оба числа собраны так, что среднее по длине ровно единица.
    var haloRidgeBase: Float = Float(1 - DICTATION_HUD_HALO_RIDGE_DEPTH)
    var haloRidgeScale: Float = Float(DICTATION_HUD_HALO_RIDGE_DEPTH
        / dictationHUDHaloRidgeMean())
    var tail: Float = DICTATION_HUD_WAVE_TAIL
    var hotStart: Float = DICTATION_HUD_WAVE_HOT_START
    var hotGain: Float = DICTATION_HUD_WAVE_HOT_GAIN
    var slopeLimit: Float = DICTATION_HUD_WAVE_SLOPE_LIMIT
}

/// Фаза до Float32 доезжает без потери смысла, но за сутки работы она вырастет
/// до сотен тысяч радиан, и мантисса начнёт съедать доли. Сворачиваем заранее:
/// период у мод несоизмерим, поэтому берём просто большой остаток.
func dictationHUDWavePhase(_ phase: CGFloat) -> Float {
    guard phase.isFinite else { return 0 }
    return Float(phase.truncatingRemainder(dividingBy: 100_000))
}

// MARK: - Сцена кадра

/// Всё, что нужно шейдеру про один кадр. Отдельным типом, чтобы сборка
/// uniform-ов оставалась чистой функцией и проверялась без GPU.
struct DictationHUDWaveScene {
    var viewSize: CGSize
    var scale: CGFloat
    var contentAlpha: CGFloat
    var lightBackground: Bool

    var waveStartX: CGFloat = 0
    /// Ширина ленты В ЭТОМ кадре. Раньше была глобальной константой, потому что
    /// лента не меняла размера; теперь из неё же растёт вход плашки, и ширина
    /// стала частью кадра.
    var waveWidth: CGFloat = DICTATION_HUD_WAVEFORM_WIDTH
    var waveMidY: CGFloat = 0
    var halfHeight: CGFloat = 0
    var amplitude: CGFloat = 0
    var phase: CGFloat = 0
    var flow: DictationHUDWaveFlow = .symmetric
    var strandParameters: [CGFloat] = []
    var strandColors: [SIMD4<Float>] = []
    var bandColor = SIMD4<Float>(repeating: 0)

    /// Фронт перекраски на распознавании: слева цвет работы, справа цвет режима.
    var front: (near: SIMD4<Float>, far: SIMD4<Float>, head: CGFloat, band: CGFloat)?

    /// Аура ленты — бывший ореол по канту пилюли. Канта нет, свечение переехало
    /// на саму ленту, ось «ровно / бежит» цела.
    var haloColor = SIMD4<Float>(repeating: 0)
    var haloStrength: CGFloat = 0
    var haloSpread: CGFloat = 1
    var haloTraveling = false
    var haloHead: CGFloat = 0

}

/// Сцена → uniform-ы. Чистая функция: ни GPU, ни AppKit.
func dictationHUDWaveUniforms(_ scene: DictationHUDWaveScene) -> DictationHUDWaveUniforms {
    var uniforms = DictationHUDWaveUniforms()
    uniforms.viewSize = SIMD2(Float(scene.viewSize.width), Float(scene.viewSize.height))
    uniforms.scale = Float(max(0.0001, scene.scale))
    uniforms.alpha = Float(min(1, max(0, scene.contentAlpha)))

    uniforms.waveStartX = Float(scene.waveStartX)
    uniforms.waveWidth = Float(max(0.0001, scene.waveWidth))
    uniforms.waveMidY = Float(scene.waveMidY)
    uniforms.halfHeight = Float(scene.halfHeight)
    uniforms.amplitude = Float(min(1, max(0, scene.amplitude)))
    uniforms.phase = dictationHUDWavePhase(scene.phase)
    uniforms.flow = scene.flow == .forward ? 1 : 0
    uniforms.lightBackground = scene.lightBackground ? 1 : 0
    if scene.lightBackground {
        uniforms.gamma = DICTATION_HUD_WAVE_LIGHT_GAMMA
        uniforms.tail = DICTATION_HUD_WAVE_LIGHT_TAIL
        uniforms.bandAlpha = DICTATION_HUD_WAVE_LIGHT_BAND_ALPHA
    }

    // Четыре — предел структуры: `strandParameter` и `strandWeight` это float4.
    // Пятая нить молча потерялась бы, а лента стала бы другой.
    let count = min(4, scene.strandParameters.count)
    uniforms.strandCount = Float(count)
    for index in 0..<count {
        let parameter = scene.strandParameters[index]
        uniforms.strandParameter[index] = Float(parameter)
        uniforms.strandWeight[index] = Float(dictationHUDRibbonStrandWeight(parameter))
    }
    let colors = scene.strandColors
    uniforms.strandColor0 = colors.count > 0 ? colors[0] : SIMD4(repeating: 0)
    uniforms.strandColor1 = colors.count > 1 ? colors[1] : uniforms.strandColor0
    uniforms.strandColor2 = colors.count > 2 ? colors[2] : uniforms.strandColor0
    uniforms.strandColor3 = colors.count > 3 ? colors[3] : uniforms.strandColor0
    uniforms.bandColor = scene.bandColor

    if let front = scene.front {
        uniforms.frontEnabled = 1
        uniforms.frontNear = front.near
        uniforms.frontFar = front.far
        uniforms.frontHead = Float(front.head)
        uniforms.frontBand = Float(max(0.0001, front.band))
    }

    uniforms.haloColor = scene.haloColor
    uniforms.haloStrength = Float(max(0, scene.haloStrength))
    uniforms.haloSpread = Float(max(0.0001, scene.haloSpread))
    uniforms.haloTraveling = scene.haloTraveling ? 1 : 0
    uniforms.haloHead = Float(scene.haloHead)
    return uniforms
}

/// Переменная окружения, выключающая GPU насильно. Нужна не для красоты:
/// ветку «на машине нет Metal» иначе нечем проверить на машине, где Metal
/// есть, а непроверенная аварийная ветка — это не аварийная ветка. Раскадровка
/// с ней рисуется прежним путём Core Graphics, и обе картинки ложатся рядом.
let DICTATION_HUD_WAVE_DISABLE_KEY = "SMLTLK_HUD_NO_METAL"

/// Выключен ли GPU-путь переменной окружения. Пустая строка и «0» — это НЕ
/// выключено: иначе случайно объявленная пустая переменная тихо уронила бы
/// плашку на медленный путь, и заметили бы это не сразу.
func dictationHUDWaveDisabledByEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    guard let value = environment[DICTATION_HUD_WAVE_DISABLE_KEY] else { return false }
    let normalized = value.trimmingCharacters(in: .whitespaces).lowercased()
    return !normalized.isEmpty && normalized != "0" && normalized != "false"
}

/// Собрать шейдер заранее. Зовётся со старта приложения: компиляция из
/// исходника стоит десятки миллисекунд, и платить их в момент первого показа
/// плашки нельзя — это и есть «тормозит в самом начале».
@MainActor
public func prewarmDictationHUDWave() {
    DictationHUDWaveRenderer.prewarm()
}

// MARK: - Рисующий

@MainActor
final class DictationHUDWaveRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let storage: MTLStorageMode

    private var texture: MTLTexture?
    /// Буфер под выгрузку кадра. Переиспользуется: 2976 кадров раскадровки не
    /// должны стоить 2976 аллокаций по 200 КБ.
    private var pixels: [UInt8] = []
    private var pixelWidth = 0
    private var pixelHeight = 0

    private static var resolved = false
    private static var instance: DictationHUDWaveRenderer?

    /// Единственный экземпляр на процесс, или `nil` — на машине нет Metal
    /// (или шейдер не собрался). Вызывающий обязан уметь жить без GPU:
    /// у плашки остаётся путь Core Graphics.
    static func shared() -> DictationHUDWaveRenderer? {
        if !resolved {
            resolved = true
            instance = dictationHUDWaveDisabledByEnvironment()
                ? nil
                : DictationHUDWaveRenderer()
        }
        return instance
    }

    /// Прогрев: компиляция шейдера из исходника занимает десятки миллисекунд,
    /// и делать её в момент первого показа плашки — ровно та «заминка в самом
    /// начале», на которую жаловался владелец. Зовётся со старта приложения,
    /// задолго до первой записи.
    static func prewarm() {
        guard let renderer = shared() else { return }
        var scene = DictationHUDWaveScene(viewSize: DICTATION_HUD_BASE_SIZE,
                                          scale: 2,
                                          contentAlpha: 0,
                                          lightBackground: false)
        scene.strandParameters = dictationHUDRibbonStrandParameters()
        scene.strandColors = scene.strandParameters.map { _ in SIMD4<Float>(1, 1, 1, 1) }
        scene.waveMidY = DICTATION_HUD_BASE_SIZE.height / 2
        scene.halfHeight = 6
        scene.amplitude = 0.5
        _ = renderer.image(scene)
    }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        // Опции по умолчанию: быстрая математика в них и так включена, а
        // явный `mathMode` появился только в macOS 15 — наш минимум 14.
        guard let library = try? device.makeLibrary(source: DICTATION_HUD_WAVE_SHADER_SOURCE,
                                                    options: MTLCompileOptions()),
              let vertexFunction = library.makeFunction(name: "smltlkWaveVertex"),
              let fragmentFunction = library.makeFunction(name: "smltlkWaveFragment") else {
            log("HUD wave: шейдер не собрался, остаётся путь Core Graphics")
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            log("HUD wave: конвейер не собрался, остаётся путь Core Graphics")
            return nil
        }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        // На единой памяти текстуру читает процессор напрямую; на дискретной
        // видеокарте её сначала надо свести обратно блитом.
        self.storage = device.hasUnifiedMemory ? .shared : .managed
    }

    /// Кадр волны как CGImage поверх прозрачного фона, premultiplied BGRA.
    /// `nil` — кадр вырожден (нулевой размер) или GPU не отдал результат.
    func image(_ scene: DictationHUDWaveScene) -> CGImage? {
        let width = Int((scene.viewSize.width * scene.scale).rounded())
        let height = Int((scene.viewSize.height * scene.scale).rounded())
        guard width > 0, height > 0, width < 16384, height < 16384 else { return nil }
        guard let texture = ensureTexture(width: width, height: height) else { return nil }

        var uniforms = dictationHUDWaveUniforms(scene)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms,
                                 length: MemoryLayout<DictationHUDWaveUniforms>.stride,
                                 index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if storage == .managed, let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.error == nil else { return nil }

        let bytesPerRow = width * 4
        let info = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        // `makeImage` снимает с буфера копию, поэтому буфер переживает кадр
        // и переиспользуется следующим.
        return pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress else { return nil }
            texture.getBytes(base,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
            guard let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: info) else { return nil }
            return context.makeImage()
        }
    }

    private func ensureTexture(width: Int, height: Int) -> MTLTexture? {
        if let texture, pixelWidth == width, pixelHeight == height { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = storage
        guard let created = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture = created
        pixelWidth = width
        pixelHeight = height
        return created
    }
}
