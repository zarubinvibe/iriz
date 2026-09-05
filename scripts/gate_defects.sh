#!/bin/bash
# Машинный гейт приёмки: status item, микрофон, автозапуск, свежесть установки.
set -euo pipefail
cd "$(dirname "$0")/.."

DOMAIN=ru.iriz.app
LOG="$HOME/Library/Logs/iriz-dictate.log"
STATUS="$HOME/Library/Application Support/iriz/status.json"
INSTALLED=/Applications/iriz.app/Contents/MacOS/iriz
total=4
ok=0
failed=0
no_data=0

# ПОЧЕМУ AX-зонд, а не ключ NSStatusItem Preferred Position.
# Замерено на macOS 26.5 (25F71): при заведомо СУЩЕСТВУЮЩЕМ элементе строки меню
# (AX-зонд отвечает, знак виден на скриншоте) ключ в домене так и не появляется.
# Система пишет его, видимо, только после ручного перетаскивания элемента.
# Прокси-замер невалиден — спрашиваем сам элемент, а не след от него в настройках.
if ! /usr/bin/pgrep -qx iriz; then
  echo "Элемент строки меню: НЕТ ДАННЫХ — приложение не запущено, запусти его"
  no_data=$((no_data + 1))
elif items=$(/usr/bin/osascript -e 'tell application "System Events" to tell process "iriz" to get name of every menu bar item of menu bar 2' 2>/dev/null) \
     && [ -n "$items" ]; then
  echo "Элемент строки меню: OK — AX видит его: $items"
  ok=$((ok + 1))
else
  echo "Элемент строки меню: FAIL — процесс жив, но элемента в строке меню нет"
  failed=$((failed + 1))
fi

if [ ! -f "$LOG" ]; then
  echo "Микрофон: НЕТ ДАННЫХ — замера нет, продиктуй хотя бы раз"
  no_data=$((no_data + 1))
else
  # Считаем ТОЛЬКО текущий запуск приложения. Лог накопительный: в нём лежат
  # и старые сессии до починки (там честные 5 старта / 0 остановок), и строки
  # от `swift test` — тесты пишут в тот же файл через глобальный логгер.
  # Без этой отсечки гейт остался бы красным навсегда.
  # Граница запуска — последняя строка "HotkeyListener: tap active":
  # она пишется один раз за старт приложения.
  read -r started stopped < <(/usr/bin/awk '
    /HotkeyListener: tap active/ { started = 0; stopped = 0; next }
    /engine started/ { started++ }
    /engine stopped/ { stopped++ }
    END { print started + 0, stopped + 0 }
  ' "$LOG")
  if [ "$started" -eq 0 ]; then
    echo "Микрофон: НЕТ ДАННЫХ — замера нет, продиктуй хотя бы раз"
    no_data=$((no_data + 1))
  elif [ "$started" -eq "$stopped" ]; then
    echo "Микрофон: OK — engine started=$started, engine stopped=$stopped"
    ok=$((ok + 1))
  else
    echo "Микрофон: FAIL — engine started=$started, engine stopped=$stopped"
    failed=$((failed + 1))
  fi
fi

wanted=$(/usr/bin/defaults read "$DOMAIN" ru.smltlk.launchAtLogin 2>/dev/null || printf 'missing')
registered=$(/usr/bin/plutil -extract loginItem raw -o - "$STATUS" 2>/dev/null || printf 'missing')
# ВАЖНО про $registered: это СНИМОК, сделанный приложением на последнем запуске
# (AppDelegate.writeStatusReport → status.json), а не живое состояние системы.
# После ручного `defaults write` снимок устаревает до следующего запуска приложения.
# «Переживает перезагрузку» этим гейтом не проверяется — это живой шаг владельца.
if [ "$wanted" = 1 ] && [ "$registered" = true ]; then
  echo "Автозапуск: OK — настройка=1, на последнем запуске SMAppService был зарегистрирован"
  ok=$((ok + 1))
elif [ "$wanted" = 1 ] && [ "$registered" = false ]; then
  echo "Автозапуск: FAIL — галочка включена, но на последнем запуске SMAppService не зарегистрирован"
  failed=$((failed + 1))
elif [ "$wanted" = 0 ] && [ "$registered" = true ]; then
  echo "Автозапуск: FAIL — галочка выключена, но на последнем запуске SMAppService был зарегистрирован"
  failed=$((failed + 1))
elif [ "$wanted" = 0 ] && [ "$registered" = false ]; then
  echo "Автозапуск: FAIL — автозапуск снят (настройка=0). Его надо вернуть после починки меню"
  failed=$((failed + 1))
else
  echo "Автозапуск: FAIL — не удалось прочитать настройку ($wanted) или снимок статуса ($registered)"
  failed=$((failed + 1))
fi

# Именно release: build_app.sh ставит в /Applications только .build/release/IrizApp.
# Любой debug-бинарь тут дал бы ложный FAIL — он свежее release после обычного swift build.
built=.build/release/IrizApp
built_time=0
if [ -f "$built" ]; then built_time=$(/usr/bin/stat -f %m "$built"); fi

if [ "$built_time" -eq 0 ]; then
  echo "Свежесть бинаря: НЕТ ДАННЫХ — release-сборки нет, запусти scripts/build_app.sh"
  no_data=$((no_data + 1))
elif [ ! -f "$INSTALLED" ]; then
  echo "Свежесть бинаря: FAIL — $INSTALLED не найден"
  failed=$((failed + 1))
else
  installed_time=$(/usr/bin/stat -f %m "$INSTALLED")
  if [ "$installed_time" -ge "$built_time" ]; then
    echo "Свежесть бинаря: OK — установленный бинарь не старше $built"
    ok=$((ok + 1))
  else
    echo "Свежесть бинаря: FAIL — в /Applications лежит более старая сборка, чем $built"
    failed=$((failed + 1))
  fi
fi

echo "Итог: всего=$total, OK=$ok, FAIL=$failed, НЕТ ДАННЫХ=$no_data"
if [ "$no_data" -gt 0 ]; then
  echo "ВНИМАНИЕ: приёмка НЕ пройдена — $no_data проверок без данных."
  echo "          Добери данные и прогони снова."
fi
[ "$failed" -eq 0 ] && [ "$no_data" -eq 0 ]
