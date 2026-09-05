// Волна уехала на GPU, и это создало новый класс поломок: контракт между
// Swift и MSL. Разъехавшаяся раскладка структуры не падает — она тихо рисует
// не то, и заметить это можно только глазами на раскадровке. Поэтому контракт
// держится тестами, а не аккуратностью.
//
// Сам шейдер здесь не запускается: под `swift test` GPU-контекста может не
// быть вовсе, и тест, который иногда есть, а иногда нет, хуже отсутствующего.
// Проверяется то, что от GPU не зависит: раскладка, сборка uniform-ов,
// выключатель аварийной ветки, свёртка фазы.
import CoreGraphics
import Foundation
import Testing

@testable import IrizDictate

@Suite("плашка: контракт волны с шейдером")
struct DictationHUDWaveShaderContractTests {
    /// Размеры типов MSL в байтах. Больше в структуре ничего не встречается,
    /// и встретиться не должно: `float3` там запрещён отдельно (см. ниже).
    private static let sizes: [String: Int] = ["float": 4, "float2": 8, "float4": 16]
    private static let alignments: [String: Int] = ["float": 4, "float2": 8, "float4": 16]

    /// Тело объявления `Uniforms` из исходника шейдера.
    private static func shaderStructureBody() -> String {
        let source = DICTATION_HUD_WAVE_SHADER_SOURCE
        guard let start = source.range(of: "struct Uniforms {"),
              let end = source.range(of: "};", range: start.upperBound..<source.endIndex) else {
            return ""
        }
        return String(source[start.upperBound..<end.lowerBound])
    }

    /// Поля `Uniforms` из исходника шейдера: имя и тип, в порядке объявления.
    private static func shaderFields() -> [(type: String, name: String)] {
        shaderStructureBody()
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ";", with: "")
                    .split(separator: " ")
                    .map(String.init)
                guard parts.count == 2, sizes[parts[0]] != nil else { return nil }
                return (type: parts[0], name: parts[1])
            }
    }

    /// Главный тест этого файла. Добавили поле в один список — краснеет, пока
    /// не добавили во второй, причём В ТО ЖЕ МЕСТО.
    @Test func раскладкаОдинаковаяВSwiftИВШейдере() {
        let shader = Self.shaderFields()
        #expect(shader.count > 30)

        let mirror = Mirror(reflecting: DictationHUDWaveUniforms())
        let swiftNames = mirror.children.compactMap(\.label)
        #expect(swiftNames == shader.map(\.name))

        // Смещения считаются по правилам C/MSL: поле встаёт на ближайшую
        // подходящую границу, структура добивается до своего выравнивания.
        var offset = 0
        var structureAlignment = 1
        for field in shader {
            let alignment = Self.alignments[field.type] ?? 4
            structureAlignment = max(structureAlignment, alignment)
            offset = ((offset + alignment - 1) / alignment) * alignment
            offset += Self.sizes[field.type] ?? 0
        }
        let stride = ((offset + structureAlignment - 1) / structureAlignment) * structureAlignment
        #expect(MemoryLayout<DictationHUDWaveUniforms>.size == offset)
        #expect(MemoryLayout<DictationHUDWaveUniforms>.stride == stride)
    }

    /// `float3` в MSL занимает 16 байт, а `SIMD3<Float>` в Swift — 12 с
    /// выравниванием 16. Один такой тип в структуре — и всё, что за ним, едет.
    @Test func вСтруктуреНетТиповСРазнымРазмеромВSwiftИВMSL() {
        let body = Self.shaderStructureBody()
        #expect(!body.isEmpty)
        #expect(!body.contains("float3"))
        // Заодно: разобрано ВСЁ объявление. Незнакомый тип молча выпал бы из
        // разбора, и проверка раскладки стала бы проверкой ни о чём.
        let declared = body.split(separator: ";").filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        #expect(declared.count == Self.shaderFields().count)
    }

    /// Кривая обязана быть той же, что под тестами модели: рисование не имеет
    /// права разойтись с моделью. Числа сверяются построчно, потому что
    /// компилятор здесь не помощник — это две разные программы.
    @Test func кривуюВШейдереПеренеслиБезРасхождений() {
        let source = DICTATION_HUD_WAVE_SHADER_SOURCE
        for fragment in ["1.62 + 0.26 * sin(u.phase * 0.29)",
                         "3.95 + 0.40 * sin(u.phase * 0.19 + 1.7)",
                         "0.74 * broad * (0.72 + 0.28 * sin(u.phase * 0.92))",
                         "0.24 * fine * (0.70 + 0.30 * sin(u.phase * 1.43 + 1.1))",
                         "sin(2.30 * SMLTLK_PI * cx - u.phase * 1.05",
                         "sin(3.75 * SMLTLK_PI * cx - u.phase * 0.61 + 0.8",
                         "0.76 * lead + 0.20 * trail"] {
            #expect(source.contains(fragment), "в шейдере нет куска кривой: \(fragment)")
        }
    }

    /// Хроматический разлёт — то самое число, из-за которого лента перестала
    /// быть цветной верёвкой. В Swift оно живёт константой, в MSL литералом,
    /// и здесь литерал СОБИРАЕТСЯ ИЗ КОНСТАНТЫ: поправят одну сторону — тест
    /// покраснеет, пока не поправят вторую.
    @Test func разлётНитейВШейдереТотЖе() {
        let source = DICTATION_HUD_WAVE_SHADER_SOURCE
        let standing = String(format: "strand * %.2f", DICTATION_HUD_RIBBON_ABERRATION)
        let travelling = String(format: "strand * %.2f", DICTATION_HUD_RIBBON_ABERRATION_FORWARD)
        // Стоячая волна: разлёт входит в обе моды.
        #expect(source.components(separatedBy: standing).count - 1 == 2,
                "в шейдере нет разлёта стоячей волны: \(standing)")
        #expect(source.components(separatedBy: travelling).count - 1 == 2,
                "в шейдере нет разлёта бегущей волны: \(travelling)")
        // Развода по вертикали не осталось: сложение к телу волны означало бы
        // возврат параллельных нитей.
        #expect(!source.contains("body + strand"))
        #expect(!source.contains("u.split"))
    }

    /// Основание дробной степени обязано быть неотрицательным. Косинус
    /// промахивается мимо −1 на единицу младшего разряда, дробная степень от
    /// минуса даёт NaN, а ноль умножить на NaN — снова NaN: маска «только
    /// снаружи канта» такой пиксель не спасает. На плашке это выглядело белой
    /// точкой посреди пилюли, и вернуться этому нельзя.
    @Test func дробнаяСтепеньНеБеретсяОтВозможногоМинуса() {
        #expect(DICTATION_HUD_WAVE_SHADER_SOURCE.contains("pow(max(wave, 0.0), u.haloFalloff)"))
        #expect(DICTATION_HUD_WAVE_SHADER_SOURCE.contains("any(isnan(col))"))
    }

    /// «В этой плашке мне не нужна сзади пузырек» (владелец, 11.08.2026).
    /// Пилюля жила в шейдере одной формулой SDF — она же маска ленты, она же
    /// начало ореола. Вернуться ей нельзя ни под каким именем: маска по канту
    /// это и есть пузырёк, даже если саму плиту не рисовать.
    @Test func пилюлиВШейдереНеОсталось() {
        let source = DICTATION_HUD_WAVE_SHADER_SOURCE
        for fragment in ["capsuleCenter", "capsuleHalf", "capsuleRadius", "plateInset",
                         "haloStart"] {
            #expect(!source.contains(fragment), "пилюля вернулась в шейдер: \(fragment)")
        }
        // Ореол-кольцо считался по углу вокруг центра пилюли. Гребень ауры
        // идёт вдоль ленты, и `atan2` для этого не нужен ни в каком виде.
        #expect(!source.contains("atan2"))
    }

    /// Кромка окна — жёсткий обрез. Пилюля гасила свечение своим кантом заранее;
    /// голая лента светит до самой кромки, и хвост срезался бы прямой линией —
    /// то есть на плашке появился бы прямоугольный контур, новый пузырёк.
    /// Поперечное затухание обязано давать РОВНО ноль на кромке.
    @Test func аураНеДоживаетДоКромкиОкна() {
        let source = DICTATION_HUD_WAVE_SHADER_SOURCE
        #expect(source.contains("float frame = 1.0 - ey4 * ey4;"))
        #expect(source.contains("* fade * frame * u.alpha;"))
        // Та же формула на числах: единица в середине, ноль на кромке,
        // и в полосе самой ленты она почти не работает.
        // Восьмая степень: лента выросла до 24 pt и подошла к кромке вплотную,
        // а четвертая срезала бы ее гребни на четверть яркости.
        let frame = { (ey: CGFloat) in 1 - pow(ey, 8) }
        #expect(abs(frame(0) - 1) < 0.0001)
        #expect(frame(1) == 0)
        let ribbonEdge = (DICTATION_HUD_RIBBON_PROCESSING_SPAN / 2)
            / (DICTATION_HUD_BASE_SIZE.height / 2)
        #expect(frame(ribbonEdge) > 0.9)
    }

    /// У MSL `smoothstep` с edge0 > edge1 результат не определён. Обратная
    /// граница обязана считаться как `1 - smoothstep`, а не перестановкой.
    @Test func smoothstepВсегдаСВозрастающимиГраницами() {
        for line in DICTATION_HUD_WAVE_SHADER_SOURCE.split(separator: "\n")
        where line.contains("smoothstep(high") {
            #expect(line.contains("1.0 - smoothstep(high - feather, high + feather"))
        }
    }
}

@Suite("плашка: сборка кадра волны")
struct DictationHUDWaveUniformsTests {
    private func scene(light: Bool = false) -> DictationHUDWaveScene {
        var scene = DictationHUDWaveScene(viewSize: DICTATION_HUD_BASE_SIZE,
                                          scale: 4,
                                          contentAlpha: 1,
                                          lightBackground: light)
        scene.waveMidY = DICTATION_HUD_BASE_SIZE.height / 2
        scene.halfHeight = DICTATION_HUD_RIBBON_LISTENING_SPAN / 2
        scene.amplitude = 0.7
        scene.strandParameters = dictationHUDRibbonStrandParameters()
        scene.strandColors = [SIMD4(1, 0, 0, 1), SIMD4(1, 0.4, 0, 1),
                              SIMD4(1, 0, 0.4, 1), SIMD4(1, 0.8, 0, 1)]
        return scene
    }

    @Test func нитиИИхВесаЕдутВШейдерТемиЖе() {
        let uniforms = dictationHUDWaveUniforms(scene())
        #expect(uniforms.strandCount == Float(DICTATION_HUD_RIBBON_STRANDS))
        for (index, parameter) in dictationHUDRibbonStrandParameters().enumerated() {
            #expect(uniforms.strandParameter[index] == Float(parameter))
            #expect(uniforms.strandWeight[index]
                    == Float(dictationHUDRibbonStrandWeight(parameter)))
        }
        // Ядро ярче крыльев — то же правило, что у пути Core Graphics.
        #expect(uniforms.strandWeight[1] > uniforms.strandWeight[0])
    }

    /// Нитей в структуре ровно четыре — по числу слотов в `float4`. Пятая молча
    /// потерялась бы, а лента стала бы другой: лучше отрезать её на сборке,
    /// чем удивляться картинке.
    @Test func пятаяНитьНеПролезает() {
        var wide = scene()
        wide.strandParameters = [-1, -0.5, 0, 0.5, 1]
        wide.strandColors = Array(repeating: SIMD4(1, 1, 1, 1), count: 5)
        #expect(dictationHUDWaveUniforms(wide).strandCount == 4)
    }

    /// Одна нить (прямая линия исхода) не должна тянуть за собой цвета
    /// несуществующих соседей.
    @Test func однаНитьРаздаётСвойЦветВсемЧетырёмСлотам() {
        var single = scene()
        single.strandParameters = [0]
        single.strandColors = [SIMD4(0, 1, 0, 1)]
        let uniforms = dictationHUDWaveUniforms(single)
        #expect(uniforms.strandCount == 1)
        #expect(uniforms.strandColor1 == uniforms.strandColor0)
        #expect(uniforms.strandColor2 == uniforms.strandColor0)
        #expect(uniforms.strandColor3 == uniforms.strandColor0)
    }

    /// На светлом фоне лента ложится краской, а не светом: там и гамма злее,
    /// и хвост режется раньше, иначе свечение читается грязью на белой плите.
    @Test func светлыйФонПолучаетСвоиЧисла() {
        let dark = dictationHUDWaveUniforms(scene(light: false))
        let light = dictationHUDWaveUniforms(scene(light: true))
        #expect(dark.lightBackground == 0)
        #expect(light.lightBackground == 1)
        #expect(light.gamma > dark.gamma)
        #expect(light.tail > dark.tail)
        #expect(light.bandAlpha < dark.bandAlpha)
    }

    @Test func мусорНаВходеНеРисуетНичегоБесконечного() {
        var broken = scene()
        broken.amplitude = .nan
        broken.contentAlpha = 9
        broken.scale = 0
        let uniforms = dictationHUDWaveUniforms(broken)
        #expect(uniforms.alpha == 1)
        #expect(uniforms.scale > 0)
        #expect(uniforms.waveWidth > 0)
        #expect(uniforms.amplitude == 0)
    }

    /// Ход волны — одна из четырёх осей различия режимов, и в шейдер он едет
    /// значением, а не подразумевается.
    @Test func ходВолныДоезжаетДоШейдера() {
        var forward = scene()
        forward.flow = .forward
        #expect(dictationHUDWaveUniforms(forward).flow == 1)
        #expect(dictationHUDWaveUniforms(scene()).flow == 0)
    }

    /// Модуляция гребнем уезжает в шейдер ДВУМЯ ЧИСЛАМИ, и собраны они из той
    /// же чистой функции, что под тестами модели. Разъедутся — промпт-лента
    /// поедет по общей яркости, и заметить это можно будет только глазами.
    @Test func гребеньВШейдереТотЖе() {
        let uniforms = dictationHUDWaveUniforms(scene())
        let mean = dictationHUDHaloRidgeMean()
        let gain = { (ridge: CGFloat) in
            CGFloat(uniforms.haloRidgeBase) + (ridge * CGFloat(uniforms.haloRidgeScale))
        }
        #expect(abs(gain(mean) - 1) < 0.0005)
        #expect(abs(gain(mean) - dictationHUDHaloRidgeGain(mean)) < 0.0005)
        #expect(abs(gain(1) - dictationHUDHaloRidgeGain(1)) < 0.0005)
        #expect(DICTATION_HUD_WAVE_SHADER_SOURCE
            .contains("ribbon *= u.haloRidgeBase + (ridge * u.haloRidgeScale);"))
    }

    /// Ширина ленты стала частью КАДРА: из неё растёт вход плашки. Ноль в этом
    /// месте — деление на ноль в шейдере.
    @Test func ширинаЛентыБерётсяИзКадраИНикогдаНеНоль() {
        var narrow = scene()
        narrow.waveWidth = 12
        #expect(dictationHUDWaveUniforms(narrow).waveWidth == 12)
        narrow.waveWidth = 0
        #expect(dictationHUDWaveUniforms(narrow).waveWidth > 0)
    }

    /// Фаза за сутки работы вырастает до сотен тысяч радиан. Float32 там уже
    /// теряет доли, поэтому её сворачивают до передачи.
    @Test func фазаСворачиваетсяПередОтправкой() {
        #expect(dictationHUDWavePhase(3.5) == 3.5)
        #expect(dictationHUDWavePhase(.nan) == 0)
        #expect(abs(dictationHUDWavePhase(1_000_000.25) - 0.25) < 0.01)
    }
}

@Suite("плашка: выключатель GPU")
struct DictationHUDWaveFallbackTests {
    /// Ветку «на машине нет Metal» иначе нечем проверить на машине, где Metal
    /// есть. Раскадровка с этой переменной рисуется прежним путём Core
    /// Graphics — и совпадает с ним кадр в кадр.
    @Test func переменнаяОкруженияВыключаетGPUТолькоКогдаЕёПросили() {
        #expect(!dictationHUDWaveDisabledByEnvironment([:]))
        #expect(!dictationHUDWaveDisabledByEnvironment([DICTATION_HUD_WAVE_DISABLE_KEY: ""]))
        #expect(!dictationHUDWaveDisabledByEnvironment([DICTATION_HUD_WAVE_DISABLE_KEY: "0"]))
        #expect(!dictationHUDWaveDisabledByEnvironment([DICTATION_HUD_WAVE_DISABLE_KEY: "false"]))
        #expect(dictationHUDWaveDisabledByEnvironment([DICTATION_HUD_WAVE_DISABLE_KEY: "1"]))
        #expect(dictationHUDWaveDisabledByEnvironment([DICTATION_HUD_WAVE_DISABLE_KEY: " yes "]))
    }
}
