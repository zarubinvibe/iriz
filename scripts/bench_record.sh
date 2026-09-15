#!/bin/bash
# Запись эталонного корпуса для замера WER (волна 1, REQ-01..REQ-03, REQ-10).
#
# Показывает фразу, пишет её голосом в WAV 16 кГц моно - тот же вход, что получает
# движок в живой диктовке. Эталон = сама фраза, поэтому расшифровки руками править
# не надо: читаешь то, что написано.
#
# Корпус лежит ВНЕ дерева git (LIM-02: голос владельца в репозиторий не коммитится).
# Прогон можно прерывать: уже записанные фразы пропускаются.
set -uo pipefail

CORPUS="${IRIZ_BENCH_DIR:-$HOME/Library/Application Support/iriz-bench}"
DEV="${IRIZ_BENCH_DEVICE:-1}"     # ffmpeg -f avfoundation -list_devices true -i ""
LANG_CODE="${1:-ru}"
HOME_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HOME_DIR/bench/phrases.$LANG_CODE.txt"

[ -f "$SRC" ] || { echo "нет файла фраз: $SRC" >&2; exit 2; }
command -v ffmpeg >/dev/null || { echo "нужен ffmpeg" >&2; exit 2; }

mkdir -p "$CORPUS/$LANG_CODE" && chmod 700 "$CORPUS" "$CORPUS/$LANG_CODE"

# Свой список фраз кладётся рядом с корпусом и имеет приоритет: туда можно вписать
# настоящие фамилии доверителей, и они не попадут ни в репозиторий, ни в мои файлы.
MINE="$CORPUS/phrases.$LANG_CODE.txt"
[ -f "$MINE" ] && SRC="$MINE"

# bash на macOS - 3.2, mapfile там нет. Читаем переносимо.
PHRASES=()
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  PHRASES+=("$line")
done < "$SRC"
TOTAL=${#PHRASES[@]}
echo "корпус: $CORPUS/$LANG_CODE   фраз: $TOTAL   микрофон: устройство $DEV"
echo "Enter - начать запись, потом Enter - остановить. s - пропустить, q - выйти."
echo

DONE=0
for i in "${!PHRASES[@]}"; do
  n=$(printf "%02d" $((i+1)))
  wav="$CORPUS/$LANG_CODE/$n.wav"
  txt="$CORPUS/$LANG_CODE/$n.txt"
  if [ -f "$wav" ]; then DONE=$((DONE+1)); continue; fi

  printf '\n[%s/%d] %s\n' "$n" "$TOTAL" "${PHRASES[$i]}"
  read -r -p "  Enter=писать  s=пропустить  q=выход > " key </dev/tty
  case "$key" in
    q|Q) echo "выход. записано $DONE из $TOTAL"; exit 0 ;;
    s|S) continue ;;
  esac

  ffmpeg -hide_banner -loglevel error -nostdin -f avfoundation -i ":$DEV" \
         -ar 16000 -ac 1 -y "$wav" &
  pid=$!
  sleep 0.4
  read -r -p "  ● пишу... Enter = стоп > " _ </dev/tty
  kill -INT "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  if [ ! -s "$wav" ]; then
    echo "  ПУСТО. Скорее всего терминалу не дано разрешение на микрофон:"
    echo "  Системные настройки > Конфиденциальность и безопасность > Микрофон."
    rm -f "$wav"; continue
  fi
  printf '%s\n' "${PHRASES[$i]}" > "$txt"
  chmod 600 "$wav" "$txt"
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$wav" 2>/dev/null | cut -c1-4)
  echo "  ✓ ${dur}s"
  DONE=$((DONE+1))
done

echo
echo "готово: $DONE из $TOTAL. Корпус: $CORPUS/$LANG_CODE"
