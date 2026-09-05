#!/usr/bin/env python3
"""Собрать ключи перевода из кода в таблицу .strings.

Ключи не выдумываются и не ведутся списком руками: единственный источник -
вызовы L("ключ", "оригинал") в исходниках. Список, который ведут отдельно,
расходится с кодом на первой же правке, и расхождение видно только переводчику.

    scripts/collect_strings.py                 напечатать пары ключ/оригинал
    scripts/collect_strings.py --write en zh   дописать недостающие ключи в таблицы
    scripts/collect_strings.py --selftest      самопроверка разбора
"""
import os
import re
import sys

KORNI = ["Sources"]
TABLICY = {"en": "Sources/IrizCore/Resources/en.lproj/Localizable.strings",
           "zh": "Sources/IrizCore/Resources/zh-Hans.lproj/Localizable.strings"}
# Вызов пишется в одну или несколько строк, оригинал может собираться из кусков
# через +. Забирать только первый кусок значило бы отдать переводчику половину
# фразы, поэтому склеиваем все.
VYZOV = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*((?:"(?:[^"\\]|\\.)*"\s*(?:\+\s*)?)+)\)', re.S)
KUSOK = re.compile(r'"((?:[^"\\]|\\.)*)"')


def sobrat(text):
    pary = []
    for m in VYZOV.finditer(text):
        klyuch = m.group(1)
        original = "".join(KUSOK.findall(m.group(2)))
        pary.append((klyuch, original))
    return pary


def iz_dereva():
    nayden = {}
    for koren in KORNI:
        for dp, _, fs in os.walk(koren):
            for f in fs:
                if not f.endswith(".swift"):
                    continue
                put = os.path.join(dp, f)
                for klyuch, original in sobrat(open(put, encoding="utf-8").read()):
                    nayden.setdefault(klyuch, original)
    return nayden


def sushchestvuyushchie(put):
    if not os.path.exists(put):
        return set()
    est = set()
    for stroka in open(put, encoding="utf-8"):
        m = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*=', stroka)
        if m:
            est.add(m.group(1))
    return est


def ekran(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def selftest():
    obrazec = '''
    static let a = L("k.one", "Привет")
    let b = L("k.two", "Первая часть "
        + "и вторая")
    '''
    pary = dict(sobrat(obrazec))
    otkazy = []
    if pary.get("k.one") != "Привет":
        otkazy.append("простая строка не разобралась")
    if pary.get("k.two") != "Первая часть и вторая":
        otkazy.append("склейка через + не собралась: " + repr(pary.get("k.two")))
    for o in otkazy:
        print("ОТКАЗ " + o, file=sys.stderr)
    if otkazy:
        return 1
    print("collect_strings: разбор сошелся на 2 случаях")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--selftest" in args:
        raise SystemExit(selftest())
    nayden = iz_dereva()
    if "--write" in args:
        yazyki = [a for a in args[args.index("--write") + 1:] if a in TABLICY] or list(TABLICY)
        for yazyk in yazyki:
            put = TABLICY[yazyk]
            est = sushchestvuyushchie(put)
            novye = [(k, v) for k, v in sorted(nayden.items()) if k not in est]
            if not novye:
                print(f"{yazyk}: новых ключей нет")
                continue
            with open(put, "a", encoding="utf-8") as f:
                f.write("\n")
                for k, v in novye:
                    f.write(f'"{ekran(k)}" = "{ekran(v)}";\n')
            print(f"{yazyk}: дописано {len(novye)} ключей")
    else:
        for k, v in sorted(nayden.items()):
            print(f"{k}\t{v}")
