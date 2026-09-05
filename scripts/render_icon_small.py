#!/usr/bin/env python3
"""Мелкий мастер значка: то же, что герой, но нарисованное так, чтобы выжить в 16-64 px.

Зачем отдельный мастер. Герой - это рендер: мрамор с прожилками, звёздное небо,
стекло. Ужатый в 32 px он теряет ровно то, что несёт смысл: замер показал, что
гребень горы читается только в 17 колонках из 32, волна схлопывается в ровную
полосу, вырез кальдеры остаётся в данных, но глазом не берётся. Так же поступает
Apple: iconset несёт РАЗНОЕ изображение на разных размерах.

Здесь ничего не выдумывается. Обвод горы снимается с того же референса владельца,
что и у героя, а шаг и огибающая волны берутся из констант HUD, чтобы значок
цитировал продукт, а не похожую картинку.
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REF = os.path.join(ROOT, "docs", "assets", "pantheon", "olympus-profile-ref.png")

SIZE = 1024
SKY_TOP = (9, 13, 26)
SKY_BOTTOM = (26, 35, 62)
MARBLE_LIT = (233, 236, 244)
MARBLE_SHADED = (146, 155, 177)
GOLD = (241, 186, 82)          # насыщенное золото: бледное на тёмном не читается золотом
GLASS = (182, 197, 219)
GROUND_LINE = (96, 105, 128)

# Плашка: пропорции и огибающая продукта. Столбиков девять, а не двадцать восемь:
# в 32 px двадцать восемь сливаются в полосу, и цитата перестаёт читаться цитатой.
PLATE_RATIO = 74.0 / 248.0
BAR_COUNT = 9
# Плашка крупнее и выше горы. Слова владельца 04.09.2026: «элемент со звуковой
# волной должен быть больше и расположен выше, и от него должно быть свечение -
# иначе на иконке непонятно, что это такое».
PLATE_WIDTH_SHARE = 0.74
PLATE_GAP_SHARE = 0.13         # воздух между плашкой и вершиной
GLOW_RADIUS_SHARE = 0.055      # мягкая аура вокруг плашки
GLOW_STRENGTH = 1.0
GLOW_GAIN = 1.15               # во сколько раз свет ярче маски

# Кадрирование обвода: те же числа, что у эталона композиции героя.
CROP_LEFT, CROP_RIGHT = 100, 500
WATER_LINE = 256
GROUND_FRACTION = 0.10


def olympus_profile(ref_path):
    """Верхний обвод Олимпа с референса: гора красная, небо бледное, вода синяя."""
    pixels = np.asarray(Image.open(ref_path).convert("RGB")).astype(int)
    red, green, blue = pixels[:, :, 0], pixels[:, :, 1], pixels[:, :, 2]
    rock = (red > 110) & (green < 140) & (blue < 140) & (red - green > 40)
    width = pixels.shape[1]
    top = np.full(width, WATER_LINE)
    for x in range(width):
        rows = np.nonzero(rock[:WATER_LINE, x])[0]
        if len(rows):
            top[x] = rows[0]
    smooth = np.convolve(top, np.ones(5) / 5, mode="same")
    smooth[:3], smooth[-3:] = top[:3], top[-3:]
    return smooth


def bar_rects(plate_x, plate_y, plate_w, plate_h):
    """Прямоугольники столбиков волны. Одна геометрия и на свет, и на сами
    стержни: две копии формулы разъезжаются на первой же правке."""
    step = plate_w * 0.74 / BAR_COUNT
    bar_w = step * 0.42
    centre_y = plate_y + plate_h / 2
    span = plate_h * 0.62
    start_x = plate_x + (plate_w - (BAR_COUNT * step - (step - bar_w))) / 2
    rects = []
    for i in range(BAR_COUNT):
        t = (i + 0.5) / BAR_COUNT
        edge = min(1.0, math.sin(math.pi * t) * 1.45)          # к краям волна садится в линию
        amplitude = abs(math.sin(t * math.pi * 2.6)) * 0.60 + abs(math.sin(t * math.pi * 5.7)) * 0.28
        height = max(bar_w, span * amplitude * edge)
        x = start_x + i * step
        rects.append((x, centre_y - height / 2, x + bar_w, centre_y + height / 2))
    return rects


def render(out_path, ref_path=REF, size=SIZE):
    profile = olympus_profile(ref_path)
    sky = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(sky)
    for y in range(size):
        t = y / size
        draw.line(
            [(0, y), (size, y)],
            fill=tuple(int(SKY_TOP[i] + (SKY_BOTTOM[i] - SKY_TOP[i]) * t) for i in range(3)),
        )

    scale = size / (CROP_RIGHT - CROP_LEFT)
    ground = size * (1 - GROUND_FRACTION)
    ridge = [
        ((x - CROP_LEFT) * scale, ground - (WATER_LINE - profile[x]) * scale)
        for x in range(CROP_LEFT, CROP_RIGHT)
    ]
    summit = min(point[1] for point in ridge)

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).polygon(ridge + [(size, ground), (0, ground)], fill=255)

    # Свет слева: поперечный градиент по всему холсту, обрезанный маской горы.
    # Затенять отдельным многоугольником нельзя - на стыке появляется шов, а
    # размытая маска даёт ореол в небе.
    gradient = np.zeros((size, size, 3), dtype=np.uint8)
    for x in range(size):
        t = (x / size) ** 1.15
        gradient[:, x] = [
            int(MARBLE_LIT[i] + (MARBLE_SHADED[i] - MARBLE_LIT[i]) * t) for i in range(3)
        ]

    icon = Image.composite(Image.fromarray(gradient), sky, mask)
    draw = ImageDraw.Draw(icon)
    draw.line([(0, ground), (size, ground)], fill=GROUND_LINE, width=max(2, int(size * 0.004)))

    plate_w = size * PLATE_WIDTH_SHARE
    plate_h = plate_w * PLATE_RATIO
    plate_x = (size - plate_w) / 2
    plate_y = summit - plate_h - size * PLATE_GAP_SHARE

    bars = bar_rects(plate_x, plate_y, plate_w, plate_h)

    # Свет идёт ОТ СТЕРЖНЕЙ, а не из заливки капсулы. Залитая капсула делала
    # плашку сплошной золотой пилюлей, а стекло обязано оставаться прозрачным:
    # внутри - та же ночь, что и снаружи, и сквозь неё видно фон.
    glow = Image.new("L", (size, size), 0)
    glow_draw = ImageDraw.Draw(glow)
    for rect in bars:
        glow_draw.rounded_rectangle(rect, radius=(rect[2] - rect[0]) / 2, fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(size * GLOW_RADIUS_SHARE))
    # Свет СКЛАДЫВАЕТСЯ с ночью, а не закрашивает её: замена цветом гасит звёзды
    # и мрамор под аурой, сложение оставляет их видимыми сквозь свет.
    base = np.asarray(icon).astype(float)
    mask = np.asarray(glow).astype(float)[:, :, None] / 255.0
    icon = Image.fromarray(
        np.clip(base + mask * np.array(GOLD, dtype=float) * GLOW_GAIN, 0, 255).astype(np.uint8)
    )
    draw = ImageDraw.Draw(icon)

    draw.rounded_rectangle(
        [plate_x, plate_y, plate_x + plate_w, plate_y + plate_h],
        radius=plate_h / 2,
        outline=GLASS,
        width=max(3, int(size * 0.009)),
    )

    for rect in bars:
        draw.rounded_rectangle(rect, radius=(rect[2] - rect[0]) / 2, fill=GOLD)

    icon.save(out_path)
    return out_path


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        ROOT, "docs", "assets", "pantheon", "icon-iriz-small.png"
    )
    print(render(target))
