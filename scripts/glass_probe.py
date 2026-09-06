#!/usr/bin/env python3
"""Прибор для стекла: числом, а не на глаз.

Четыре круга подряд стекло судили кадром над тёмным терминалом. На такой сцене
матовую краску от стекла отличить нельзя в принципе, и все четыре раза проверка
подтверждала то, чего в окне не было. Прибор обязан дефект ПРОВАЛИВАТЬ.

Как меряется.

Окно снимается трижды с одним и тем же содержимым: над чёрной подложкой, над
белой и над вертикальными полосами. Содержимое во всех трёх кадрах одинаково,
поэтому разность кадров вычитает наш интерфейс целиком и оставляет только то,
что пришло из-за окна.

    ПРОПУСКАНИЕ  = среднее(белый - чёрный) / 255
        Размытие среднюю яркость не меняет, поэтому число верно при любом
        радиусе. Краска даёт около нуля, чистая дыра около единицы.

    МЯГКОСТЬ     = доля столбцов, попавших в середину между тёмной и светлой
                   полосой
        Первая версия мерила размах полос и провалилась на собственной
        самопроверке: полоса шириной 120 pt переживает размытие радиусом в
        десятки точек почти целиком, и заведомо исправное стекло прибор назвал
        дырой. Размах отвечает не на тот вопрос. Отвечает КРОМКА: у резкой
        границы почти нет промежуточных значений, у размытой их много.
        Дыра даёт около нуля, размытие - десятки процентов.

Стекло - это ВЫСОКОЕ пропускание при ЗАМЕТНОЙ мягкости. Одного числа мало:
краска и дыра различаются только парой.

Запуск:
    python3 scripts/glass_probe.py --shots .build/glass-probe
    python3 scripts/glass_probe.py --selftest
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# Пороги приёмки. Держатся здесь, а не в голове: спор о том, стекло это или
# нет, решается сравнением с числом.
# Пороги ОТНОСИТЕЛЬНЫЕ, от потолка самой системы. Абсолютное число я задал
# первым и оно оказалось выдумкой: 0.30 при физическом потолке стекла 0.294,
# то есть окно не могло пройти ворота ни при какой работе. Потолок меряется
# тем же прибором на пустом окне с одним стеклом внутри.
MIN_TRANSMISSION_OF_CEILING = 0.85
MIN_SOFTNESS_OF_CEILING = 0.60
# Запасные абсолютные пороги: кадров голого стекла может не быть.
MIN_TRANSMISSION = 0.20
MIN_SOFTNESS = 0.05

# Полосы известной ширины в точках; на retina-кадре шаг вдвое больше.
STRIPE_WIDTH_PT = 120


def luminance(path: Path) -> np.ndarray:
    """Кадр в яркость 0..255, float."""
    img = Image.open(path).convert("RGB")
    a = np.asarray(img, dtype=np.float64)
    return 0.2126 * a[:, :, 0] + 0.7152 * a[:, :, 1] + 0.0722 * a[:, :, 2]


def regions(h: int, w: int) -> dict[str, tuple[slice, slice]]:
    """Полосы окна по долям, а не по точкам: кадр бывает 1x и 2x."""
    return {
        "боковик": (slice(int(0.18 * h), int(0.80 * h)), slice(int(0.02 * w), int(0.18 * w))),
        "страница": (slice(int(0.60 * h), int(0.85 * h)), slice(int(0.30 * w), int(0.95 * w))),
        "низ": (slice(int(0.93 * h), int(0.99 * h)), slice(int(0.05 * w), int(0.95 * w))),
        "всё окно": (slice(int(0.05 * h), int(0.98 * h)), slice(int(0.02 * w), int(0.98 * w))),
    }


def measure(black: np.ndarray, white: np.ndarray, stripes: np.ndarray) -> dict:
    """Пропускание и удержание по каждой области окна."""
    if not (black.shape == white.shape == stripes.shape):
        raise ValueError(f"кадры разного размера: {black.shape}, {white.shape}, {stripes.shape}")

    d_trans = white - black       # вклад подложки, интерфейс вычтен
    d_stripe = stripes - black    # вклад одних полос
    h, w = black.shape
    out = {}

    for name, (ys, xs) in regions(h, w).items():
        transmission = float(d_trans[ys, xs].mean()) / 255.0
        # Профиль полос по средним столбцов: горизонталь - единственная
        # координата, вдоль которой подложка меняется.
        columns = d_stripe[ys, xs].mean(axis=0)
        span = float(columns.max() - columns.min())
        if span < 1.0:
            # Полос не видно вовсе - мягкость не определена, и выдумывать её
            # нельзя: приговор в этом случае выносит пропускание.
            softness = 0.0
        else:
            low = columns.min() + 0.25 * span
            high = columns.min() + 0.75 * span
            softness = float(((columns > low) & (columns < high)).mean())
        out[name] = {
            "пропускание": round(transmission, 4),
            "размах_полос": round(span, 2),
            "мягкость": round(softness, 4),
        }
    return out


# Область приговора. НЕ «всё окно», и это принципиально: с плавающими плитами
# окно наполовину состоит из поверхностей, которые ОБЯЗАНЫ быть плотными - на
# них лежит текст. Судить по ним значит требовать нечитаемого интерфейса.
# Ворота судят подложку окна там, где она открыта: ниже плиты содержимого.
VERDICT_REGION = "страница"

# ЗАКРЕПЛЁННЫЙ ВИД. Числа сняты с окна, которое владелец принял словами
# «заебись, сохраняй, чтобы в следующие разы было ровно так же».
#
# Держатся числами, а не описанием, потому что описание следующий круг прочтёт
# и всё равно сделает иначе - это свойство исполнителя, а не злой умысел.
# Полосы широкие: они ловят подмену рецепта (стекло стало краской, плита
# сравнялась с фоном), а не дрожание замера в третьем знаке.
LOCKED = {
    # Фон окна: прозрачное стекло с преломлением. Снято 0.678.
    "фон_пропускание_мин": 0.55,
    # Плиты: МАТОВОЕ стекло плюс заливка под ним. Снято 0.121 боковик, 0.105 низ.
    #
    # Числа обновлены 05.09.2026 по решению владельца: «нужно сделать ещё в два
    # раза менее светопроницаемо плашки, они вообще не читаемы на белом фоне;
    # основной фон идеально сделан». Прежняя полоса (0.28..0.58) сегодняшний вид
    # завернула бы, и это правильно: ворота обязаны краснеть на изменении вида.
    # Меняются они ВМЕСТЕ с решением владельца и только с ним.
    # Числа обновлены 06.09.2026 по второму решению владельца: «ещё в два раза
    # менее светопроницаемо и матовым стеклом, они вообще не читаемы на белом
    # фоне». Плита сменила вариант стекла с `.clear` на `.regular`: он правит
    # светимость подложки ради читаемости, и это ровно та работа, которая под
    # текстом нужна. Фон окна остался прозрачным - он текста не несёт.
    "плита_пропускание_мин": 0.06,
    "плита_пропускание_макс": 0.20,
    # Плита ОБЯЗАНА отличаться от фона, иначе поверхности сливаются и язык окна
    # пропадает. Снято 0.56.
    "разница_фон_плита_мин": 0.35,
    # Преломление живо в каждой области. Снято 0.23 и выше.
    "мягкость_мин": 0.12,
}

# ПЛАШКА. Правило владельца 06.09.2026, дословно: «всё стекло, которое просто
# без текста или без каких-то выделений снизу, должно быть максимально
# прозрачным, как это уже сделано в настройках… в том числе это стекло у самой
# плашки».
#
# Эталон класса «прозрачное» - фон окна настроек: `glassEffect(.clear)`,
# снято 0.678 при пороге 0.55, то есть порог держится на 0.81 от снятого.
# Плашка мерится тем же прибором и судится тем же классом; своё число у неё
# потому, что стекло у неё МАЛЕНЬКОЕ, и доля кромки в кадре больше, чем у окна.
# Замер 06.09.2026 прибором `iriz --probe-plate`, светлый вид:
#
#            было (.regular)   стало (.clear)   эталон окна
#   покой         0.244            0.722           0.678
#   запись        0.112            0.605             --
#   мягкость      0.20 / 0.15      0.57 / 0.37       0.25
#
# Порог берётся от МЕНЬШЕГО из снятых (запись, 0.605) той же долей, что у окна:
# 0.55 / 0.678 = 0.81, значит 0.605 * 0.81 = 0.49, округлено вниз до 0.48.
# Прежнее матовое стекло (0.244 и 0.112) этот порог не проходит - ворота
# краснеют на возврате, а не соглашаются с ним молча.
PLATE_LOCKED = {
    "пропускание_мин": 0.48,
    "мягкость_мин": 0.12,
}
# Доля центра плашки, по которой судят: кромка стекла и ореол в замер не идут.
PLATE_CORE = 0.62


def verdict(measurements: dict, ceiling: dict | None = None) -> tuple[bool, list[str]]:
    """Приговор по подложке окна. Остальные области - для разбора."""
    whole = measurements[VERDICT_REGION]
    t, soft = whole["пропускание"], whole["мягкость"]
    problems = []

    if ceiling:
        # Окно сравнивается с ГОЛЫМ стеклом того же размера в той же системе.
        # Своё содержимое неизбежно съедает часть пропускания, и требовать от
        # окна больше, чем даёт пустое стекло, значит требовать невозможного.
        ct, cs = ceiling["пропускание"], ceiling["мягкость"]
        need_t, need_s = ct * MIN_TRANSMISSION_OF_CEILING, cs * MIN_SOFTNESS_OF_CEILING
        if t < need_t:
            problems.append(
                f"окно пропускает {t:.3f} при потолке стекла {ct:.3f} - это "
                f"{t / max(ct, 1e-6):.0%} вместо {MIN_TRANSMISSION_OF_CEILING:.0%}. "
                "Интерфейс закрывает окно сильнее, чем должен."
            )
        if soft < need_s:
            problems.append(
                f"кромка за окном резче, чем у голого стекла: мягкость {soft:.3f} "
                f"против {cs:.3f}."
            )
        return (not problems), problems

    if t < MIN_TRANSMISSION:
        problems.append(
            f"окно не пропускает: {t:.2f} при пороге {MIN_TRANSMISSION:.2f}. "
            "Это краска, а не стекло."
        )
    elif soft < MIN_SOFTNESS:
        problems.append(
            f"кромка полос за окном осталась резкой: мягкость {soft:.2f} при "
            f"пороге {MIN_SOFTNESS:.2f}. Это дыра, а не размытие."
        )
    return (not problems), problems


def gate(measurements: dict) -> tuple[bool, list[str]]:
    """Приёмка закреплённого вида: сегодняшнее окно как эталон на будущее."""
    problems = []
    back = measurements["страница"]["пропускание"]
    if back < LOCKED["фон_пропускание_мин"]:
        problems.append(
            f"фон окна закрылся: пропускание {back:.3f} при пороге "
            f"{LOCKED['фон_пропускание_мин']:.2f}. Прозрачное стекло подменили плотным."
        )
    for name in ("боковик", "низ"):
        plate = measurements[name]["пропускание"]
        if plate < LOCKED["плита_пропускание_мин"]:
            problems.append(
                f"плита «{name}» стала молочной: {plate:.3f} при нижнем пороге "
                f"{LOCKED['плита_пропускание_мин']:.2f}."
            )
        if plate > LOCKED["плита_пропускание_макс"]:
            problems.append(
                f"плита «{name}» растворилась в фоне: {plate:.3f} при верхнем пороге "
                f"{LOCKED['плита_пропускание_макс']:.2f}."
            )
        if back - plate < LOCKED["разница_фон_плита_мин"]:
            problems.append(
                f"плита «{name}» не отличается от фона: разница "
                f"{back - plate:.3f} при пороге {LOCKED['разница_фон_плита_мин']:.2f}."
            )
    for name, v in measurements.items():
        if name == "всё окно":
            continue
        if v["мягкость"] < LOCKED["мягкость_мин"]:
            problems.append(
                f"преломление пропало в области «{name}»: мягкость {v['мягкость']:.3f} "
                f"при пороге {LOCKED['мягкость_мин']:.2f}."
            )
    return (not problems), problems


def measure_plate(black: np.ndarray, white: np.ndarray, stripes: np.ndarray) -> dict:
    """Пропускание и мягкость по СЕРЕДИНЕ плашки.

    Только середина: у плашки скруглённая капсула во всё окно, и по углам кадра
    стекла нет вовсе - там подложка видна напрямую и пропускание там единица.
    Считать её значило бы мерить не стекло, а поле вокруг него.
    """
    if not (black.shape == white.shape == stripes.shape):
        raise ValueError(f"кадры разного размера: {black.shape}, {white.shape}, {stripes.shape}")
    h, w = black.shape
    dy = int((1 - PLATE_CORE) / 2 * h)
    dx = int((1 - PLATE_CORE) / 2 * w)
    ys, xs = slice(dy, h - dy), slice(dx, w - dx)
    d_trans = (white - black)[ys, xs]
    d_stripe = (stripes - black)[ys, xs]
    columns = d_stripe.mean(axis=0)
    span = float(columns.max() - columns.min())
    if span < 1.0:
        softness = 0.0
    else:
        low = columns.min() + 0.25 * span
        high = columns.min() + 0.75 * span
        softness = float(((columns > low) & (columns < high)).mean())
    return {
        "пропускание": round(float(d_trans.mean()) / 255.0, 4),
        "размах_полос": round(span, 2),
        "мягкость": round(softness, 4),
    }


def plate_gate(measurements: dict) -> tuple[bool, list[str]]:
    """Стекло плашки обязано быть в классе «прозрачное»."""
    problems = []
    for form, v in measurements.items():
        if v["пропускание"] < PLATE_LOCKED["пропускание_мин"]:
            problems.append(
                f"стекло плашки «{form}» закрылось: пропускание {v['пропускание']:.3f} "
                f"при пороге {PLATE_LOCKED['пропускание_мин']:.2f}. "
                "Прозрачное стекло подменили плотным."
            )
        if v["мягкость"] < PLATE_LOCKED["мягкость_мин"]:
            problems.append(
                f"преломление у плашки «{form}» пропало: мягкость {v['мягкость']:.3f} "
                f"при пороге {PLATE_LOCKED['мягкость_мин']:.2f}. Это дыра, а не стекло."
            )
    return (not problems), problems


def run_plate(shots: Path) -> int:
    forms = ("resting", "listening")
    measurements = {}
    for form in forms:
        files = {k: shots / f"plate-glass-{form}-{k}.png" for k in ("black", "white", "stripes")}
        missing = [str(p) for p in files.values() if not p.exists()]
        if missing:
            print(f"нет кадров: {', '.join(missing)}", file=sys.stderr)
            print("сними их: iriz --probe-plate <папка>", file=sys.stderr)
            return 2
        measurements[form] = measure_plate(*(luminance(files[k])
                                             for k in ("black", "white", "stripes")))
    ok, problems = plate_gate(measurements)
    print("=== стекло плашки ===")
    print(f"{'форма':<12} {'пропускание':>12} {'мягкость':>10} {'размах':>8}")
    for name, v in measurements.items():
        print(f"{name:<12} {v['пропускание']:>12.3f} {v['мягкость']:>10.3f} "
              f"{v['размах_полос']:>8.1f}")
    print()
    if ok:
        print("ВЕРДИКТ: стекло плашки прозрачное.")
    else:
        for p in problems:
            print(f"ВЕРДИКТ: НЕТ. {p}")
    return 0 if ok else 1


def run(shots: Path, appearance: str, locked: bool = False) -> int:
    files = {k: shots / f"probe-{appearance}-{k}.png" for k in ("black", "white", "stripes")}
    missing = [str(p) for p in files.values() if not p.exists()]
    if missing:
        print(f"нет кадров: {', '.join(missing)}", file=sys.stderr)
        print("сними их: iriz --glass-probe <папка>", file=sys.stderr)
        return 2

    data = {k: luminance(p) for k, p in files.items()}
    m = measure(data["black"], data["white"], data["stripes"])

    bare = {k: shots / f"bare-{appearance}-{k}.png" for k in ("black", "white", "stripes")}
    ceiling = None
    if all(p.exists() for p in bare.values()):
        cm = measure(*(luminance(bare[k]) for k in ("black", "white", "stripes")))
        ceiling = cm[VERDICT_REGION]
    ok, problems = gate(m) if locked else verdict(m, ceiling)

    print(f"=== стекло, вид {appearance} ===")
    print(f"{'область':<12} {'пропускание':>12} {'мягкость':>10} {'размах':>8}")
    for name, v in m.items():
        print(f"{name:<12} {v['пропускание']:>12.3f} {v['мягкость']:>10.3f} "
              f"{v['размах_полос']:>8.1f}")
    if ceiling:
        print(f"{'голое стекло':<12} {ceiling['пропускание']:>12.3f} "
              f"{ceiling['мягкость']:>10.3f} {ceiling['размах_полос']:>8.1f}")
    print()
    if ok:
        print("ВЕРДИКТ: закреплённый вид на месте." if locked
              else "ВЕРДИКТ: стекло. Пропускает и размывает.")
    else:
        for p in problems:
            print(f"ВЕРДИКТ: НЕТ. {p}")
    return 0 if ok else 1


def synth(kind: str, size=(400, 600)) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Три поддельных кадра с известным ответом - основа самопроверки."""
    h, w = size
    content = np.full((h, w), 128.0)
    content[100:140, :] = 30.0  # «текст», одинаковый во всех кадрах

    x = np.arange(w)
    stripe_bg = np.where((x // STRIPE_WIDTH_PT) % 2 == 0, 255.0, 0.0)
    stripe_bg = np.tile(stripe_bg, (h, 1))

    if kind == "краска":
        a = 0.98  # почти непрозрачная плита
        blur = 1.0
    elif kind == "дыра":
        a = 0.05
        blur = 0.0  # ничего не размывает
    else:  # стекло
        a = 0.45
        blur = 0.9

    def compose(bg):
        if blur:
            k = 61
            pad = np.pad(bg, ((0, 0), (k, k)), mode="edge")
            kern = np.ones(2 * k + 1) / (2 * k + 1)
            smooth = np.apply_along_axis(lambda r: np.convolve(r, kern, mode="same"), 1, pad)
            bg = blur * smooth[:, k:-k] + (1 - blur) * bg
        return a * content + (1 - a) * bg

    return compose(np.zeros((h, w))), compose(np.full((h, w), 255.0)), compose(stripe_bg)


def selftest() -> int:
    """Прибор проверяется на заведомо известных случаях, иначе он украшение."""
    cases = {"краска": False, "дыра": False, "стекло": True}
    failures = []
    for kind, expected in cases.items():
        m = measure(*synth(kind))
        ok, problems = verdict(m)
        whole = m[VERDICT_REGION]
        mark = "OK" if ok == expected else "ПРОВАЛ"
        print(f"{mark:>7}  {kind:<7} пропускание={whole['пропускание']:.3f} "
              f"мягкость={whole['мягкость']:.3f} вердикт={'стекло' if ok else 'нет'}")
        if ok != expected:
            failures.append(f"{kind}: ждали {expected}, получили {ok} ({problems})")

    # Ворота закреплённого вида проверяются отдельно: они обязаны ловить
    # именно подмену рецепта, а не любое отклонение.
    good = {
        "боковик": {"пропускание": 0.121, "мягкость": 0.21, "размах_полос": 31.0},
        "страница": {"пропускание": 0.678, "мягкость": 0.25, "размах_полос": 173.0},
        "низ": {"пропускание": 0.105, "мягкость": 0.46, "размах_полос": 53.0},
        "всё окно": {"пропускание": 0.302, "мягкость": 0.31, "размах_полос": 87.6},
    }
    gate_cases = {"принятое окно": (good, True)}
    flat = json.loads(json.dumps(good))
    flat["боковик"]["пропускание"] = 0.45      # плита слилась с фоном
    gate_cases["плита без тона"] = (flat, False)
    dense = json.loads(json.dumps(good))
    dense["страница"]["пропускание"] = 0.30    # фон стал плотным
    gate_cases["фон закрылся"] = (dense, False)
    dull = json.loads(json.dumps(good))
    dull["низ"]["мягкость"] = 0.02             # преломление пропало
    gate_cases["без преломления"] = (dull, False)
    for name, (data, expected) in gate_cases.items():
        ok, problems = gate(data)
        mark = "OK" if ok == expected else "ПРОВАЛ"
        print(f"{mark:>7}  ворота: {name} -> {'принято' if ok else 'отказ'}")
        if ok != expected:
            failures.append(f"ворота {name}: ждали {expected}, получили {ok} ({problems})")

    # Ворота плашки: честный вход зелёный, плотное стекло и дыра - красные.
    clear = {"resting": {"пропускание": PLATE_LOCKED["пропускание_мин"] + 0.05,
                         "мягкость": 0.30, "размах_полос": 40.0},
             "listening": {"пропускание": PLATE_LOCKED["пропускание_мин"] + 0.05,
                           "мягкость": 0.30, "размах_полос": 40.0}}
    plate_cases = {"прозрачная плашка": (clear, True)}
    dense = json.loads(json.dumps(clear))
    dense["listening"]["пропускание"] = max(0.0, PLATE_LOCKED["пропускание_мин"] - 0.05)
    plate_cases["плашка закрылась"] = (dense, False)
    hole = json.loads(json.dumps(clear))
    hole["resting"]["мягкость"] = 0.01
    plate_cases["преломление пропало"] = (hole, False)
    for name, (data, expected) in plate_cases.items():
        ok, problems = plate_gate(data)
        mark = "OK" if ok == expected else "ПРОВАЛ"
        print(f"{mark:>7}  плашка: {name} -> {'принято' if ok else 'отказ'}")
        if ok != expected:
            failures.append(f"плашка {name}: ждали {expected}, получили {ok} ({problems})")

    if failures:
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        return 1
    print("самопроверка: прибор различает краску, дыру и стекло, ворота ловят подмену рецепта.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Замер стекла окна настроек.")
    ap.add_argument("--shots", type=Path, default=Path(".build/glass-probe"))
    ap.add_argument("--appearance", default="light", choices=["light", "dark"])
    ap.add_argument("--json", action="store_true", help="выдать замеры как JSON")
    ap.add_argument("--locked", action="store_true",
                    help="судить по закреплённому виду, а не по потолку системы")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--plate", type=Path, default=None,
                    help="судить стекло ПЛАШКИ по кадрам из этой папки")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if args.plate is not None:
        return run_plate(args.plate)

    if args.json:
        files = {k: args.shots / f"probe-{args.appearance}-{k}.png"
                 for k in ("black", "white", "stripes")}
        if any(not p.exists() for p in files.values()):
            return 2
        m = measure(*(luminance(files[k]) for k in ("black", "white", "stripes")))
        print(json.dumps(m, ensure_ascii=False, indent=2))
        return 0 if verdict(m)[0] else 1

    return run(args.shots, args.appearance, locked=args.locked)


if __name__ == "__main__":
    sys.exit(main())
