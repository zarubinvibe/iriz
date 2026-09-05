// Исходник фрагментного шейдера волны. Отдельным файлом, потому что это чужой
// язык внутри нашего: держать полсотни строк MSL посреди Swift-класса —
// гарантированная каша при первой же правке.
//
// Компилируется в рантайме через `device.makeLibrary(source:)`. Причина
// прозаическая: SwiftPM в режиме `swift build` не компилирует `.metal`-файлы
// сам, а собирать `default.metallib` отдельным шагом значит завести у проекта
// второй способ сборки. Разовая цена компиляции снята прогревом
// (`DictationHUDWaveRenderer.prewarm`).
//
// Вся математика ниже — своя (см. шапку DictationHUDWaveShader.swift).
// `ribbonSample` — построчный перенос `dictationHUDRibbonSample` из
// DictationHUD.swift: кривая одна, и разойтись им нельзя.
let DICTATION_HUD_WAVE_SHADER_SOURCE = #"""
#include <metal_stdlib>
using namespace metal;

constant float SMLTLK_PI = 3.14159265358979323846;

struct Uniforms {
    float4 strandParameter;
    float4 strandWeight;
    float4 strandColor0;
    float4 strandColor1;
    float4 strandColor2;
    float4 strandColor3;
    float4 bandColor;
    float4 frontNear;
    float4 frontFar;
    float4 haloColor;

    float2 viewSize;

    float scale;
    float alpha;
    float waveStartX;
    float waveWidth;
    float waveMidY;
    float halfHeight;
    float amplitude;
    float phase;
    float flow;
    float bell;
    float thickness;
    float intensity;
    float bandAlpha;
    float bandFeather;
    float gamma;
    float edge;
    float strandCount;
    float lightBackground;
    float frontEnabled;
    float frontHead;
    float frontBand;
    float haloStrength;
    float haloSpread;
    float haloTraveling;
    float haloHead;
    float haloFloor;
    float haloFalloff;
    float haloRidgeBase;
    float haloRidgeScale;
    float tail;
    float hotStart;
    float hotGain;
    float slopeLimit;
};

struct VertexOut {
    float4 position [[position]];
};

// Один треугольник на весь кадр: вершинного буфера нет, геометрия считается
// из индекса. Дешевле полноэкранного квада и без шва по диагонали.
vertex VertexOut smltlkWaveVertex(uint id [[vertex_id]]) {
    float2 uv = float2(float((id << 1) & 2), float(id & 2));
    VertexOut out;
    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    return out;
}

// Колокол огибающей: 1 в центре, 0 на краях. Лента растворяется у торцов,
// а не обрывается о кант пилюли.
static inline float ribbonEnvelope(float x, float bell) {
    float c = cos(clamp(x, -1.0, 1.0) * SMLTLK_PI * 0.5);
    return pow(max(c, 0.0), bell);
}

// Отклонение нити от осевой линии в долях полувысоты. Слово в слово
// `dictationHUDRibbonSample`: симметричный ход — стоячая волна (выражение
// чётное по x), направленный — бегущая.
static inline float ribbonSample(constant Uniforms &u, float x, float strand) {
    float cx = clamp(x, -1.0, 1.0);
    float envelope = ribbonEnvelope(cx, u.bell);
    float body;
    if (u.flow < 0.5) {
        float broad = cos((1.62 + 0.26 * sin(u.phase * 0.29)) * SMLTLK_PI * cx
                          + strand * 1.95);
        float fine = cos((3.95 + 0.40 * sin(u.phase * 0.19 + 1.7)) * SMLTLK_PI * cx
                         + strand * 1.95);
        body = 0.74 * broad * (0.72 + 0.28 * sin(u.phase * 0.92))
             + 0.24 * fine * (0.70 + 0.30 * sin(u.phase * 1.43 + 1.1));
    } else {
        float lead = sin(2.30 * SMLTLK_PI * cx - u.phase * 1.05 + strand * 1.25);
        float trail = sin(3.75 * SMLTLK_PI * cx - u.phase * 0.61 + 0.8 + strand * 1.25);
        body = 0.76 * lead + 0.20 * trail;
    }
    return envelope * u.amplitude * body;
}

static inline float3 strandTint(constant Uniforms &u, int index, float t) {
    // Фронт перекраски на распознавании: слева уже цвет работы, справа ещё
    // цвет режима, в котором говорили. Он важнее хроматики нитей и её заменяет.
    if (u.frontEnabled > 0.5) {
        float mixed = smoothstep(u.frontHead - u.frontBand * 0.5,
                                 u.frontHead + u.frontBand * 0.5,
                                 t);
        return mix(u.frontNear.rgb, u.frontFar.rgb, mixed);
    }
    if (index == 0) { return u.strandColor0.rgb; }
    if (index == 1) { return u.strandColor1.rgb; }
    if (index == 2) { return u.strandColor2.rgb; }
    return u.strandColor3.rgb;
}

fragment float4 smltlkWaveFragment(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]]) {
    float2 p = in.position.xy / u.scale;

    // Пилюли за лентой нет, поэтому нет и маски по её канту: лента гасится
    // только своей огибающей и краевыми затуханиями — вдоль (`fade`) и
    // поперёк (`frame`). Подложки под ней тоже нет, и это решение по кадрам,
    // а не забывчивость: см. DictationHUD.swift, «О ПОДЛОЖКЕ ПОД ЛЕНТОЙ».
    float3 ribbon = float3(0.0);
    int count = int(u.strandCount + 0.5);

    if (count > 0) {
        float t = (p.x - u.waveStartX) / u.waveWidth;
        float xn = t * 2.0 - 1.0;
        float dxn = 2.0 / u.waveWidth;
        // Гауссово затухание по длине. Гасит не размах, а саму ВИДИМОСТЬ,
        // поэтому у ленты нет торцов ни у линий, ни у заливки.
        float ex = min(fabs(xn) * u.edge, 3.0);
        float ex3 = ex * ex * ex;
        float fade = exp(-ex3 * ex3);

        // Границы ленты — по ВСЕМ нитям, а не по первой и последней. При
        // разводе по фазе крайние нити пересекаются, и в точке пересечения
        // «между первой и последней» пусто, хотя лента там во всю высоту.
        float low = u.waveMidY;
        float high = u.waveMidY;
        for (int index = 0; index < count; index++) {
            float strand = u.strandParameter[index];
            float y = u.waveMidY + ribbonSample(u, xn, strand) * u.halfHeight;
            if (index == 0) { low = y; high = y; }
            low = min(low, y);
            high = max(high, y);
            // Наклон кривой: без него крутые участки читались бы толще
            // пологих, потому что вертикальный зазор там больше настоящего
            // расстояния до линии.
            float back = u.waveMidY + ribbonSample(u, xn - dxn, strand) * u.halfHeight;
            float forward = u.waveMidY + ribbonSample(u, xn + dxn, strand) * u.halfHeight;
            float slope = clamp((forward - back) * 0.5, -u.slopeLimit, u.slopeLimit);
            float distance = fabs(p.y - y) * rsqrt(1.0 + slope * slope);
            // Лоренцев спад: мягкое ядро с длинным хвостом. Обводкой такого
            // не получить — ради этой строки всё и уехало на GPU.
            //
            // Квадратичная добавка в знаменателе — не украшение: чистый 1/d
            // на пилюле 34 pt высотой затягивает дымкой ВСЮ плиту, и особенно
            // видно это на светлом фоне, где дымка читается грязью. Возле ядра
            // она ничего не меняет, далеко — рубит хвост.
            float reach = distance / u.thickness;
            float glow = u.intensity * u.strandWeight[index]
                / (1.0 + reach + u.tail * reach * reach);
            float3 tint = strandTint(u, index, t);
            // Пережог ядра. Свет такой яркости глаз видит белым, и без этого
            // лента остаётся цветной верёвкой вместо ленты света. На светлом
            // фоне выключено: там белое ядро — это дырка.
            if (u.lightBackground < 0.5) {
                float hot = clamp((glow - u.hotStart) * u.hotGain, 0.0, 1.0);
                tint = mix(tint, float3(1.0), hot);
            }
            ribbon += tint * glow;
        }

        float band = 0.0;
        if (count > 1) {
            // Обе границы считаются возрастающим smoothstep: у MSL при
            // edge0 > edge1 результат не определён, и на отдельных пикселях
            // оттуда приходит мусор.
            float feather = u.bandFeather;
            band = smoothstep(low - feather, low + feather, p.y)
                * (1.0 - smoothstep(high - feather, high + feather, p.y));
            // Заливка перекрашивается фронтом ВМЕСТЕ с нитями. Иначе она
            // остаётся своего цвета поверх уже перекрашенной ленты, и на
            // распознавании вся середина заливается белым — фронт есть,
            // а видно его только по кромкам.
            float3 bandTint = u.frontEnabled > 0.5 ? strandTint(u, 0, t) : u.bandColor.rgb;
            ribbon += bandTint * u.bandAlpha * band;
        }

        // Аура — бывший ореол по канту пилюли. Канта нет, и кольцо вокруг
        // ничего рисовать больше нельзя: кольцо и есть контур пузырька.
        // Свечение переехало на саму ленту: экспоненциальный спад от её
        // границы наружу. Ось «ровно / бежит» цела — у промпта по ленте
        // течёт гребень, только теперь вдоль неё, а не вокруг пилюли.
        //
        // СНАРУЖИ, а не поверх: `(1 - band)` держит ауру вне ленты. Без этого
        // она ложилась ещё и на заливку, складывалась с ней и с пережогом
        // ядра — и промпт-лента выгорала в белую, теряя фиолетовый, то есть
        // цветовую ось различия режимов. Ореол по канту такой ошибки допустить
        // не мог: он физически жил снаружи пилюли.
        if (u.haloStrength > 0.0005) {
            float ridge = 1.0;
            if (u.haloTraveling > 0.5) {
                // max(..., 0) обязателен: в противофазе косинус промахивается
                // мимо −1 на единицу младшего разряда, основание уходит
                // в минус, и дробная степень отдаёт NaN. Ноль умножить на NaN —
                // тоже NaN, поэтому никакая маска такой пиксель не спасает:
                // на плашке это выглядело белой точкой.
                float wave = (cos((t - u.haloHead) * 2.0 * SMLTLK_PI) + 1.0) * 0.5;
                float crest = pow(max(wave, 0.0), u.haloFalloff);
                ridge = u.haloFloor + (1.0 - u.haloFloor) * crest;
            }
            float outside = max(max(low - p.y, p.y - high), 0.0);
            float aura = exp(-outside / u.haloSpread) * (1.0 - band);
            ribbon += u.haloColor.rgb * aura * ridge * u.haloStrength;
            if (u.haloTraveling > 0.5) {
                // Гребень ведёт не только юбку свечения, но и САМУ ленту:
                // в юбке он тонет — там уже горит лоренцев хвост нитей, и
                // четверти его яркости глаз не видит. Проверено кадрами
                // `motion-*-prompt-halo-*`: без этой строки бегущая аура
                // на них не отличалась от ровной, то есть четвёртая ось
                // различия режимов была жива в модели и мертва на экране.
                //
                // Множитель ходит ВОКРУГ ЕДИНИЦЫ: `base` и `scale` собраны
                // из средней яркости гребня, поэтому средняя яркость ленты
                // не меняется. Иначе промпт поехал бы по общей яркости
                // вслед за формой гребня, а яркость здесь занята голосом.
                ribbon *= u.haloRidgeBase + (ridge * u.haloRidgeScale);
            }
        }
        // Край панели — жёсткий обрез: за ним рисовать некуда. Пока за лентой
        // стояла пилюля, её кант гасил всё заранее; голая лента светит до самой
        // кромки окна, и хвост свечения там срезался бы прямой линией. Поэтому
        // поперёк окна лежит своё затухание: единица в середине (ленту оно
        // не трогает — она живёт внутри половины высоты) и РОВНО ноль на
        // кромке. Не «мало», а ноль: «мало» рано или поздно станет видно.
        float ey = clamp((p.y - u.viewSize.y * 0.5) / max(u.viewSize.y * 0.5, 0.0001),
                         -1.0, 1.0);
        float ey2 = ey * ey;
        float ey4 = ey2 * ey2;
        // Восьмая степень, а не четвёртая: лента выросла с 15,18 до 24 pt и
        // подошла к кромке вплотную. Четвёртая срезала бы её гребни на четверть
        // яркости - то есть чинила бы одно и ломала другое. Ровный ноль на самой
        // кромке при этом никуда не делся, он и есть смысл этой строки.
        float frame = 1.0 - ey4 * ey4;
        ribbon = pow(max(ribbon, 0.0), float3(u.gamma)) * fade * frame * u.alpha;
    }

    float3 col = ribbon;
    // Страховка от NaN. Один такой пиксель уже стоил белой точки на плашке;
    // прозрачный кадр — честный отказ, светящийся мусор — нет.
    if (any(isnan(col))) { return float4(0.0); }
    float peak = max(max(col.r, col.g), col.b);
    if (peak < 0.0005) { return float4(0.0); }

    // Наружу кадр уходит ПОКРЫТИЕМ, а не светом: яркость становится альфой,
    // и лента ложится поверх чужого окна обычным source-over. Плиты за ней
    // нет, складывать её не с чем — и складывать не надо: именно поэтому она
    // читается и на белом документе, и на чёрном терминале без подложки.
    float coverage = clamp(peak, 0.0, 1.0);
    float3 rgb = u.lightBackground > 0.5
        // На светлом фоне сложение света выжгло бы всё в белое. Тот же цвет
        // ложится краской: покрытие берётся из яркости, тон — из её состава.
        ? (col / peak) * coverage
        // На тёмном — ровно сложение света.
        : min(col, float3(1.0));
    return float4(rgb, coverage);
}
"""#
