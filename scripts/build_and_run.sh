#!/usr/bin/env bash
# Совместимый вход: прежняя команда без параметров собирает, устанавливает и запускает OwnShot.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT_DIR/scripts/build-ownshot.sh" --run "$@"
