#!/bin/bash
# Ищет настройки, в которые пишут, но которые никто не читает.
#
# ЗАЧЕМ. За одну ночь этот класс дефектов поймался трижды:
#   1. окно настроек писало клавиши в ключи `ru.smltlk.settings.<action>.*`,
#      которых не читал ни один участок рантайма — владелец переназначил бы
#      клавишу, и ничего не произошло;
#   2. заводской словарь замен звался только тестами, то есть в продукте
#      оставался пустым;
#   3. строка меню обещала хоткей «речь в промпт», которого не существует.
#
# Настройка, которую никто не читает, ХУЖЕ отсутствующей: она обещает и не делает.
# Гейт «swift test зелёный» этого класса не ловит — тесты проверяют то, что написано,
# а не то, что позвано. Ловит только сверка объявлений с использованием.
#
# ЧТО СЧИТАЕТ. Все ключи, объявленные как `static let name = "..."` в Sources/,
# и для каждого — сколько раз имя константы вообще используется. Ноль использований
# = мёртвая константа. Есть запись и ноль чтений = обещание без исполнения.
#
# ЧЕГО НЕ СЧИТАЕТ. Ключи, собранные из строк на ходу (интерполяцией) — их
# статически не увидеть. Если такой появится, добавь его сюда руками.
set -euo pipefail
cd "$(dirname "$0")/.."

/usr/bin/python3 - <<'PY'
import re, pathlib, sys

srcs = sorted(pathlib.Path("Sources").rglob("*.swift"))
if not srcs:
    print("audit_settings_keys: не найдено ни одного .swift в Sources/ — проверь путь")
    sys.exit(1)
blob = "\n".join(p.read_text() for p in srcs)

decl = re.compile(r'static let (\w+)\s*=\s*"([^"]+)"')
keys = {}
for m in decl.finditer(blob):
    name, key = m.group(1), m.group(2)
    # ключ настроек: либо своё пространство, либо донорский snake_case
    if key.startswith("ru.") or "_" in key:
        keys[name] = key

dead, write_only = [], []
for name, key in sorted(keys.items(), key=lambda kv: kv[1]):
    uses = len(re.findall(r"\b" + re.escape(name) + r"\b", blob)) - 1
    reads = len(re.findall(
        r"\.(?:bool|string|integer|data|object|array|stringArray|double|value)\s*\(\s*forKey:\s*[\w.]*"
        + re.escape(name), blob))
    writes = len(re.findall(
        r"\.(?:set|setValue|removeObject)\s*\([^)]*forKey:\s*[\w.]*" + re.escape(name), blob))
    if uses == 0:
        dead.append(key)
    elif writes > 0 and reads == 0:
        write_only.append(key)

print(f"audit_settings_keys: ключей объявлено {len(keys)}")

failed = 0
if dead:
    print("FAIL — мёртвые константы ключей, их никто не использует:")
    for k in dead:
        print(f"    {k}")
    failed += len(dead)
if write_only:
    print("FAIL — в эти ключи пишут, но никто не читает (обещание без исполнения):")
    for k in write_only:
        print(f"    {k}")
    failed += len(write_only)

if failed == 0:
    print("audit_settings_keys: OK — каждый ключ и читается, и используется")
sys.exit(1 if failed else 0)
PY
