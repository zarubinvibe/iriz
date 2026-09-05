#!/usr/bin/env python3
"""Таблица WER: базовый движок против кандидатов, один прибор, один корпус.

Зовется так:
    python3 scripts/bench_compare.py <корпус> имя=<каталог расшифровок> [имя=<каталог> ...]

Корпус - каталог с подкаталогами ru и en (эталоны и wav лежат вместе).
Каждому кандидату дается ОДИН и тот же срез, посчитанный из эталона.

Почему две колонки на русский. Эталон читан с листа, где числа выписаны
СЛОВАМИ. Движок, отвечающий словами, совпадает с эталоном; движок, приводящий
к цифрам, получает до 80 процентов ошибок на фразе, которую расслышал верно.
Для юридического документа цифры как раз и нужны, то есть прибор наказывает
лучший вывод. Поэтому рядом стоит замер без записей с числительными: он меряет
слух, а не соглашение о записи чисел.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from bench_wer import measure  # noqa: E402

ROWS = (
    ("ru все", "ru", "all", False),
    ("ru чистый", "ru", "clean", False),
    ("ru смешанный", "ru", "mixed", False),
    ("ru все, без чисел", "ru", "all", True),
    ("ru чистый, без чисел", "ru", "clean", True),
    ("ru смешанный, без чисел", "ru", "mixed", True),
    ("en", "en", "all", False),
)


def wer(ref_dir: Path, hyp_dir: Path, slice_mode: str, drop: bool):
    rows, errs, total = measure(ref_dir, hyp_dir, slice_mode, drop)
    return (100 * errs / total, errs, total, len(rows)) if total else None


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    corpus = Path(sys.argv[1])
    engines = []
    for spec in sys.argv[2:]:
        if "=" not in spec:
            print(f"ожидалось имя=каталог, получено: {spec}", file=sys.stderr)
            return 2
        name, _, path = spec.partition("=")
        engines.append((name, Path(path)))

    width = max(24, *(len(n) for n, _ in engines))
    print("срез".ljust(26) + "".join(n.ljust(width) for n, _ in engines))
    print("-" * (26 + width * len(engines)))
    for label, lang, slice_mode, drop in ROWS:
        cells = []
        for _, hyp in engines:
            r = wer(corpus / lang, hyp / lang, slice_mode, drop)
            cells.append(f"{r[0]:.2f}%  {r[1]}/{r[2]} на {r[3]}".ljust(width) if r else "нет данных".ljust(width))
        print(label.ljust(26) + "".join(cells))
    return 0


if __name__ == "__main__":
    sys.exit(main())
