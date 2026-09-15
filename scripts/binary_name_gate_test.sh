#!/bin/bash
# Тест ворот живого адреса на враждебном входе: они обязаны ловить ровно тот
# дефект, ради которого написаны, и не краснеть на законном.
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
GATE="$DIR/binary_name_gate.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/scripts"
cat > "$WORK/scripts/build_app.sh" <<'B'
APP=/Applications/iriz.app
cp .build/release/IrizApp "$APP/Contents/MacOS/iriz"
B
fails=0
run() { bash "$GATE" "$WORK" >"$WORK/out" 2>&1; echo $?; }
check() { # <ожидание pass|fail> <имя>
  local want=$1 name=$2 rc; rc=$(run)
  if [ "$want" = pass ] && [ "$rc" -ne 0 ]; then echo "ПРОВАЛ: $name - ждали успех"; cat "$WORK/out"; fails=$((fails+1));
  elif [ "$want" = fail ] && [ "$rc" -eq 0 ]; then echo "ПРОВАЛ: $name - ждали отказ, ворота смолчали"; fails=$((fails+1));
  else echo "ок: $name"; fi
}

: > "$WORK/scripts/probe.sh"
check pass "чистое дерево"

echo 'pgrep -qx smltlk' > "$WORK/scripts/probe.sh"
check fail "pgrep на мёртвое имя процесса"

echo 'pkill -x smltlk' > "$WORK/scripts/probe.sh"
check fail "pkill на мёртвое имя процесса"

printf '%s\n' 'osascript -e '"'"'tell application "System Events" to tell process "smltlk" to get name'"'"'' > "$WORK/scripts/probe.sh"
check fail "osascript на мёртвый процесс"

echo 'APP2=/Applications/smltlk.app' > "$WORK/scripts/probe.sh"
check fail "путь к несуществующему бандлу"

echo '# снимает карантин с /Applications/smltlk.app - так было до переименования' > "$WORK/scripts/probe.sh"
check pass "комментарий про старое имя адресом не является"

echo 'pgrep -qf "smltlk transcribe"' > "$WORK/scripts/probe.sh"
check pass "pgrep -f матчит командную строку, имя процесса тут ни при чём"

printf 'pgrep -qx iriz\npkill -x iriz\nAPP2=/Applications/iriz.app\n' > "$WORK/scripts/probe.sh"
check pass "живые адреса"

[ "$fails" -eq 0 ] && echo "binary_name_gate_test: OK" || { echo "binary_name_gate_test: провалов $fails"; exit 1; }
