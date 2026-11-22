#!/usr/bin/env bash
# Локальная сборка всегда использует закреплённый сертификат OwnShot.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION=Release
DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode-derived-data"
INSTALL=0
RUN=0
CLEAN=0
QUIET=1
PIN="$ROOT_DIR/.local-signing/identity.json"
INSTALL_PATH="$HOME/Applications/OwnShot.app"
fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
Использование: scripts/build-ownshot.sh [параметры]
  --configuration Debug|Release  Конфигурация (по умолчанию Release)
  --build-only                   Только собрать и проверить (по умолчанию)
  --install                      Установить в ~/Applications/OwnShot.app
  --run                          Установить и запустить приложение
  --derived-data PATH            Каталог DerivedData для повторных сборок
  --clean                        Очистить продукты перед сборкой
  --verbose                      Полный вывод xcodebuild
  --help                         Эта справка
Сертификат настраивается отдельно: scripts/create-signing-cert.sh
Отсутствие закреплённой идентичности останавливает сборку.
HELP
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration|--derived-data|--derived-data-path)
      [[ $# -ge 2 && -n "$2" ]] || fail "Для $1 требуется значение."
      if [[ "$1" == --configuration ]]; then CONFIGURATION="$2"; else DERIVED_DATA_PATH="$2"; fi
      shift 2 ;;
    --build-only) INSTALL=0; RUN=0; shift ;;
    --install) INSTALL=1; shift ;;
    --run|run) INSTALL=1; RUN=1; shift ;;
    --clean) CLEAN=1; shift ;;
    --verbose) QUIET=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Неизвестный параметр: $1. См. --help." ;;
  esac
done
[[ "$CONFIGURATION" == Debug || "$CONFIGURATION" == Release ]] || fail 'Допустимы только Debug и Release.'
[[ "$(uname -s)" == Darwin ]] || fail 'Сборка поддерживается только на macOS.'
for command in python3 xcodebuild codesign openssl; do
  command -v "$command" >/dev/null || fail "Не найдена команда $command."
done
[[ -f "$PIN" ]] || fail 'Нет закреплённой идентичности. Выполни scripts/create-signing-cert.sh.'
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
# --inspect не создаёт ключи и не заменяет пропавшую идентичность.
[[ -x "$ROOT_DIR/.local-signing/identity-helper" ]] || fail 'Нет helper подписи. Выполни scripts/create-signing-cert.sh.'
"$ROOT_DIR/.local-signing/identity-helper" --inspect --pin "$PIN" > "$TEMP_DIR/identity.json"
python3 - "$PIN" "$TEMP_DIR/identity.json" > "$TEMP_DIR/fingerprints" <<'PY'
import json, re, sys
pinned, current = (json.load(open(path)) for path in sys.argv[1:])
for name, length in [('fingerprintSHA1', 40), ('fingerprintSHA256', 64)]:
    value = pinned.get(name, '').upper()
    if not re.fullmatch('[0-9A-F]{%d}' % length, value) or value != current.get(name, '').upper():
        raise SystemExit('Ошибка: закреплённая идентичность не совпадает с Keychain.')
    print(value)
PY
SHA1="$(sed -n '1p' "$TEMP_DIR/fingerprints")"
SHA256="$(sed -n '2p' "$TEMP_DIR/fingerprints")"
printf 'OWN_SHOT_SIGNING_IDENTITY = %s\n' "$SHA1" > "$TEMP_DIR/Signing.xcconfig"
mv "$TEMP_DIR/Signing.xcconfig" "$ROOT_DIR/.local-signing/Signing.xcconfig"
REQUIREMENT="identifier \"dev.nikoko.ownshot\" and certificate leaf = H\"$SHA1\""
ARGS=(-project "$ROOT_DIR/Snapzy.xcodeproj" -scheme Snapzy -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA_PATH" -destination "platform=macOS,arch=$(uname -m)"
  CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SHA1" DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES)
[[ "$QUIET" == 0 ]] || ARGS+=(-quiet)
[[ "$CLEAN" == 0 ]] || xcodebuild "${ARGS[@]}" clean
xcodebuild "${ARGS[@]}" build
APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/OwnShot.app"
[[ -d "$APP" ]] || fail "Сборка не создала $APP."
verify_app() {
  local app="$1" cert_sha1 cert_sha256 actual_requirement
  python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    if plistlib.load(f).get('CFBundleIdentifier') != 'dev.nikoko.ownshot':
        raise SystemExit('Ошибка: неверный bundle ID приложения.')
PY
  codesign --verify --deep --strict --verbose=2 "$app" || fail 'Подпись приложения или вложенного кода недействительна.'
  codesign --verify --strict -R="$REQUIREMENT" "$app" || fail 'Подпись не соответствует закреплённому сертификату и bundle ID.'
  rm -f "$TEMP_DIR/cert"*
  codesign --display --extract-certificates="$TEMP_DIR/cert" "$app" || fail 'Не удалось извлечь сертификат подписи.'
  [[ -f "$TEMP_DIR/cert0" ]] || fail 'В подписи отсутствует сертификат (ad-hoc запрещён).'
  cert_sha1="$(openssl x509 -inform DER -in "$TEMP_DIR/cert0" -noout -fingerprint -sha1 | sed 's/.*=//;s/://g' | tr '[:lower:]' '[:upper:]')"
  cert_sha256="$(openssl x509 -inform DER -in "$TEMP_DIR/cert0" -noout -fingerprint -sha256 | sed 's/.*=//;s/://g' | tr '[:lower:]' '[:upper:]')"
  [[ "$cert_sha1" == "$SHA1" && "$cert_sha256" == "$SHA256" ]] || fail 'Сертификат подписи отличается от закреплённого.'
  codesign --display -r- "$app" > "$TEMP_DIR/requirement" 2>&1
  actual_requirement="$(sed -n 's/^designated => //p' "$TEMP_DIR/requirement")"
  [[ "$(printf '%s' "$actual_requirement" | tr '[:lower:]' '[:upper:]')" == "$(printf '%s' "$REQUIREMENT" | tr '[:lower:]' '[:upper:]')" ]] || fail "Designated requirement изменился: $actual_requirement"
}
verify_app "$APP"
printf 'Подпись проверена: %s\nSHA-256 сертификата: %s\nDesignated requirement: %s\n' "$APP" "$SHA256" "$REQUIREMENT"
if [[ "$INSTALL" == 1 ]]; then
  mkdir -p "$HOME/Applications"
  STAGING="$(mktemp -d "$HOME/Applications/.ownshot-install.XXXXXX")"
  trap 'rm -rf "$TEMP_DIR" "${STAGING:-}"' EXIT
  ditto "$APP" "$STAGING/OwnShot.app"
  verify_app "$STAGING/OwnShot.app"
  # Все проверки проходят до замены установленной копии.
  BACKUP="$STAGING/Previous.app"
  if [[ -e "$INSTALL_PATH" ]]; then mv "$INSTALL_PATH" "$BACKUP"; fi
  if ! mv "$STAGING/OwnShot.app" "$INSTALL_PATH"; then
    [[ ! -e "$BACKUP" ]] || mv "$BACKUP" "$INSTALL_PATH"
    fail 'Не удалось установить приложение. Предыдущая копия сохранена.'
  fi
  printf 'Установлено: %s\n' "$INSTALL_PATH"
fi
# Сборочные копии не должны оставаться обработчиками файлов и ownshot://.
python3 - "$APP" "$INSTALL_PATH" "$INSTALL" <<'PY'
from pathlib import Path
import shutil, subprocess, sys

app, installed = (Path(path).resolve() for path in sys.argv[1:3])
lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
for nested in sorted({path.resolve() for path in app.rglob('*.app')}, key=lambda path: len(str(path)), reverse=True):
    subprocess.run([lsregister, '-u', str(nested)], capture_output=True, text=True)
for plugin in (app / 'Contents/PlugIns').glob('*.appex'):
    result = subprocess.run(['/usr/bin/pluginkit', '-r', str(plugin)], capture_output=True, text=True)
    if result.returncode and 'no plugin at' not in result.stderr:
        raise SystemExit(result.stderr)
subprocess.run([lsregister, '-u', str(app)], capture_output=True, text=True)
# На macOS unregister может вернуть ошибку повторного сканирования уже удалённой записи.
# Проверяем результат в реестре, а не код этого сканирования.
registry = subprocess.run([lsregister, '-dump'], capture_output=True, text=True, check=True).stdout
test_host = app.with_name('OwnShot Test Host.app')
roots = [str(app)]
if not test_host.exists():
    roots.append(str(test_host))
    for line in registry.splitlines():
        if line.startswith('path:'):
            path = line.split(':', 1)[1].strip().rsplit(' (0x', 1)[0]
            if path == str(test_host) or path.startswith(str(test_host) + '/'):
                subprocess.run([lsregister, '-u', path], capture_output=True, text=True)
    registry = subprocess.run([lsregister, '-dump'], capture_output=True, text=True, check=True).stdout
def remaining_paths(registry):
    remaining = set()
    for line in registry.splitlines():
        if line.startswith('path:'):
            path = line.split(':', 1)[1].strip().rsplit(' (0x', 1)[0]
            if any(path == root or path.startswith(root + '/') for root in roots):
                remaining.add(path)
    return sorted(remaining, key=lambda path: (-len(path), path))

remaining = remaining_paths(registry)
if remaining:
    for path in remaining:
        subprocess.run([lsregister, '-u', path], capture_output=True, text=True)
    registry = subprocess.run([lsregister, '-dump'], capture_output=True, text=True, check=True).stdout
    remaining = remaining_paths(registry)
if remaining:
    raise SystemExit('Остались регистрации сборочной копии: ' + ', '.join(remaining))
if sys.argv[3] == '1':
    subprocess.run([lsregister, '-f', str(installed)], check=True)
    for plugin in (installed / 'Contents/PlugIns').glob('*.appex'):
        subprocess.run(['/usr/bin/pluginkit', '-a', str(plugin)], check=True)
    if app.resolve() != installed.resolve():
        shutil.rmtree(app)
print('Регистрация сборочной копии удалена. Рабочая копия: ' + str(installed))
PY
[[ "$RUN" == 0 ]] || open "$INSTALL_PATH"
