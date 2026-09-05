// Рендер знака smltlk для визуальной приёмки и машинного теста размытием.
// Компилируется scripts/render_marks.sh вместе с Sources/IrizApp/IrizMark.swift —
// геометрия живёт только в пакете, здесь лишь вывод в файлы и пиксельные проверки.
//
// argv: render-marks <renderDir> <iconsetDir> <proofDir>
import AppKit

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: render-marks <renderDir> <iconsetDir> <proofDir>\n".data(using: .utf8)!)
    exit(2)
}
let renderDir = args[1]
let iconsetDir = args[2]
let proofDir = args[3]
let fm = FileManager.default
try! fm.createDirectory(atPath: renderDir, withIntermediateDirectories: true)
try! fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
try! fm.createDirectory(atPath: proofDir, withIntermediateDirectories: true)

// MARK: - Холст

/// RGBA-контекст с осью Y вниз (как flipped NSImage), 1 пункт = scale пикселей.
func makeContext(width: Int, height: Int, scale: CGFloat) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: scale, y: -scale)
    return ctx
}

/// Знак на холсте 18×18 pt; whiteBackground — для просмотровых PNG (маску на
/// прозрачности глаз не читает), прозрачный фон — для анализа альфы.
func renderMark(state: MarkState, phase: CGFloat = 0, scale: CGFloat, whiteBackground: Bool) -> CGImage {
    let px = Int((IrizMark.canvasPoints * scale).rounded())
    let ctx = makeContext(width: px, height: px, scale: scale)
    if whiteBackground {
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: IrizMark.canvasPoints, height: IrizMark.canvasPoints))
    }
    IrizMark.draw(state: state, phase: phase,
                    in: CGRect(x: 0, y: 0, width: IrizMark.canvasPoints, height: IrizMark.canvasPoints),
                    context: ctx)
    return ctx.makeImage()!
}

func savePNG(_ image: CGImage, name: String, dir: String) {
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    print("wrote \(dir)/\(name) (\(image.width)x\(image.height))")
}

// MARK: - Просмотровые PNG: все состояния знака (VISUAL_SPEC §4)

let states: [(name: String, state: MarkState)] = [
    ("mark-fixing", MarkState(mode: .fixing, alarm: .none)),
    ("mark-shadow", MarkState(mode: .shadow, alarm: .none)),
    ("mark-paused", MarkState(mode: .paused, alarm: .none)),
    ("mark-dictating", MarkState(mode: .dictating, alarm: .none)),
    ("mark-alarm-no-permission", MarkState(mode: .fixing, alarm: .noPermission)),
]
/// Состояние по ИМЕНИ, а не по индексу. Индексы уже подвели: из списка убрали
/// одно состояние, и проверки поехали на соседние, а прибор упал выходом за
/// границу вместо внятного отказа.
func markState(_ name: String) -> MarkState {
    guard let found = states.first(where: { $0.name == name })?.state else {
        FileHandle.standardError.write("нет состояния «\(name)»\n".data(using: .utf8)!)
        exit(2)
    }
    return found
}

for (name, state) in states {
    savePNG(renderMark(state: state, scale: 8, whiteBackground: true), name: "\(name).png", dir: renderDir)
    savePNG(renderMark(state: state, scale: 2, whiteBackground: true), name: "\(name)-real-size.png", dir: renderDir)
}

// MARK: - Тест размытием (§2.8, §3.2): знак обязан читаться на реальном
// размере строки меню, а заливка — не двоиться на пересечениях фигур.

var failures: [String] = []

/// Альфа-канал произвольного CGImage как матрица байт (перерисовываем в свой
/// контекст, чтобы не зависеть от раскладки памяти исходника; interpolation
/// выключена — пиксели копируются один в один, без подмешивания).
func alphaMatrix(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) {
    let ctx = makeContext(width: image.width, height: image.height, scale: 1)
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bpr = ctx.bytesPerRow
    let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: bpr * image.height)
    return (Array(UnsafeBufferPointer(start: ptr, count: bpr * image.height)), image.width, image.height, bpr)
}

func alpha(_ m: (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int), x: Int, y: Int) -> Double {
    Double(m.bytes[y * m.bytesPerRow + x * 4 + 3]) / 255
}

// Диапазоны строк по умолчанию — сердцевина знака (y 40…140 единиц сетки из
// 180): торцы каретки и буквы закономерно покрывают крайние строки частично,
// поэтому полный столбец — не честная выборка для среднего.
func bandMean(_ m: (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int), columns: ClosedRange<Int>,
              rows: ClosedRange<Int>? = nil) -> Double {
    let ys = rows ?? (0...(m.height - 1))
    var sum = 0.0
    var n = 0
    for y in ys {
        for x in columns {
            sum += alpha(m, x: x, y: y)
            n += 1
        }
    }
    return sum / Double(n)
}

func bandMax(_ m: (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int), rows: ClosedRange<Int>) -> Double {
    var result = 0.0
    for y in rows where y >= 0 && y < m.height {
        for x in 0..<m.width { result = max(result, alpha(m, x: x, y: y)) }
    }
    return result
}

func bandMax(_ m: (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int), columns: ClosedRange<Int>) -> Double {
    var result = 0.0
    for y in 0..<m.height {
        for x in columns { result = max(result, alpha(m, x: x, y: y)) }
    }
    return result
}

// 1. Волна занимает холст по ширине: знак не должен жаться в угол.
let fixing1x = alphaMatrix(renderMark(state: markState("mark-fixing"), scale: 1, whiteBackground: false))
// Меряем РАЗМАХ чернил, а не их количество: между столбиками законно пусто,
// и счёт залитых колонок наказывал бы волну за то, что она волна.
var firstInk = -1, lastInk = -1
for x in 0..<fixing1x.width {
    for y in 0..<fixing1x.height where alpha(fixing1x, x: x, y: y) > 0.5 {
        if firstInk < 0 { firstInk = x }
        lastInk = x
        break
    }
}
let inkColumns = lastInk - firstInk + 1
if inkColumns < 13 {
    failures.append("wave too narrow at @1x (span \(inkColumns) of 18)")
}

// 2. Размытие 18→9→18: столбики остаются РАЗДЕЛЬНЫМИ. Если промежутки между
// ними заплывают, волна становится сплошной полосой и перестаёт быть волной.
// Считаем столбики на честном @1x, а не на пережатом вдвое кадре: при
// даунсэмпле 18→9 пять столбиков физически не помещаются в девять пикселей и
// слипаются у ЛЮБОЙ волны - такой замер наказывал бы за законную геометрию.
savePNG(renderMark(state: markState("mark-fixing"), scale: 1, whiteBackground: false),
        name: "blur-test-mark.png", dir: renderDir)
let blurred = fixing1x
var rowPeaks = 0
var previous = 0.0
var rising = false
for x in 0..<blurred.width {
    let value = bandMax(blurred, columns: x...x)
    if value > previous + 0.05 { rising = true }
    if rising, value < previous - 0.05 { rowPeaks += 1; rising = false }
    previous = value
}
if rowPeaks < 4 {
    failures.append("blurred wave merged into a bar (peaks \(rowPeaks))")
}

// 3. Заливка не двоится: в режиме «пауза» обе зоны рисуются альфой 0.4;
// если бы фигуры заливались дважды на пересечении, там было бы ~0.64.
let paused4x = alphaMatrix(renderMark(state: markState("mark-paused"), scale: 4, whiteBackground: false))
var maxAlpha = 0.0
for y in 0..<paused4x.height {
    for x in 0..<paused4x.width { maxAlpha = max(maxAlpha, alpha(paused4x, x: x, y: y)) }
}
if maxAlpha > 0.55 { failures.append("double fill on overlap (max alpha \(maxAlpha), expected ~0.4)") }

// 4. Авария «нет разрешений»: волна ложится в ОДНУ ровную линию.
let alarm8x = alphaMatrix(renderMark(state: markState("mark-alarm-no-permission"), scale: 8, whiteBackground: false))
let unit = 0.18 * 8
func inkHeight(_ m: (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int), gridX: Double) -> Double {
    let x = Int(gridX * unit)
    guard x >= 0, x < m.width else { return 0 }
    var top = -1, bottom = -1
    for y in 0..<m.height where alpha(m, x: x, y: y) > 0.5 {
        if top < 0 { top = y }
        bottom = y
    }
    return top < 0 ? 0 : Double(bottom - top + 1) / unit
}
// Нутро линии, а не кончики: торцы скруглены, и в крайней точке колпачка
// высота законно меньше.
let alarmHeights = [22.0, 36.0, 50.0, 64.0, 78.0].map { inkHeight(alarm8x, gridX: $0) }
let alarmSpread = (alarmHeights.max() ?? 0) - (alarmHeights.min() ?? 0)
if alarmHeights.contains(where: { $0 < 5 }) { failures.append("alarm line broken: \(alarmHeights)") }
if alarmSpread > 2 { failures.append("alarm wave is not flat (spread \(alarmSpread))") }

// 5. Живая волна НЕ плоская: середина выше краёв, и ни один столбик не пропал.
let normal8x = alphaMatrix(renderMark(state: markState("mark-fixing"), scale: 8, whiteBackground: false))
let normalHeights = [17.5, 33.75, 50.0, 66.25, 82.5].map { inkHeight(normal8x, gridX: $0) }
if normalHeights.contains(where: { $0 < 10 }) { failures.append("wave bar missing: \(normalHeights)") }
if normalHeights[2] <= normalHeights[0] + 3 {
    failures.append("wave envelope flat in normal state: \(normalHeights)")
}

// 6. На записи появляется точка записи - и только на записи. Она и есть тот
// «дублирующий значок того, что идёт запись», о котором просил владелец.
let dict8x = alphaMatrix(renderMark(state: markState("mark-dictating"), scale: 8, whiteBackground: false))
let dot = inkHeight(dict8x, gridX: 8.0)
let dotIdle = inkHeight(normal8x, gridX: 8.0)
if dot < 8 { failures.append("recording dot missing while dictating (\(dot))") }
if dotIdle > 4 { failures.append("recording dot shown while idle (\(dotIdle))") }

if failures.isEmpty {
    print("MARK-TEST PASS: columns=\(inkColumns) peaks=\(rowPeaks) pausedMax=\(maxAlpha) alarmFlat=\(alarmSpread) envelope=\(normalHeights) dot=\(dot)")
} else {
    for failure in failures { FileHandle.standardError.write("BLUR-TEST FAIL: \(failure)\n".data(using: .utf8)!) }
    exit(1)
}

// MARK: - Пруфы (.build/proof/): все состояния в 16pt и 64pt + фазы волны.

/// Контекст-компоновщик БЕЗ переворота оси Y: CGImage, нарисованный во
/// flipped-контекст, ложится в память вверх ногами, поэтому upscale и склейку
/// полосы ведём в обычном контексте (в makeContext — только отрисовка путей).
func makePlainContext(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height,
              bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Увеличение строго nearest-neighbour: пиксели строки меню видны честно,
/// без подмешивания интерполяцией.
func upscaleNearest(_ image: CGImage, factor: Int) -> CGImage {
    let ctx = makePlainContext(width: image.width * factor, height: image.height * factor)
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width * factor, height: image.height * factor))
    return ctx.makeImage()!
}

// Состояние диктовки в 16pt и 64pt вместе с остальными состояниями.
// 64pt — это ×4 nearest-neighbour увеличение честного 16pt-рендера.
let mark16ptScale = 16.0 / IrizMark.canvasPoints
for (name, state) in states {
    let small = renderMark(state: state, scale: mark16ptScale, whiteBackground: true)
    savePNG(small, name: "\(name)-16pt.png", dir: proofDir)
    savePNG(upscaleNearest(small, factor: 4), name: "\(name)-64pt.png", dir: proofDir)
}

// wave-phases.png: четыре фазы единственной анимации продукта в ряд (§4) —
// 0, π/2, π, 3π/2. Каждая фаза — честный 16pt-рендер, увеличенный ×4;
// фазы обязаны различаться, иначе полоса доказывает обратное.
let phaseFramePx = 64
let strip = makePlainContext(width: phaseFramePx * 4, height: phaseFramePx)
strip.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
strip.fill(CGRect(x: 0, y: 0, width: phaseFramePx * 4, height: phaseFramePx))
strip.interpolationQuality = .none
for (i, phase) in [CGFloat(0), .pi / 2, .pi, 3 * .pi / 2].enumerated() {
    let frame = upscaleNearest(renderMark(state: markState("mark-dictating"), phase: phase,
                                          scale: mark16ptScale, whiteBackground: true),
                               factor: 4)
    strip.draw(frame, in: CGRect(x: phaseFramePx * i, y: 0, width: phaseFramePx, height: phaseFramePx))
}
savePNG(strip.makeImage()!, name: "wave-phases.png", dir: proofDir)

// MARK: - Иконка приложения (§5): iconset → iconutil → .build/AppIcon.icns

let iconSizes: [(pixels: Int, name: String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (pixels, name) in iconSizes {
    var rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    let cg = IrizMark.iconImage(pixels: pixels).cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    savePNG(cg, name: name, dir: iconsetDir)
}
var bigRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
savePNG(IrizMark.iconImage(pixels: 1024).cgImage(forProposedRect: &bigRect, context: nil, hints: nil)!,
        name: "icon-1024.png", dir: renderDir)
// Просмотровые рендеры иконки на ключевых размерах — для визуальной приёмки
// тем же вызовом iconImage, что и .icns (§5).
for pixels in [16, 32, 128] {
    var rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    savePNG(IrizMark.iconImage(pixels: pixels).cgImage(forProposedRect: &rect, context: nil, hints: nil)!,
            name: "icon-\(pixels).png", dir: renderDir)
}
