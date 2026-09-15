#!/bin/bash
# Регрессия: пользователю install.sh Node.js не нужен, а дрейф релизных
# заметок при наличии Node.js остаётся отказом.
set -euo pipefail
case "${1:-}" in ""|--selftest) ;; *) echo "usage: selfcheck_test.sh [--selftest]" >&2; exit 2 ;; esac

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/iriz-selfcheck-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/repo"
mkdir -p "$fixture/scripts" "$fixture/Sources/App"
cp "$repo_root/scripts/selfcheck.sh" "$repo_root/scripts/publishable_files.py" "$fixture/scripts/"
printf '.target(name: "App")\n' > "$fixture/Package.swift"
printf '[Русский](README.ru.md) [简体中文](README.zh.md)\n' > "$fixture/README.md"
printf '[English](README.md)\n' > "$fixture/README.ru.md"
printf '[English](README.md)\n' > "$fixture/README.zh.md"

status=0
(cd "$fixture" && env -i PATH=/usr/bin:/bin LANG=C /bin/bash scripts/selfcheck.sh --selftest) \
  > "$test_root/no-node.out" 2>&1 || status=$?
[ "$status" -eq 0 ] || { cat "$test_root/no-node.out" >&2; exit 1; }
grep -Fq "проверка пропущена без Node.js" "$test_root/no-node.out" \
  || { cat "$test_root/no-node.out" >&2; exit 1; }

mkdir -p "$test_root/bin"
printf '#!/bin/sh\ncase "$*" in *--selftest*) exit 0 ;; *) exit 1 ;; esac\n' > "$test_root/bin/node"
chmod +x "$test_root/bin/node"
status=0
(cd "$fixture" && env -i PATH="$test_root/bin:/usr/bin:/bin" LANG=C \
  /bin/bash scripts/selfcheck.sh --selftest) > "$test_root/stale.out" 2>&1 || status=$?
[ "$status" -eq 1 ] || { cat "$test_root/stale.out" >&2; exit 1; }
grep -Fq "GitHub Release notes устарели" "$test_root/stale.out" \
  || { cat "$test_root/stale.out" >&2; exit 1; }

echo "selfcheck_test: OK"
