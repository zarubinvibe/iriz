#!/bin/bash
# Враждебная проба ворот единственного адреса.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
GATE="$DIR/support_path_gate.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/IrizCore" "$WORK/Sources/Other"
cat > "$WORK/Sources/IrizCore/PrivateFiles.swift" <<'SWIFT'
public func irizApplicationSupportDirectoryURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(IRIZ_PRIVATE_ROOT_NAME, isDirectory: true)
}
SWIFT
fails=0

: > "$WORK/Sources/Other/Clean.swift"
bash "$GATE" "$WORK" >/dev/null 2>&1 || { echo "ПРОВАЛ: чистое дерево покраснело"; fails=$((fails+1)); }

cat > "$WORK/Sources/Other/Clean.swift" <<'SWIFT'
let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("iriz", isDirectory: true)
SWIFT
bash "$GATE" "$WORK" >/dev/null 2>&1 && { echo "ПРОВАЛ: пропущена вторая сборка пути"; fails=$((fails+1)); } || echo "ок: вторая сборка пути поймана"

cat > "$WORK/Sources/Other/Clean.swift" <<'SWIFT'
let dir = irizApplicationSupportDirectoryURL().appendingPathComponent("dictations")
SWIFT
bash "$GATE" "$WORK" >/dev/null 2>&1 || { echo "ПРОВАЛ: законное обращение через функцию покраснело"; fails=$((fails+1)); }

[ "$fails" -eq 0 ] && echo "support_path_gate_test: OK" || { echo "провалов $fails"; exit 1; }
