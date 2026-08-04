#!/bin/bash
# Стабильная QA-сборка. В отличие от probe-образа она сохраняет один и тот же
# designated requirement, поэтому Accessibility grant не ломается при каждом
# изменении бинарника.

set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: WaiWai, LLC (R4A779QVVY)}"
ALLOW_DIRTY_BETA="${ALLOW_DIRTY_BETA:-0}"

HEAD_SHA=$(git rev-parse --verify HEAD)
if [[ -n "$(git status --porcelain)" && "$ALLOW_DIRTY_BETA" != "1" ]]; then
  echo "Installable beta не собирается из грязного дерева." >&2
  echo "Для локального QA незакоммиченного кода укажите ALLOW_DIRTY_BETA=1 явно." >&2
  exit 1
fi

echo "→ Исходный commit: $HEAD_SHA"
if [[ "$ALLOW_DIRTY_BETA" == "1" ]]; then
  echo "  Dirty-tree override: артефакт только для локального QA, не для публичной раздачи."
  BUILD_NUMBER_OVERRIDE="${BUILD_NUMBER_OVERRIDE:-$(date -u +%y%m%d%H%M)}"
  export BUILD_NUMBER_OVERRIDE
  echo "  Уникальный QA build number: $BUILD_NUMBER_OVERRIDE"
fi

if ! security find-identity -v -p codesigning \
  | grep -Fq "\"$DEVELOPER_ID\""; then
  echo "Не найден сертификат: $DEVELOPER_ID" >&2
  exit 1
fi

DEVELOPER_ID="$DEVELOPER_ID" \
REQUIRE_NOTARIZATION=1 \
./scripts/build-dmg.sh
