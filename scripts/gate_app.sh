#!/bin/bash
# Гейт этапа 5: собрать, подписать, установить, запустить через open и проверить,
# что приложение само сообщило в status.json о выданных разрешениях и автозапуске.
set -e
bash scripts/build_app.sh
APP=/Applications/iriz.app
codesign -dv --verbose=2 "$APP" 2>&1 | grep -q 'smltlk-selfsign'
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'com.apple.security.device.audio-input'
codesign -dv --verbose=2 "$APP" 2>&1 | grep -q 'flags=.*runtime'
STATUS="$HOME/Library/Application Support/iriz/status.json"
# Свежий запуск: иначе open активирует старый процесс и status.json не перепишется.
pkill -x iriz 2>/dev/null || true
sleep 1
rm -f "$STATUS"
open "$APP"
for _ in $(seq 1 20); do [ -f "$STATUS" ] && break; sleep 0.5; done
cat "$STATUS"
pgrep -x iriz > /dev/null
python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d['ax'] and d['listen'] and d['loginItem'] else 1)" "$STATUS"
