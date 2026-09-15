#!/usr/bin/env python3
"""Список файлов, которые уедут в публичный срез.

Отдельным прибором, а не веткой внутри проверки: границу «что публикуется»
задает .github/public-release.json, и спрашивать ее должны все, кому она нужна,
одинаково. Без списка (в уже собранном публичном дереве) публикуется все.

    scripts/publishable_files.py           список путей, по одному на строку
    scripts/publishable_files.py --selftest самопроверка сопоставления шаблонов
"""
import json
import os
import re
import subprocess
import sys


def v_regulyarku(shablon):
    """Тот же перевод глоба в регулярку, что и у публикующего прибора.

    fnmatch тут не годится: у него `*` проходит через косую черту, и
    `Sources/*` захватывал бы вложенные каталоги. Расхождение с настоящим
    срезом опаснее отсутствия проверки: она говорила бы про другое дерево.
    """
    out = []
    i = 0
    while i < len(shablon):
        c = shablon[i]
        if c == "*":
            if i + 1 < len(shablon) and shablon[i + 1] == "*":
                cherez_slesh = i + 2 < len(shablon) and shablon[i + 2] == "/"
                out.append("(?:.*/)?" if cherez_slesh else ".*")
                i += 3 if cherez_slesh else 2
                continue
            out.append("[^/]*")
            i += 1
            continue
        if c == "?":
            out.append("[^/]")
            i += 1
            continue
        out.append(re.escape(c))
        i += 1
    return re.compile("^" + "".join(out) + "$")


def podhodit(put, shablony):
    return any(v_regulyarku(sh).match(put) for sh in shablony)


def otslezhivaemye():
    out = subprocess.run(["git", "ls-files", "-z"], capture_output=True, text=True)
    puti = [p for p in out.stdout.split("\0") if p]
    if puti:
        return puti
    sobrannye = []
    for koren, katalogi, fayly in os.walk("."):
        katalogi[:] = [k for k in katalogi if k not in (".git", ".build")]
        for fayl in fayly:
            sobrannye.append(os.path.join(koren, fayl)[2:])
    return sobrannye


def publikuemye():
    puti = otslezhivaemye()
    spisok = ".github/public-release.json"
    if not os.path.exists(spisok):
        return puti
    dogovor = json.load(open(spisok, encoding="utf-8"))
    vklyucheno = dogovor.get("include", [])
    isklyucheno = dogovor.get("exclude", [])
    return [p for p in puti if podhodit(p, vklyucheno) and not podhodit(p, isklyucheno)]


def selftest():
    sluchai = [
        ("README.md", ["README.md"], True),
        ("Sources/App/main.swift", ["Sources/**"], True),
        ("Sources/App/main.swift", ["Sources/*"], False),
        (".cursor/rules/a.mdc", [".cursor/rules/*.mdc"], True),
        ("queue/GOAL.md", ["Sources/**", "README.md"], False),
        ("docs/assets/x/y.png", ["docs/assets/**"], True),
    ]
    otkazy = 0
    for put, shablony, zhdem in sluchai:
        bylo = podhodit(put, shablony)
        if bylo != zhdem:
            print(f"ОТКАЗ {put} по {shablony}: ждали {zhdem}, вышло {bylo}", file=sys.stderr)
            otkazy += 1
    if otkazy:
        return 1
    print(f"publishable_files: {len(sluchai)} случаев сопоставления сошлись")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        raise SystemExit(selftest())
    print("\n".join(publikuemye()))
