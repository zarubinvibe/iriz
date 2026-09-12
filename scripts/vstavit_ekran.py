#!/usr/bin/env python3
"""Положить настоящий кадр продукта на экран мраморного ноутбука.

Почему прибором, а не рисованием. Модель, которой велено нарисовать интерфейс,
рисует ПОХОЖИЙ интерфейс: кнопки не те, слова выдуманы, шрифт чужой. Такая
картинка врёт про продукт тем громче, чем красивее сцена. Здесь на экран
ложатся настоящие пиксели витрины, снятые тем же прибором, что и всё остальное.

Четырёхугольник экрана задаётся файлом рядом с кадром: сцена меняется редко, а
углы меряются один раз. Прибор проверяет, что по этим углам действительно лежит
ровное светлое поле, и отказывается работать, если сцену пересняли и углы
разъехались, - иначе кадр продукта уехал бы на мрамор.

    scripts/vstavit_ekran.py <сцена.png> <углы.json> <кадр.png> <выход.png>
    scripts/vstavit_ekran.py --selftest
"""
import json
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageStat


def koefficienty(iz_uglov, v_ugly):
    """Коэффициенты перспективы для PIL: они отображают ВЫХОД в ВХОД."""
    a = []
    b = []
    for (x, y), (u, v) in zip(v_ugly, iz_uglov):
        a.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
        b.append(u)
        a.append([0, 0, 0, x, y, 1, -v * x, -v * y])
        b.append(v)
    # Решение системы 8x8 методом Гаусса: numpy сюда тянуть незачем.
    n = 8
    for i in range(n):
        glavnaya = max(range(i, n), key=lambda r: abs(a[r][i]))
        a[i], a[glavnaya] = a[glavnaya], a[i]
        b[i], b[glavnaya] = b[glavnaya], b[i]
        if abs(a[i][i]) < 1e-9:
            raise ValueError("вырожденный четырёхугольник экрана")
        for r in range(i + 1, n):
            k = a[r][i] / a[i][i]
            for c in range(i, n):
                a[r][c] -= k * a[i][c]
            b[r] -= k * b[i]
    x = [0.0] * n
    for i in range(n - 1, -1, -1):
        s = sum(a[i][c] * x[c] for c in range(i + 1, n))
        x[i] = (b[i] - s) / a[i][i]
    return x


def proverit_ekran(scena, ugly):
    """Экран обязан быть ровным полем, которое СВЕТЛЕЕ мрамора вокруг.

    Абсолютный порог яркости тут не работает: мрамор сцены сам светлый, и
    четырёхугольник, съехавший на стол, проходил проверку. Судим по разнице с
    каймой снаружи - она есть у экрана и её нет у мрамора.
    """
    xs = [t[0] for t in ugly]
    ys = [t[1] for t in ugly]
    l, r, t, b = int(min(xs)), int(max(xs)), int(min(ys)), int(max(ys))
    vnutri = scena.crop((l + 12, t + 12, r - 12, b - 12)).convert("L")
    kajma = 24
    snaruji = scena.crop((max(0, l - kajma), max(0, t - kajma),
                          min(scena.width, r + kajma), min(scena.height, b + kajma))).convert("L")
    sv = ImageStat.Stat(vnutri)
    sn = ImageStat.Stat(snaruji)
    raznica = sv.mean[0] - sn.mean[0]
    horosho = raznica > 3 and sv.stddev[0] < 12
    return horosho, round(sv.mean[0], 1), round(raznica, 1)


def obrezat_polya(kadr, dopusk=10):
    """Снять ровные поля вокруг окна.

    Кадры витрины снимаются с полем в 96 точек - ради тени и воздуха на
    странице. На экране ноутбука это поле лишнее: окно внутри окна читается
    вложенной картинкой, а не работающей программой.
    """
    seryj = kadr.convert("L")
    w, h = seryj.size
    fon = seryj.getpixel((1, 1))

    def dannye(kusok):
        return kusok.get_flattened_data() if hasattr(kusok, "get_flattened_data") else kusok.getdata()

    def rovnaya(pikseli):
        return all(abs(p - fon) <= dopusk for p in pikseli)

    l, r, t, b = 0, w - 1, 0, h - 1
    while l < r and rovnaya(dannye(seryj.crop((l, 0, l + 1, h)))): l += 1
    while r > l and rovnaya(dannye(seryj.crop((r, 0, r + 1, h)))): r -= 1
    while t < b and rovnaya(dannye(seryj.crop((0, t, w, t + 1)))): t += 1
    while b > t and rovnaya(dannye(seryj.crop((0, b, w, b + 1)))): b -= 1
    if r - l < 40 or b - t < 40:
        return kadr
    return kadr.crop((l, t, r + 1, b + 1))


def vstavit(scena_put, ugly_put, kadr_put, vyhod_put):
    scena = Image.open(scena_put).convert("RGB")
    ugly = [tuple(t) for t in json.load(open(ugly_put, encoding="utf-8"))["ekran"]]
    rovno, sredneye, razbros = proverit_ekran(scena, ugly)
    if not rovno:
        print(f"УГЛЫ НЕ ПО ЭКРАНУ: яркость {sredneye}, перевес над каймой {razbros}. "
              f"Сцену пересняли - перемерьте углы.", file=sys.stderr)
        return 1

    kadr = obrezat_polya(Image.open(kadr_put).convert("RGB"))
    shirina = int(max(t[0] for t in ugly) - min(t[0] for t in ugly))
    vysota = int(max(t[1] for t in ugly) - min(t[1] for t in ugly))
    # Кадр вписывается в экран целиком, поля добираются его же краевым цветом:
    # обрезать продукт ради формы экрана значит показать половину окна.
    k = min(shirina / kadr.width, vysota / kadr.height)
    ujatyj = kadr.resize((max(1, int(kadr.width * k)), max(1, int(kadr.height * k))), Image.LANCZOS)
    pole = Image.new("RGB", (shirina, vysota), ujatyj.getpixel((0, 0)))
    pole.paste(ujatyj, ((shirina - ujatyj.width) // 2, (vysota - ujatyj.height) // 2))

    kf = koefficienty([(0, 0), (shirina, 0), (shirina, vysota), (0, vysota)], ugly)
    lozhe = pole.transform(scena.size, Image.PERSPECTIVE, kf, Image.BICUBIC)
    maska = Image.new("L", (shirina, vysota), 255).transform(
        scena.size, Image.PERSPECTIVE, kf, Image.BICUBIC)
    gotovo = scena.copy()
    gotovo.paste(lozhe, (0, 0), maska)
    # Экран остаётся стеклом: лёгкий свет сцены поверх кадра, иначе картинка
    # выглядит наклейкой, а не свечением панели.
    blik = Image.new("RGB", scena.size, (255, 255, 255))
    gotovo = Image.blend(gotovo, Image.composite(blik, gotovo, maska), 0.06)
    gotovo.save(vyhod_put)
    print(f"вставлено: {vyhod_put}")
    return 0


def selftest():
    with tempfile.TemporaryDirectory(prefix="iriz-screen-selftest-") as directory:
        root = Path(directory)
        scena = Image.new("RGB", (400, 300), (232, 226, 216))
        ekran = (100, 60, 300, 200)
        scena.paste(Image.new("RGB", (200, 140), (242, 236, 228)), ekran[:2])
        scena.save(root / "scena.png")
        (root / "ugly.json").write_text(
            json.dumps({"ekran": [[100, 60], [300, 60], [300, 200], [100, 200]]}), encoding="utf-8")
        Image.new("RGB", (200, 120), (20, 90, 200)).save(root / "kadr.png")
        if vstavit(root / "scena.png", root / "ugly.json",
                   root / "kadr.png", root / "vyhod.png") != 0:
            print("ПРОВАЛ: честная сцена отвергнута", file=sys.stderr)
            return 1
        gotovo = Image.open(root / "vyhod.png").convert("RGB")
        r, g, b = gotovo.getpixel((200, 130))
        if not (b > r + 40):
            print(f"ПРОВАЛ: кадр не лёг на экран, в середине {r},{g},{b}", file=sys.stderr)
            return 1
        print("     OK  кадр лёг ровно в экран")
        # Порченый вход: углы показывают на мрамор, а не на экран.
        (root / "ugly-bad.json").write_text(
            json.dumps({"ekran": [[10, 10], [90, 10], [90, 50], [10, 50]]}), encoding="utf-8")
        if vstavit(root / "scena.png", root / "ugly-bad.json",
                   root / "kadr.png", root / "vyhod2.png") == 0:
            print("ПРОВАЛ: устаревшие углы не пойманы", file=sys.stderr)
            return 1
    print("     OK  углы мимо экрана отвергнуты")
    print("SELFTEST OK")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(vstavit(*sys.argv[1:5]))
