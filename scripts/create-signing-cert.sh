#!/usr/bin/env bash
# Ключ создаётся в Keychain и не экспортируется.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 0 ]]; then
  printf 'Использование: scripts/create-signing-cert.sh\nПовторный запуск использует прежнюю идентичность. Экспорт P12 не поддерживается.\n' >&2
  exit 2
fi
LOCAL="$ROOT_DIR/.local-signing"
mkdir -p "$LOCAL"
# Стабильный путь нужен для ACL закрытого ключа в Keychain.
if [[ ! -x "$LOCAL/identity-helper" || "$ROOT_DIR/scripts/ownshot-signing-identity.swift" -nt "$LOCAL/identity-helper" ]]; then
  TEMP_HELPER="$(mktemp "$LOCAL/.identity-helper.XXXXXX")"
  trap 'rm -f "$TEMP_HELPER"' EXIT
  swiftc "$ROOT_DIR/scripts/ownshot-signing-identity.swift" -o "$TEMP_HELPER"
  mv "$TEMP_HELPER" "$LOCAL/identity-helper"
fi
"$LOCAL/identity-helper" --ensure --pin "$LOCAL/identity.json"
TEMP_CONFIG="$(mktemp "$LOCAL/.Signing.xcconfig.XXXXXX")"
trap 'rm -f "$TEMP_CONFIG"' EXIT
python3 - "$LOCAL/identity.json" > "$TEMP_CONFIG" <<'PY'
import json, re, sys
identity = json.load(open(sys.argv[1]))
fingerprint = identity.get('fingerprintSHA1', '')
if not re.fullmatch('[0-9A-F]{40}', fingerprint):
    raise SystemExit('Ошибка: неверный SHA-1 закреплённого сертификата.')
print('OWN_SHOT_SIGNING_IDENTITY = ' + fingerprint)
PY
mv "$TEMP_CONFIG" "$LOCAL/Signing.xcconfig"
