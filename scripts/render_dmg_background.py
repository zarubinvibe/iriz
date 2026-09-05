#!/usr/bin/env python3
"""Фон окна образа: подложка, стрелка и одна строка подписи.

Окно образа - первое, что человек видит от продукта. Список файлов в нём
означает «разбирайся сам»; два значка и стрелка между ними означают
«перетащи». Второе не требует ни строчки инструкции и работает на любом языке
ровно потому, что инструкции в нём нет.

Рисуется машиной, а не руками: размеры фона и координаты значков в
scripts/make_release.sh обязаны совпадать, и совпадать они могут только если
приходят из одного места. Числа тут - точки окна, множитель даёт вторую
плотность для ретины.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 660, 420
APP_X, APP_Y = 170, 190
ALIAS_X, ALIAS_Y = 490, 190
CAPTION = "Перетащи iriz в Applications"
FONT_PATH = "/System/Library/Fonts/SFNS.ttf"

TOP = (251, 250, 248)
BOTTOM = (240, 238, 233)
ARROW = (158, 152, 143)
TEXT = (108, 104, 98)


def render(scale: int) -> Image.Image:
    width, height = WIDTH * scale, HEIGHT * scale
    image = Image.new("RGB", (width, height), TOP)
    draw = ImageDraw.Draw(image)

    for y in range(height):
        t = y / max(1, height - 1)
        draw.line(
            [(0, y), (width, y)],
            fill=tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)),
        )

    # Стрелка идёт ровно по центрам значков: она указывает на цель, а не в
    # пустоту рядом с ней.
    y = round((APP_Y - 18) * scale)
    x0 = round((APP_X + 108) * scale)
    x1 = round((ALIAS_X - 108) * scale)
    head = round(16 * scale)
    draw.line([(x0, y), (x1 - head, y)], fill=ARROW, width=round(4 * scale))
    draw.polygon(
        [(x1, y), (x1 - head, y - head * 0.62), (x1 - head, y + head * 0.62)],
        fill=ARROW,
    )

    font = ImageFont.truetype(FONT_PATH, round(14 * scale))
    box = draw.textbbox((0, 0), CAPTION, font=font)
    draw.text(
        ((width - (box[2] - box[0])) / 2, round(330 * scale)),
        CAPTION,
        font=font,
        fill=TEXT,
    )
    return image


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: render_dmg_background.py <bg.png> <bg@2x.png>", file=sys.stderr)
        return 2
    render(1).save(sys.argv[1])
    render(2).save(sys.argv[2])
    print(f"фон образа: {WIDTH}x{HEIGHT} и {WIDTH * 2}x{HEIGHT * 2}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
