#!/bin/bash
# Локальная проверка сборщика: Swift, подпись, DMG и сеть заменены командами-заглушками.
# Запуск: bash scripts/make_release_test.sh
set -euo pipefail
case "${1:-}" in ""|--selftest) ;; *) echo "usage: make_release_test.sh [--selftest]" >&2; exit 2 ;; esac

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
mkdir -p "$repo_root/.build"
test_root="$(mktemp -d "$repo_root/.build/make-release-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
real_python="$(command -v python3)"
mkdir -p "$test_root/bin"

# ponytail: один диспетчер вместо библиотеки моков; настоящий DMG проверяет macOS CI.
cat > "$test_root/bin/stub" <<'STUB'
#!/bin/bash
set -euo pipefail
name="$(basename "$0")"
printf '%s' "$name" >> "$TEST_TRACE"
printf ' <%s>' "$@" >> "$TEST_TRACE"
printf '\n' >> "$TEST_TRACE"
deny() { printf 'forbidden test command: %s %s\n' "$name" "$*" >&2; exit 97; }
case "$name" in
  swift)
    scratch='' archs='' show=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --scratch-path) scratch="$2"; shift ;;
        --arch) archs="${archs:+$archs }$2"; shift ;;
        --show-bin-path) show=1 ;;
      esac
      shift
    done
    [ -n "$scratch" ] || deny 'swift without scratch-path'
    bin="$scratch/release"
    if [ "$show" = 1 ]; then printf '%s\n' "$bin"; exit; fi
    mkdir -p "$bin/whisper.framework"
    printf '%s\n' "$archs" > "$bin/IrizApp"
    chmod +x "$bin/IrizApp"
    framework_archs="$archs"
    case "${TEST_FAULT:-}" in
      framework-arm64) framework_archs='x86_64' ;;
      framework-universal) framework_archs='arm64' ;;
    esac
    printf '%s\n' "$framework_archs" > "$bin/whisper.framework/whisper"
    chmod +x "$bin/whisper.framework/whisper"
    if [ "${TEST_FAULT:-}" != missing-bundle ]; then
      for locale in ru en zh-hans; do
        if [ "${TEST_FAULT:-}" = missing-locale ] && [ "$locale" = zh-hans ]; then continue; fi
        resource="$bin/IrizApp_IrizCore.bundle/$locale.lproj"
        mkdir -p "$resource"
        printf '"hello" = "fixture";\n' > "$resource/Localizable.strings"
      done
    fi
    ;;
  lipo)
    [ "$1" = -archs ] || deny "$@"
    if [ "${TEST_FAULT:-}" = mounted-arch ] && [[ "$2" = */mount.*/iriz.app/Contents/MacOS/iriz ]]; then
      : > "$TEST_CASE_ROOT/injected-fault"
      printf 'x86_64\n'
      exit
    fi
    sed -n '1p' "$2"
    ;;
  vtool)
    target=app platform=MACOS minos=14.0
    case "${!#}" in */whisper.framework/*) target=framework ;; esac
    case "${TEST_FAULT:-}" in
      "$target-minos-missing") exit 0 ;;
      "$target-platform-ios") platform=IOS ;;
      "$target-minos-high") minos=14.1 ;;
    esac
    for arch in $(sed -n '1p' "${!#}"); do
      printf '%s (architecture %s):\n    platform %s\n       minos %s\n         sdk 14.0\n' "${!#}" "$arch" "$platform" "$minos"
    done
    ;;
  otool)
    case "$1" in
      -L) printf '%s:\n\t@rpath/whisper.framework/whisper (compatibility version 1.0.0, current version 1.0.0)\n' "${!#}" ;;
      -l)
        case "${TEST_FAULT:-}" in rpath-install|rpath-noop) exit 0 ;; esac
        if [ "${TEST_FAULT:-}" = rpath-prefix ]; then
          printf '          cmd LC_RPATH\n         path @executable_path/../FrameworksExtra (offset 12)\n'
          exit
        fi
        printf '          cmd LC_RPATH\n         path @executable_path/../Frameworks (offset 12)\n'
        ;;
      *) deny "$@" ;;
    esac
    ;;
  hdiutil)
    operation="$1"; shift
    case "$operation" in
      create)
        source='' output="${!#}"
        while [ "$#" -gt 0 ]; do
          case "$1" in -srcfolder) source="$2"; shift ;; -o) output="$2"; shift ;; esac
          shift
        done
        [ -d "$source" ] || deny 'missing source folder'
        [ -x "$source/iriz.app/Contents/MacOS/iriz" ] || deny 'missing app executable'
        [ "$(readlink "$source/Applications")" = /Applications ] || deny 'invalid Applications alias'
        for locale in ru en zh-hans; do
          [ -f "$source/iriz.app/Contents/Resources/IrizApp_IrizCore.bundle/$locale.lproj/Localizable.strings" ] \
            || deny "resource was not copied: $locale"
        done
        printf '%s\n' "$source" > "$output"
        ;;
      convert)
        source="$1"; shift; output=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = -o ]; then output="$2"; shift; fi
          shift
        done
        cp "$source" "$output"
        ;;
      verify)
        [ -f "$1" ] || deny 'missing DMG'
        if [ "${TEST_FAULT:-}" = dmg-verify ]; then exit 1; fi
        ;;
      attach)
        dmg="$1"; shift; mount=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = -mountpoint ]; then mount="$2"; shift; fi
          shift
        done
        case "$mount" in "$TEST_CASE_ROOT"/*) ;; *) deny "mount outside sandbox: $mount" ;; esac
        mkdir -p "$mount"
        cp -R "$(sed -n '1p' "$dmg")/." "$mount/"
        printf '%s\n' "$mount" > "$TEST_CASE_ROOT/owned-mount"
        printf '<?xml version="1.0"?><plist version="1.0"><dict><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/disk99</string><key>mount-point</key><string>%s</string></dict></array></dict></plist>\n' "$mount"
        ;;
      detach)
        for arg in "$@"; do [ "$arg" != -force ] || deny 'forced detach'; done
        [ -f "$TEST_CASE_ROOT/owned-mount" ] || deny 'detach without owned mount'
        owned="$(sed -n '1p' "$TEST_CASE_ROOT/owned-mount")"
        [ "$1" = "$owned" ] || [ "$1" = /dev/disk99 ] || deny 'foreign mount'
        printf '%s\n' "$owned" > "$TEST_CASE_ROOT/detached-mount"
        ;;
      *) deny "$operation" ;;
    esac
    ;;
  codesign)
    if [ "${TEST_FAULT:-}" = mounted-signature ] && [ "$1" = --verify ] && [[ "${!#}" = */mount.*/iriz.app ]]; then
      : > "$TEST_CASE_ROOT/injected-fault"
      exit 1
    fi
    if [ "${TEST_FAULT:-}" = dmg-anchor ] && [[ "$*" = *'-R=anchor apple generic'* ]] && [[ "${!#}" = *.dmg ]]; then
      : > "$TEST_CASE_ROOT/injected-fault"
      exit 1
    fi
    ;;
  security|xcrun|ditto|spctl)
    [ "${TEST_NOTARY:-}" = 1 ] && [ "${IRIZ_NOTARY_PROFILE:-}" = fixture ] \
      && [ "${SMLTLK_SIGN_IDENTITY:-}" = 'Developer ID Application: Fixture (TEST123)' ] || deny "$@"
    case "$name" in
      security)
        [ "$*" = 'find-identity -v -p codesigning' ] || deny "$@"
        printf '1) 0123456789012345678901234567890123456789 "Developer ID Application: Fixture (TEST123)"\n'
        ;;
      xcrun)
        case "$1 $2" in
          'notarytool history') [ "$*" = 'notarytool history --keychain-profile fixture' ] || deny "$@" ;;
          'notarytool submit')
            [ "$#" = 6 ] && [ "$4 $5 $6" = '--keychain-profile fixture --wait' ] || deny "$@"
            case "$3" in "$TEST_CASE_ROOT"/*.zip|"$TEST_CASE_ROOT"/*.dmg) ;; *) deny "$@" ;; esac
            [ -f "$3" ] || deny 'missing notary payload'
            ;;
          'stapler staple'|'stapler validate')
            [ "$#" = 3 ] || deny "$@"
            case "$3" in "$TEST_CASE_ROOT"/*.app|"$TEST_CASE_ROOT"/*.dmg) ;; *) deny "$@" ;; esac
            [ -e "$3" ] || deny 'missing stapler target'
            ;;
          *) deny "$@" ;;
        esac
        ;;
      ditto)
        [ "$#" = 5 ] && [ "$1 $2 $3" = '-c -k --keepParent' ] && [ -d "$4" ] || deny "$@"
        case "$5" in "$TEST_CASE_ROOT"/*.zip) ;; *) deny "$@" ;; esac
        printf '%s\n' "$4" > "$5"
        ;;
      spctl)
        [ "$#" = 5 ] && [ "$1 $2 $3 $4" = '-a -vv -t exec' ] || deny "$@"
        case "$5" in "$TEST_CASE_ROOT"/*.app) ;; *) deny "$@" ;; esac
        ;;
    esac
    ;;
  install_name_tool) if [ "${TEST_FAULT:-}" = rpath-install ]; then exit 1; fi ;;
  plutil) ;;
  git)
    case "$*" in
      *rev-parse*HEAD*) printf '0123456789012345678901234567890123456789\n' ;;
      *status*|*diff*) ;;
      *) deny "$@" ;;
    esac
    ;;
  python3)
    case "$*" in *render_dmg_background*|*PIL*) deny 'Pillow in headless build' ;; esac
    exec "$TEST_REAL_PYTHON" "$@"
    ;;
  cp|mv|rm|mkdir|touch|ln)
    # Единственный разрешённый /Applications аргумент: цель ссылки внутри DMG.
    for arg in "$@"; do
      case "$arg" in
        /Applications|/Applications/*|/Volumes|/Volumes/*)
          if [ "$name" = ln ] && [ "$arg" = /Applications ] && [ "$1" = -s ]; then continue; fi
          deny "system write: $arg"
          ;;
      esac
    done
    command -p "$name" "$@"
    ;;
  *) deny "$@" ;;
esac
STUB
chmod +x "$test_root/bin/stub"
for command in swift lipo vtool otool hdiutil codesign install_name_tool plutil git python3 \
  security xcrun osascript tiffutil curl wget open killall pkill kill ditto spctl \
  cp mv rm mkdir touch ln; do
  ln -s stub "$test_root/bin/$command"
done
cat > "$test_root/no-kill.sh" <<'STUB'
kill() { printf 'forbidden builtin kill\n' >> "$TEST_TRACE"; return 97; }
STUB

checks=0
new_case() {
  case_root="$test_root/case-$checks with space"
  mkdir -p "$case_root/scripts" "$case_root/release/dist" "$case_root/.build"
  cp "$repo_root/scripts/make_release.sh" "$case_root/scripts/"
  printf '1.2.3\n' > "$case_root/RELEASE_VERSION"
  printf 'previous release\n' > "$case_root/release/dist/previous.txt"
  for artifact in iriz-1.2.3-arm64.dmg iriz-macos-arm64.dmg release-manifest.json SHA256SUMS.txt; do
    cp "$case_root/release/dist/previous.txt" "$case_root/release/dist/$artifact"
  done
  printf 'keep source\n' > "$case_root/source-sentinel"
  printf 'icon\n' > "$case_root/.build/AppIcon.icns"
  printf '<plist version="1.0"><dict/></plist>\n' > "$case_root/entitlements.plist"
  cp "$case_root/entitlements.plist" "$case_root/entitlements-notarized.plist"
  cat > "$case_root/scripts/render_marks.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
mkdir -p .build
printf 'fixture icon\n' > .build/AppIcon.icns
STUB
  : > "$case_root/trace"
}

run_release() {
  status=0
  env -i PATH="$test_root/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="$case_root" LANG=en_US.UTF-8 \
    BASH_ENV="$test_root/no-kill.sh" TEST_CASE_ROOT="$case_root" \
    TEST_TRACE="$case_root/trace" TEST_REAL_PYTHON="$real_python" \
    SMLTLK_SIGN_IDENTITY=- IRIZ_DMG_HEADLESS=1 "$@" \
    /bin/bash "$case_root/scripts/make_release.sh" > "$case_root/output" 2>&1 || status=$?
}

fail() {
  printf 'make_release_test: %s (exit %s)\n' "$*" "$status" >&2
  sed -n '1,160p' "$case_root/output" >&2
  exit 1
}

expect_fail() {
  local label="$1" pattern="$2"; shift 2
  run_release "$@"
  [ "$status" = 1 ] || fail "$label: ожидался отказ 1"
  grep -Eiq "^make_release: $pattern" "$case_root/output" || fail "$label: причина отказа не совпала"
  [ -f "$case_root/release/dist/previous.txt" ] || fail "$label: повреждён прошлый выпуск"
  for artifact in iriz-1.2.3-arm64.dmg iriz-macos-arm64.dmg release-manifest.json SHA256SUMS.txt; do
    cmp -s "$case_root/release/dist/previous.txt" "$case_root/release/dist/$artifact" \
      || fail "$label: прошлый $artifact перезаписан до приёмки"
  done
  [ -f "$case_root/source-sentinel" ] || fail "$label: повреждён исходник"
  if grep -Eq '^(hdiutil|codesign|swift) ' "$case_root/trace" && [ "$label" = guard ]; then
    fail 'опасный ввод дошёл до сборки'
  fi
  checks=$((checks + 1))
}

expect_pass() {
  local notary=0 argument
  for argument in "$@"; do if [ "$argument" = TEST_NOTARY=1 ]; then notary=1; fi; done
  run_release "$@"
  [ "$status" = 0 ] || fail 'ожидалась успешная сборка'
  if grep -Eq '^(osascript|tiffutil|curl|wget|open|killall|pkill|kill|forbidden) ' "$case_root/trace"; then
    fail 'headless вызвал графику, сеть или kill'
  fi
  if [ "$notary" = 0 ] && grep -Eq '^(security|xcrun|ditto|spctl) ' "$case_root/trace"; then
    fail 'ad-hoc вызвал связку ключей или нотаризацию'
  fi
  [ -f "$case_root/source-sentinel" ] || fail 'повреждён исходник'
  checks=$((checks + 1))
}

for version in '../escape' '1.2.3/escape' '1.2.3;echo' ''; do
  new_case
  if [ -z "$version" ]; then printf '\n' > "$case_root/RELEASE_VERSION"; fi
  expect_fail guard 'версия должна иметь вид' "SMLTLK_VERSION=$version"
done

for scratch in / /Applications '../outside' '.'; do
  new_case
  expect_fail guard 'рабочий путь должен быть внутри' "SMLTLK_SCRATCH=$scratch"
done

new_case
ln -s "$test_root" "$case_root/release/linked-scratch"
expect_fail guard 'рабочий путь.*без симлинков' "SMLTLK_SCRATCH=$case_root/release/linked-scratch/build"

new_case
expect_fail guard 'нотаризация требует Developer ID Application' IRIZ_NOTARY_PROFILE=fixture

new_case
expect_fail guard 'рабочий путь должен быть внутри' IRIZ_RELEASE_DIST=/

new_case
expect_fail guard 'scratch и dist должны быть раздельными' "SMLTLK_SCRATCH=$case_root/release/dist/build"

new_case
expect_fail 'resource bundle' 'нет ресурсного IrizApp_IrizCore[.]bundle' TEST_FAULT=missing-bundle

new_case
expect_fail 'localization resources' 'в бандле нет таблицы перевода zh-hans' TEST_FAULT=missing-locale

new_case
expect_fail 'arm64 framework' 'в whisper[.]framework нет архитектуры arm64' TEST_FAULT=framework-arm64

new_case
expect_fail 'universal framework' 'в whisper[.]framework нет архитектуры x86_64' \
  IRIZ_RELEASE_VARIANTS='arm64 universal' TEST_FAULT=framework-universal

new_case
expect_fail 'rpath install' 'не удалось добавить rpath фреймворков' TEST_FAULT=rpath-install

new_case
expect_fail 'rpath no-op' 'rpath фреймворков отсутствует после упаковки' TEST_FAULT=rpath-noop

new_case
expect_fail 'rpath prefix' 'rpath фреймворков отсутствует после упаковки' TEST_FAULT=rpath-prefix
grep -q '^install_name_tool ' "$case_root/trace" || fail 'rpath prefix: FrameworksExtra принят за Frameworks'

for target in app framework; do
  binary='IrizApp'
  if [ "$target" = framework ]; then binary='whisper[.]framework/whisper'; fi
  for fault in minos-missing platform-ios minos-high; do
    new_case
    expect_fail "$target $fault" "minOS/платформа не подтверждены для каждого среза .*/$binary$" \
      "TEST_FAULT=$target-$fault"
  done
done

new_case
expect_fail 'DMG verify' 'шаг «hdiutil verify [(]arm64[)]» упал[.]' TEST_FAULT=dmg-verify

for fault in mounted-signature mounted-arch; do
  new_case
  reason='смонтированный .* неполон или подпись в нём не проходит'
  if [ "$fault" = mounted-arch ]; then reason='в .*/mount[.].*/iriz[.]app/Contents/MacOS/iriz нет архитектуры arm64'; fi
  expect_fail "$fault" "$reason" "TEST_FAULT=$fault"
  [ -f "$case_root/injected-fault" ] || fail "$fault: отказ не был внедрён в смонтированный образ"
  cmp -s "$case_root/owned-mount" "$case_root/detached-mount" || fail "$fault: собственный том остался подключён"
  [ "$(grep -c '^hdiutil <detach>' "$case_root/trace")" = 1 ] || fail "$fault: лишний detach"
done

new_case
expect_pass
[ -f "$case_root/release/dist/iriz-1.2.3-arm64.dmg" ] || fail 'нет versioned arm64 DMG'
[ -f "$case_root/release/dist/iriz-macos-arm64.dmg" ] || fail 'нет стабильного arm64 alias'
if grep -q -- '<x86_64>' "$case_root/trace"; then fail 'universal собрался без opt-in'; fi
[ "$(find "$case_root/release/dist" -name '*.dmg' | wc -l | tr -d ' ')" = 2 ] || fail 'лишний DMG по умолчанию'

"$real_python" - "$case_root/release/dist" <<'PY'
import hashlib, json, pathlib, sys
dist = pathlib.Path(sys.argv[1])
manifest = json.loads((dist / "release-manifest.json").read_text())
assert manifest["version"] == "1.2.3", manifest
assert manifest["build_version"], manifest
assert manifest["source_sha"] == "0123456789012345678901234567890123456789", manifest
assert manifest["source_dirty"] is False, manifest
assert manifest["signing"] == {"identity": "-", "mode": "ad-hoc", "targets": ["app"]}, manifest
assert manifest["notarized"] is False, manifest
files = {"iriz-1.2.3-arm64.dmg", "iriz-macos-arm64.dmg"}
assert {row["file"] for row in manifest["artifacts"]} == files, manifest
checksums = {}
for line in (dist / "SHA256SUMS.txt").read_text().splitlines():
    digest, name = line.split(None, 1)
    checksums[name.strip()] = digest
assert set(checksums) == files | {"release-manifest.json"}, checksums
assert checksums["release-manifest.json"] == hashlib.sha256((dist / "release-manifest.json").read_bytes()).hexdigest()
for row in manifest["artifacts"]:
    data = (dist / row["file"]).read_bytes()
    assert row["sha256"] == hashlib.sha256(data).hexdigest() == checksums[row["file"]], row
    assert row["bytes"] == len(data), row
    assert row["architectures"] == ["arm64"], row
assert (dist / "iriz-1.2.3-arm64.dmg").read_bytes() == (dist / "iriz-macos-arm64.dmg").read_bytes()
PY

new_case
expect_pass IRIZ_RELEASE_VARIANTS='arm64 universal' SMLTLK_VERSION=2.3.4 \
  "IRIZ_RELEASE_DIST=$case_root/release/custom-dist" IRIZ_DMG_HEADLESS= CI=true
[ -f "$case_root/release/custom-dist/iriz-2.3.4-universal.dmg" ] || fail 'opt-in universal не собрался'
grep -q -- '<x86_64>' "$case_root/trace" || fail 'universal не запросил x86_64'

new_case
expect_pass TEST_NOTARY=1 IRIZ_NOTARY_PROFILE=fixture \
  'SMLTLK_SIGN_IDENTITY=Developer ID Application: Fixture (TEST123)'
"$real_python" - "$case_root" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
calls = [(line.split(" ", 1)[0], re.findall(r"<([^>]*)>", line)) for line in (root / "trace").read_text().splitlines()]
def at(command, argument, suffix):
    return next(i for i, (cmd, args) in enumerate(calls)
                if cmd == command and argument in args and any(arg.endswith(suffix) for arg in args))
order = [at("codesign", "--force", "/stage-arm64/iriz.app"),
         at("codesign", "-R=anchor apple generic", "/stage-arm64/iriz.app"),
         at("xcrun", "submit", ".zip"), at("codesign", "--force", ".dmg"),
         at("codesign", "-R=anchor apple generic", ".dmg"), at("xcrun", "submit", ".dmg")]
assert order == sorted(set(order)), order
assert "--timestamp" in calls[order[0]][1] and "--timestamp" in calls[order[3]][1]
manifest = json.loads((root / "release/dist/release-manifest.json").read_text())
assert manifest["notarized"] is True, manifest
assert manifest["signing"] == {"identity": "Developer ID Application: Fixture (TEST123)",
                               "mode": "developer-id", "targets": ["app", "dmg"]}, manifest
PY

new_case
expect_fail 'DMG Apple anchor' 'шаг «проверка подписи образа arm64» упал[.]' \
  TEST_NOTARY=1 IRIZ_NOTARY_PROFILE=fixture TEST_FAULT=dmg-anchor \
  'SMLTLK_SIGN_IDENTITY=Developer ID Application: Fixture (TEST123)'
[ -f "$case_root/injected-fault" ] || fail 'Apple anchor: отказ не был внедрён'
if grep -Eq '^xcrun <notarytool> <submit> <[^>]*[.]dmg>' "$case_root/trace"; then
  fail 'DMG отправлен на нотаризацию после отказа Apple anchor'
fi

printf 'make_release_test: %s сценариев прошли; реальная сборка, подпись и DMG не запускались.\n' "$checks"
