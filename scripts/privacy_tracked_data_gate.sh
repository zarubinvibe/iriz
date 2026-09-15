#!/bin/bash
# Fail-closed gate: runtime/generated corpus paths must never be tracked.
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

python3 - "$repo_root" <<'PY'
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

# Перепинено 11.08.2026 после privacy-review: из заводского словаря убраны
# записи с именами частных проектов владельца, и четыре записи корпуса, которые
# их проверяли, заменены на общедоступные. Содержимое перечитано глазами.
#
# Перепинено 05.09.2026. Ворота стояли красными с 03.09: корпус тронул
# переименование продукта, а пин остался прежним. Содержимое перечитано целиком
# заново - двенадцать синтетических записей, живой речи и личных данных нет,
# изменилось ровно одно слово в трёх ожидаемых строках: «Ирида» -> «iriz».
EXPECTED_FIXTURE_SHA256 = "2dc5e8d5619edd68a25d918b28462f393d6cdedb26ab4a9e383e01e75fa6b2e1"
FIXTURE = "Tests/fixtures/transcripts.json"
FORBIDDEN_PREFIXES = (
    "03_impl/runs/",
    "04_merge/diverge/",
    "04_merge/proof/prompts/",
    "04_merge/runs/",
    "04_merge/samples/",
    "04_merge/council/",
    "05_next/council/",
    "05_next/diverge/",
    ".kimi-runs/",
)
# Волна 1 (03.09.2026) завела корпус надиктовок владельца. LIM-05 цели: звук и
# расшифровки корпуса в репозиторий не попадают. Корпус лежит ВНЕ дома, в
# ~/Library/Application Support/iriz-bench с правами 0700, поэтому обход рабочего
# дерева (find . -name '*.wav') тавтологичен и зелен всегда - судить надо по
# git ls-files. Лист фраз bench/phrases.*.txt остается: фамилии в нем выдуманы,
# подтверждено владельцем 03.09.2026.
AUDIO_SUFFIXES = (".wav", ".m4a", ".mp3", ".aiff", ".aif", ".caf", ".flac", ".ogg")
CORPUS_MARKER = "iriz-bench"
FORBIDDEN_PATHS = {
    "04_merge/BRIEF_MERGE.md",
    "04_merge/COUNCIL.md",
    "04_merge/EXTRACT_MAP.md",
    "04_merge/PLAN_MERGE.md",
}
EXPECTED_ENTRY_KEYS = {
    "id",
    "synthetic",
    "text",
    "expectedText",
    "expectedAppliedCorrections",
}
SYNTHETIC_ID = re.compile(r"synthetic-(?:correction|trap|idempotent)-[0-9]{2}\Z")


def fail(message: str) -> None:
    print(f"privacy_tracked_data_gate: {message}", file=sys.stderr)
    raise SystemExit(1)


root = Path(sys.argv[1]).resolve()
try:
    top = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    ).stdout.strip()
except (OSError, subprocess.CalledProcessError):
    fail("не найден Git-репозиторий")

if Path(top).resolve() != root:
    fail("проверять нужно корень Git-репозитория")

try:
    raw_paths = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout
except (OSError, subprocess.CalledProcessError):
    fail("не удалось получить список tracked-файлов")

tracked = {
    item.decode("utf-8", errors="surrogateescape")
    for item in raw_paths.split(b"\0")
    if item
}
forbidden = sorted(
    path
    for path in tracked
    if path in FORBIDDEN_PATHS
    or any(path.startswith(prefix) for prefix in FORBIDDEN_PREFIXES)
)
if forbidden:
    print("privacy_tracked_data_gate: запрещённые tracked-пути:", file=sys.stderr)
    for path in forbidden:
        print(f"  {path}", file=sys.stderr)
    raise SystemExit(1)

audio = sorted(path for path in tracked if path.lower().endswith(AUDIO_SUFFIXES))
if audio:
    print("privacy_tracked_data_gate: звук в tracked-файлах (LIM-05):", file=sys.stderr)
    for path in audio:
        print(f"  {path}", file=sys.stderr)
    raise SystemExit(1)

corpus = sorted(path for path in tracked if CORPUS_MARKER in path)
if corpus:
    print("privacy_tracked_data_gate: расшифровки корпуса в tracked-файлах (LIM-05):", file=sys.stderr)
    for path in corpus:
        print(f"  {path}", file=sys.stderr)
    raise SystemExit(1)

if FIXTURE not in tracked:
    fail("контрольная синтетическая fixture отсутствует в tracked-файлах")

fixture_path = root / FIXTURE
try:
    fixture_bytes = fixture_path.read_bytes()
except OSError:
    fail("контрольная синтетическая fixture не читается")

if hashlib.sha256(fixture_bytes).hexdigest() != EXPECTED_FIXTURE_SHA256:
    fail("контрольная синтетическая fixture изменилась без privacy-review")

try:
    entries = json.loads(fixture_bytes)
except (UnicodeDecodeError, json.JSONDecodeError):
    fail("контрольная синтетическая fixture имеет неверный JSON")

if not isinstance(entries, list) or len(entries) != 12:
    fail("контрольная синтетическая fixture имеет неверный размер")

seen_ids: set[str] = set()
for index, entry in enumerate(entries):
    if not isinstance(entry, dict) or set(entry) != EXPECTED_ENTRY_KEYS:
        fail(f"запись {index} имеет неверную схему")
    entry_id = entry["id"]
    if type(entry_id) is not str or not SYNTHETIC_ID.fullmatch(entry_id) or entry_id in seen_ids:
        fail(f"запись {index} имеет неверный синтетический ID")
    seen_ids.add(entry_id)
    if entry["synthetic"] is not True:
        fail(f"запись {index} не помечена как синтетическая")
    for key in ("text", "expectedText"):
        value = entry[key]
        if type(value) is not str or not value or len(value) > 240:
            fail(f"запись {index} имеет неверное поле {key}")
        if any(ord(character) < 32 and character not in "\t\n" for character in value):
            fail(f"запись {index} содержит управляющий символ")
    count = entry["expectedAppliedCorrections"]
    if type(count) is not int or not 0 <= count <= 27:
        fail(f"запись {index} имеет неверный счётчик замен")

print("privacy_tracked_data_gate: ok")
PY
