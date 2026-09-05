#!/usr/bin/env python3
"""Замер WER на эталонном корпусе (волна 1, REQ-04..REQ-06).

Одна формула для обоих языков: пословное расстояние Левенштейна между
эталоном и расшифровкой, делённое на число слов эталона.

Нормализация: регистр и знаки препинания снимаются. Буква ё НЕ схлопывается
в е намеренно - движок выдаёт на ней <unk>, и схлопывание спрятало бы дефект.

Срез корпуса (--slice) режет тот же каталог на части БЕЗ ручной разметки:
запись считается смешанной тогда и только тогда, когда в её ЭТАЛОНЕ есть
латиница. Правило воспроизводит разбиение базлайна 03.09.2026 точно -
23 чистых записи на 262 слова и 7 смешанных на 84. Разметка на вкус
исполнителя невозможна по построению: срез выводится из эталона, а не
назначается. Так один прибор на одном корпусе даёт четыре числа.

Печатает число, а не оценку словами. Код возврата 2, если сравнивать нечего.
"""
import re, sys, unicodedata
from pathlib import Path

PUNCT = re.compile(r"[^\w\sЀ-ӿ]", re.UNICODE)
LATIN = re.compile(r"[A-Za-z]")
SLICES = ("all", "clean", "mixed")

# Числительные смещают замер, а не меряют слух. Эталон читан с листа, где числа
# выписаны СЛОВАМИ, поэтому движок, отвечающий словами, совпадает с эталоном, а
# движок, приводящий к цифрам, получает до 80 процентов ошибок на фразе, которую
# расслышал верно: «четыреста восемьдесят семь тысяч шестьсот» против «487 600».
# Для юридического документа цифры как раз и нужны, то есть наказан лучший вывод.
# Полная нормализация русских числительных сюда не влезает - порядковые
# («третьего февраля» против «3 февраля») к кардинальным не сводятся. Поэтому
# --drop-numerals режет записи с числительными и сравнивает на остатке: отрезано
# машинно, по эталону, и одинаково для всех кандидатов.
NUMERAL_WORDS = (
    "ноль", "один", "одна", "одно", "два", "две", "три", "четыре", "пять", "шест",
    "сем", "восем", "девят", "десят", "одиннадцат", "двенадцат", "тринадцат",
    "четырнадцат", "пятнадцат", "шестнадцат", "семнадцат", "восемнадцат",
    "девятнадцат", "двадцат", "тридцат", "сорок", "пятьдесят", "шестьдесят",
    "семьдесят", "восемьдесят", "девяносто", "сто", "двести", "трист", "четырест",
    "пятьсот", "шестьсот", "семьсот", "восемьсот", "девятьсот", "тысяч", "миллион",
    "первого", "первой", "перв", "второго", "втор", "треть", "четверт", "пятого",
)
NUMERAL_RE = re.compile(r"\d|\b(?:" + "|".join(NUMERAL_WORDS) + r")\w*", re.UNICODE)


def has_numeral(ref_text: str) -> bool:
    """Числительное в ЭТАЛОНЕ - цифрой или словом."""
    return NUMERAL_RE.search(ref_text.lower()) is not None


def in_slice(ref_text: str, mode: str) -> bool:
    """Смешанная запись - та, где в эталоне есть латиница. Иначе чистая."""
    if mode == "all":
        return True
    return LATIN.search(ref_text) is not None if mode == "mixed" else LATIN.search(ref_text) is None

def words(text: str) -> list[str]:
    t = unicodedata.normalize("NFC", text).lower()
    t = PUNCT.sub(" ", t)
    return t.split()

def distance(ref: list[str], hyp: list[str]) -> int:
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i]
        for j, h in enumerate(hyp, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h)))
        prev = cur
    return prev[-1]

def measure(ref_dir: Path, hyp_dir: Path, slice_mode: str = "all", drop_numerals: bool = False):
    rows, errs, total = [], 0, 0
    for ref_file in sorted(ref_dir.glob("*.txt")):
        hyp_file = hyp_dir / ref_file.name
        if not hyp_file.exists():
            continue
        ref_text = ref_file.read_text(encoding="utf-8")
        if not in_slice(ref_text, slice_mode):
            continue
        if drop_numerals and has_numeral(ref_text):
            continue
        ref = words(ref_text)
        hyp = words(hyp_file.read_text(encoding="utf-8"))
        if not ref:
            continue
        d = distance(ref, hyp)
        errs += d
        total += len(ref)
        rows.append((d / len(ref), ref_file.stem, d, len(ref), ref_file, hyp_file))
    return rows, errs, total

def main() -> int:
    argv = sys.argv[1:]
    slice_mode = "all"
    if "--slice" in argv:
        i = argv.index("--slice")
        if i + 1 >= len(argv) or argv[i + 1] not in SLICES:
            print(f"--slice принимает одно из: {', '.join(SLICES)}", file=sys.stderr)
            return 2
        slice_mode = argv[i + 1]
        del argv[i:i + 2]
    drop_numerals = "--drop-numerals" in argv
    if drop_numerals:
        argv.remove("--drop-numerals")
    if len(argv) < 2:
        print("usage: bench_wer.py [--slice all|clean|mixed] [--drop-numerals] <каталог эталонов> <каталог расшифровок> [сколько худших показать]", file=sys.stderr)
        return 2
    ref_dir, hyp_dir = Path(argv[0]), Path(argv[1])
    worst_n = int(argv[2]) if len(argv) > 2 else 5
    rows, errs, total = measure(ref_dir, hyp_dir, slice_mode, drop_numerals)
    if not total:
        print(f"сравнивать нечего: {ref_dir} против {hyp_dir} (срез {slice_mode})", file=sys.stderr)
        return 2
    print(f"WER {100 * errs / total:.2f}%   ошибок {errs} из {total} слов, записей {len(rows)}, срез {slice_mode}{' без числительных' if drop_numerals else ''}")
    if worst_n:
        print(f"\nхудшие {min(worst_n, len(rows))}:")
        for rate, name, d, n, rf, hf in sorted(rows, reverse=True)[:worst_n]:
            print(f"\n  [{name}] {100 * rate:.1f}%  ({d} из {n})")
            print(f"    эталон:  {rf.read_text(encoding='utf-8').strip()}")
            print(f"    услышано: {hf.read_text(encoding='utf-8').strip()}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
