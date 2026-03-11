#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${APPLE_LOCAL_AI_RELEASE_BUILD_DIR:-$ROOT_DIR/release/build}"
APP_DIR="${APPLE_LOCAL_AI_APP_PATH:-$BUILD_DIR/DropSort.app}"
STAGING_DIR="$BUILD_DIR/dmg-staging"
DMG_PATH="${APPLE_LOCAL_AI_DMG_PATH:-$BUILD_DIR/DropSort.dmg}"
VOLNAME="DropSort"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --app)
      APP_DIR="$2"
      shift
      ;;
    --output)
      DMG_PATH="$2"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ ! -d "$APP_DIR" ]]; then
  echo "App bundle not found: $APP_DIR" >&2
  exit 1
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

MANIFEST_PATH="$BUILD_DIR/dmg-manifest.json"
APP_DIR_ENV="$APP_DIR" \
STAGING_DIR_ENV="$STAGING_DIR" \
DMG_PATH_ENV="$DMG_PATH" \
VOLNAME_ENV="$VOLNAME" \
MANIFEST_PATH_ENV="$MANIFEST_PATH" \
python3 - <<'PY'
import json
import os
from pathlib import Path

payload = {
    "app_path": os.environ["APP_DIR_ENV"],
    "staging_dir": os.environ["STAGING_DIR_ENV"],
    "output_dmg": os.environ["DMG_PATH_ENV"],
    "volume_name": os.environ["VOLNAME_ENV"],
}
Path(os.environ["MANIFEST_PATH_ENV"]).write_text(
    json.dumps(payload, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
PY

if (( DRY_RUN )); then
  echo "Dry run complete. Manifest: $MANIFEST_PATH"
  exit 0
fi

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  "$DMG_PATH"

echo "Created DMG: $DMG_PATH"
