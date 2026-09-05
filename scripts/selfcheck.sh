#!/usr/bin/env bash
# Самопроверка дерева: то, что можно доказать без сборки и без сети.
#
# Зачем такая. Публичное дерево проверяется на ЧУЖОЙ машине, где нет ни
# зависимостей SwiftPM, ни сети, ни Xcode. Проверка, которая требует всего
# этого, на чужой машине просто падает и ничего не доказывает. Здесь проверяется
# то, что обязано быть верным в самом дереве: манифесты читаются, цели сборки
# указывают на существующие каталоги, страницы на трёх языках ссылаются друг на
# друга, а абсолютных путей владельца в тексте нет.
#
# Коды: 0 - всё сошлось, 1 - есть отказ.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  ОТКАЗ %s\n' "$1" >&2; fails=$((fails + 1)); }

printf '\n=== iriz: самопроверка дерева ===\n\n'

# 1. Цели сборки существуют на диске.
missing_targets=$(python3 - <<'PY'
import re, pathlib
source = pathlib.Path("Package.swift").read_text(encoding="utf-8")
roots = [pathlib.Path("Sources"), pathlib.Path("Tests")]
missing = []
# Цель может нести явный `path:` - тогда каталог ищется по нему, а не по имени.
# Без этого проверка врала на SettingsPreview, который лежит внутри чужой цели.
for block in re.split(r'(?=\.(?:target|executableTarget|testTarget)\()', source):
    name = re.search(r'name:\s*"([^"]+)"', block)
    if not name:
        continue
    explicit = re.search(r'path:\s*"([^"]+)"', block)
    if explicit:
        if not pathlib.Path(explicit.group(1)).is_dir():
            missing.append(name.group(1))
    elif not any((root / name.group(1)).is_dir() for root in roots):
        missing.append(name.group(1))
print("\n".join(missing))
PY
)
if [ -z "$missing_targets" ]; then
  ok "цели Package.swift лежат на диске"
else
  fail "цели без каталога: $(printf '%s' "$missing_targets" | tr '\n' ' ')"
fi

# 2. Манифесты читаются.
for file in .github/pantheon.json .github/family-page.json .entire/settings.json Package.resolved; do
  [ -f "$file" ] || continue
  if python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$file" 2>/dev/null; then
    ok "$file читается"
  else
    fail "$file не разбирается как JSON"
  fi
done

# 3. Три языка на месте и ссылаются друг на друга.
for file in README.md README.ru.md README.zh.md; do
  [ -f "$file" ] || { fail "нет $file"; continue; }
done
if [ -f README.md ] && [ -f README.ru.md ] && [ -f README.zh.md ]; then
  crossed=1
  grep -q "README.ru.md" README.md || crossed=0
  grep -q "README.zh.md" README.md || crossed=0
  grep -q "README.md"    README.ru.md || crossed=0
  grep -q "README.md"    README.zh.md || crossed=0
  [ "$crossed" -eq 1 ] && ok "страницы на трёх языках связаны" || fail "страницы языков не ссылаются друг на друга"
fi

# 4. Абсолютных путей владельца нет В ТОМ, ЧТО ПУБЛИКУЕТСЯ.
#
# Проверять все дерево нельзя: приватный дом законно держит рабочие записи с
# путями владельца, и такая проверка краснела бы на них вечно. Границу задает
# белый список среза, и спрашивает ее отдельный прибор - тот же, что у
# публикации, с той же семантикой шаблонов.
naydeno=0
while IFS= read -r put; do
  [ -n "$put" ] || continue
  case "$put" in scripts/selfcheck.sh|scripts/publishable_files.py) continue ;; esac
  [ -f "$put" ] || continue
  if grep -Iq -E '/(Users|home)/[a-zA-Z0-9._-]+/' "$put" 2>/dev/null; then
    printf '  путь владельца в %s\n' "$put" >&2
    naydeno=$((naydeno + 1))
  fi
done < <(python3 scripts/publishable_files.py)
if [ "$naydeno" -eq 0 ]; then
  ok "в публикуемых файлах абсолютных путей нет"
else
  fail "абсолютные пути домашнего каталога в $naydeno публикуемых файлах"
fi

# 5. Права на исполнение у скриптов, которые зовут снаружи.
for script in install.sh scripts/build_app.sh; do
  [ -f "$script" ] || continue
  [ -r "$script" ] && ok "$script читается" || fail "$script не читается"
done

printf '\nотказов: %d\n\n' "$fails"
[ "$fails" -eq 0 ]
