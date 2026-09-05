#!/bin/bash
# Ворота двух правил хранения звука.
#
# В продукте живут два противоположных правила, и оба - решения владельца:
#
#   ДИКТОВКА   звук не сохраняется НИКОГДА. Надиктованное это черновик мысли,
#              и держать его голосом значит держать то, чего человек не просил
#              хранить.
#   ВСТРЕЧА    звук сохраняется ВМЕСТЕ с расшифровкой. Расшифровку нечем
#              сверить, а заседание это доказательство, к которому возвращаются
#              через год.
#
# Правила противоречат друг другу только на вид: у них разные поверхности.
# Опасность в том, что однажды их сольют - уборкой, обобщением, «сделаем
# единообразно». Ворота держат границу.
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0

check() {
    local rc=0

    # M01: путь диктовки не сохраняет звук. Ищем запись аудио рядом с
    # сохранением расшифровки диктовки.
    if grep -rn "DictationStore.save" Sources/ --include="*.swift" \
        | grep -iE "wav|caf|m4a|audioURL|copyItem" >/dev/null; then
        echo "M01: в пути диктовки появилось сохранение звука"
        rc=1
    fi

    # M02: у встречи сохраняются ОБА файла. Половина доказательства хуже его
    # отсутствия: она создаёт видимость.
    grep -q "let audioCopy = directory.appendingPathComponent" Sources/IrizDictate/MeetingStore.swift \
        || { echo "M02: встреча перестала сохранять звук"; rc=1; }
    grep -q "protocol.md" Sources/IrizDictate/MeetingStore.swift \
        || { echo "M02: встреча перестала сохранять расшифровку"; rc=1; }

    # M03: звук встречи КОПИРУЕТСЯ, а не переносится. Перенос означал бы, что
    # запись пропала из папки, куда её положил владелец.
    # Образец с якорем-точкой: без неё он ловит `removeItem(at: audioCopy)`,
    # где `moveItem(at: audio` лежит подстрокой. Ворота краснели на здоровом
    # дереве, а ложная тревога обесценивает красный так же, как пропуск.
    if grep -q "\.moveItem(at: audio" Sources/IrizDictate/MeetingStore.swift; then
        echo "M03: звук встречи переносится вместо копирования"
        rc=1
    fi

    # M04: дома диктовок и встреч разные. Общий каталог однажды сольют уборкой.
    grep -q '"meetings"' Sources/IrizDictate/MeetingStore.swift \
        || { echo "M04: у встреч пропал свой каталог"; rc=1; }
    return $rc
}

if [ "${1:-}" = "--selftest" ]; then
    ok=0
    if check >/dev/null; then
        echo "     OK  живое дерево принято"
    else
        echo "ПРОВАЛ: живое дерево не проходит ворота"; ok=1
    fi

    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    cp Sources/IrizDictate/MeetingStore.swift "$TMP/backup"
    sed -i '' 's|copyItem(at: audio|moveItem(at: audio|' Sources/IrizDictate/MeetingStore.swift
    if check >/dev/null; then
        echo "ПРОВАЛ: перенос оригинала не пойман"; ok=1
    else
        echo "     OK  перенос оригинала отвергнут"
    fi
    cp "$TMP/backup" Sources/IrizDictate/MeetingStore.swift

    cp Sources/IrizDictate/MeetingStore.swift "$TMP/backup2"
    sed -i '' 's|protocol.md|protokol.txt.disabled|' Sources/IrizDictate/MeetingStore.swift
    if check >/dev/null; then
        echo "ПРОВАЛ: пропажа расшифровки не поймана"; ok=1
    else
        echo "     OK  пропажа расшифровки отвергнута"
    fi
    cp "$TMP/backup2" Sources/IrizDictate/MeetingStore.swift

    [ $ok -eq 0 ] && echo "SELFTEST OK"
    exit $ok
fi

if out=$(check); then
    echo "ворота хранения встречи: чисто"
    exit 0
fi
echo "$out" >&2
echo "ВОРОТА ХРАНЕНИЯ: два правила о звуке слились" >&2
exit 1
