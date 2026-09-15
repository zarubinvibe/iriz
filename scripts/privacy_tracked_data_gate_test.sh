#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
gate="$repo_root/scripts/privacy_tracked_data_gate.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/smltlk-privacy-gate.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

new_repo() {
    local path="$1"
    mkdir -p "$path/Tests/fixtures"
    git -C "$path" init -q
    cp "$repo_root/Tests/fixtures/transcripts.json" "$path/Tests/fixtures/transcripts.json"
    git -C "$path" add Tests/fixtures/transcripts.json
}

expect_pass() {
    local path="$1"
    if ! bash "$gate" "$path" >/dev/null; then
        echo "privacy_tracked_data_gate_test: ожидался успех" >&2
        exit 1
    fi
}

expect_fail() {
    local path="$1"
    if bash "$gate" "$path" >/dev/null 2>&1; then
        echo "privacy_tracked_data_gate_test: ожидался отказ" >&2
        exit 1
    fi
}

clean="$tmp/clean"
new_repo "$clean"
expect_pass "$clean"

index=0
for forbidden_path in \
    03_impl/runs/generated.log \
    04_merge/diverge/report.md \
    04_merge/proof/prompts/raw.txt \
    04_merge/runs/generated.log \
    04_merge/samples/transcripts.json \
    04_merge/council/job/report.md \
    05_next/council/job/report.md \
    05_next/diverge/report.md \
    .kimi-runs/status.json \
    04_merge/BRIEF_MERGE.md \
    04_merge/EXTRACT_MAP.md \
    04_merge/PLAN_MERGE.md \
    04_merge/COUNCIL.md
do
    forbidden="$tmp/forbidden-$index"
    new_repo "$forbidden"
    mkdir -p "$forbidden/$(dirname "$forbidden_path")"
    : > "$forbidden/$forbidden_path"
    git -C "$forbidden" add -f "$forbidden_path"
    expect_fail "$forbidden"
    index=$((index + 1))
done

tampered="$tmp/tampered"
new_repo "$tampered"
sed -i.bak 's/"synthetic": true/"synthetic": false/' "$tampered/Tests/fixtures/transcripts.json"
rm "$tampered/Tests/fixtures/transcripts.json.bak"
git -C "$tampered" add Tests/fixtures/transcripts.json
expect_fail "$tampered"

missing="$tmp/missing"
mkdir -p "$missing"
git -C "$missing" init -q
expect_fail "$missing"

# LIM-05: звук и расшифровки корпуса не отслеживаются. Проба ломает вход, по
# которому судит гейт, а не сам гейт: файл появляется в индексе - гейт краснеет.
audio_index=0
for audio_path in \
    bench/corpus/01.wav \
    Tests/audio/sample.m4a \
    docs/demo.mp3 \
    05_next/proof/take.caf
do
    audio_repo="$tmp/audio-$audio_index"
    new_repo "$audio_repo"
    mkdir -p "$audio_repo/$(dirname "$audio_path")"
    : > "$audio_repo/$audio_path"
    git -C "$audio_repo" add -f "$audio_path"
    expect_fail "$audio_repo"
    audio_index=$((audio_index + 1))
done

corpus="$tmp/corpus"
new_repo "$corpus"
mkdir -p "$corpus/vendor/iriz-bench/ru"
: > "$corpus/vendor/iriz-bench/ru/01.txt"
git -C "$corpus" add -f vendor/iriz-bench/ru/01.txt
expect_fail "$corpus"

# Обратная сторона: лист фраз остается разрешенным. Фамилии в нем выдуманы,
# подтверждено владельцем 03.09.2026, и гейт не имеет права его хоронить.
phrases="$tmp/phrases"
new_repo "$phrases"
mkdir -p "$phrases/bench"
printf 'Ходатайство Сафиуллиной об отложении\n' > "$phrases/bench/phrases.ru.txt"
git -C "$phrases" add -f bench/phrases.ru.txt
expect_pass "$phrases"

echo "privacy_tracked_data_gate_test: ok"
