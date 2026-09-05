#!/usr/bin/env bash
# Установка iriz из исходников.
#
# Без флагов скрипт НИЧЕГО не собирает и ничего не ставит: он объясняет, что
# это такое, смотрит, чего не хватает на этой машине, гоняет самопроверку
# дерева и честно называет следующий шаг. Так его можно запустить, не решив
# ещё, нужен ли вам продукт.
#
#   bash install.sh          что это, чего не хватает, самопроверка
#   bash install.sh --build  собрать и положить в /Applications
#
# Коды: 0 - проверки прошли, 1 - чего-то не хватает или сборка не удалась.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

BUILD=0
[ "${1:-}" = "--build" ] && BUILD=1

printf '\n'
printf 'iriz - приложение строки меню для macOS.\n'
printf 'Чинит раскладку, пишет текст под диктовку прямо на этом Маке и превращает\n'
printf 'надиктовку в готовое задание для агента.\n\n'

missing=0
need() { # need <команда> <зачем>
  if command -v "$1" >/dev/null 2>&1; then
    printf '  есть   %-8s %s\n' "$1" "$2"
  else
    printf '  НЕТ    %-8s %s\n' "$1" "$2"
    missing=$((missing + 1))
  fi
}

printf 'Что нужно на машине:\n'
need swift "сборка приложения (Xcode или Command Line Tools)"
need python3 "самопроверка дерева"
need git "обновления"

os=$(sw_vers -productVersion 2>/dev/null || echo "не macOS")
case "$os" in
  1[4-9].*|2[0-9].*) printf '  есть   macOS    %s\n' "$os" ;;
  *) printf '  НЕТ    macOS    нужна 14 или новее, у вас: %s\n' "$os"; missing=$((missing + 1)) ;;
esac
printf '\n'

bash scripts/selfcheck.sh --selftest || exit 1

if [ "$missing" -gt 0 ]; then
  printf 'Не хватает %d пунктов из списка выше. Поставьте их и запустите снова.\n\n' "$missing"
  exit 1
fi

if [ "$BUILD" -eq 0 ]; then
  printf 'Всё на месте. Собрать и поставить:\n\n    bash install.sh --build\n\n'
  printf 'Готовый образ без сборки лежит в разделе Releases на GitHub.\n\n'
  exit 0
fi

printf 'Собираю. Первая сборка тянет зависимости и занимает несколько минут.\n\n'
bash scripts/build_app.sh || { printf '\nСборка не удалась.\n\n'; exit 1; }
printf '\nГотово. Значок появится в строке меню.\n'
printf 'Модель распознавания приложение скачает само на шаге знакомства.\n\n'
