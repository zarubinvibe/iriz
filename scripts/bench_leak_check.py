#!/usr/bin/env python3
"""Ворота против утечки: термины промта не смеют встречаться в эталонах.

    python3 scripts/bench_leak_check.py "<текст промта>" <каталог эталонов>

Код 0 - пересечений нет, число замера предъявляемо.
Код 1 - есть, и тогда выигрыш доказывает подсказку ответов, а не работу рычага.

Почему это ворота, а не заметка. 03.09.2026 русский промт я собрал намеренно
чисто и выигрыш 44,05 в 19,05 оказался честным. Английский в том же прогоне
собрал машинально - «pull request, git rebase, CI logs», - и греп нашел 2
совпадения из 10 эталонов. Дисциплина, живущая во внимании, отвалилась на
втором применении. Значит она обязана жить в приборе.

Сверяются ЛАТИНСКИЕ термины: рычаг под смешанную речь ими и работает.
"""
import re
import sys
from pathlib import Path

# Латинское слово от двух букв: односимвольные дают шум на любом тексте.
TERM = re.compile(r"[A-Za-z][A-Za-z0-9.+#-]{1,}")

# Служебные слова совпадают в любом английском тексте и утечкой не являются:
# сверяются СОДЕРЖАТЕЛЬНЫЕ термины, за которые и тянет рычаг.
FUNCTION_WORDS = frozenset("""
a an the and or but if then than that this these those there here
is am are was were be been being do does did done
of in on at to for with without from into over under by as
i you he she it we they me him her us them my your his its our their
not no nor so too very can could will would shall should may might must
have has had also just only about after before when while where which who whom
""".split())


def terms(prompt: str) -> set[str]:
    raw = {m.group(0).strip(".-").lower() for m in TERM.finditer(prompt)}
    return {t for t in raw if t not in FUNCTION_WORDS}


def leaks(prompt: str, ref_dir: Path) -> list[tuple[str, str]]:
    found = []
    wanted = terms(prompt)
    if not wanted:
        return found
    for ref in sorted(ref_dir.glob("*.txt")):
        low = ref.read_text(encoding="utf-8").lower()
        for t in sorted(wanted):
            if re.search(r"(?<![A-Za-z0-9])" + re.escape(t) + r"(?![A-Za-z0-9])", low):
                found.append((ref.name, t))
    return found


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    prompt, ref_dir = sys.argv[1], Path(sys.argv[2])
    if not ref_dir.is_dir():
        print(f"нет каталога эталонов: {ref_dir}", file=sys.stderr)
        return 2
    found = leaks(prompt, ref_dir)
    if found:
        print(f"УТЕЧКА: терминов промта в эталонах {len(found)}", file=sys.stderr)
        for name, t in found:
            print(f"  {name}: {t}", file=sys.stderr)
        print("Число такого замера доказывает подсказку, а не рычаг.", file=sys.stderr)
        return 1
    print(f"утечки нет: сверено терминов {len(terms(prompt))} по эталонам в {ref_dir.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
