#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${APPLE_LOCAL_AI_RELEASE_BUILD_DIR:-$ROOT_DIR/release/build}"
APP_DIR="${APPLE_LOCAL_AI_APP_PATH:-$BUILD_DIR/DropSort.app}"
DRY_RUN=0
SIGN_IDENTITY=""
SIGN_IDENTITY_MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --app)
      APP_DIR="$2"
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

APP_BINARY="$APP_DIR/Contents/MacOS/AppleLocalOrganizerApp"
PYTHON_RUNTIME="$APP_DIR/Contents/Resources/python-runtime"
MANIFEST_PATH="${BUILD_DIR}/sign-manifest.json"
PYTHON_APP="$PYTHON_RUNTIME/Resources/Python.app"

function resolve_identity() {
  if [[ -n "${DEVELOPER_ID_APP_HASH:-}" ]]; then
    SIGN_IDENTITY="${DEVELOPER_ID_APP_HASH}"
    SIGN_IDENTITY_MODE="hash"
    return
  fi

  if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
    SIGN_IDENTITY="${DEVELOPER_ID_APP}"
    SIGN_IDENTITY_MODE="label"
    return
  fi

  local -a discovered_hashes
  discovered_hashes=()
  while IFS= read -r candidate; do
    discovered_hashes+=("$candidate")
  done < <(
    security find-identity -v -p codesigning 2>/dev/null |
      awk '/Developer ID Application:/ {print $2}'
  )

  if (( ${#discovered_hashes[@]} == 1 )); then
    SIGN_IDENTITY="${discovered_hashes[1]}"
    SIGN_IDENTITY_MODE="auto-hash"
    return
  fi

  echo "Developer ID identity is required. Set DEVELOPER_ID_APP_HASH or DEVELOPER_ID_APP." >&2
  exit 1
}

function sign_basic() {
  local target="$1"
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$target"
  else
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$target"
  fi
}

function sign_runtime() {
  local target="$1"
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$target"
  else
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$target"
  fi
}

function write_manifest() {
  local nested_joined
  local bundles_joined
  nested_joined=$(printf '%s\n' "${nested_targets[@]}")
  bundles_joined=$(printf '%s\n' "${bundle_targets[@]}")
  APP_BINARY_ENV="$APP_BINARY" \
  APP_DIR_ENV="$APP_DIR" \
  NESTED_TARGETS_ENV="$nested_joined" \
  BUNDLE_TARGETS_ENV="$bundles_joined" \
  MANIFEST_PATH_ENV="$MANIFEST_PATH" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

targets = {
    "nested": [item for item in os.environ.get("NESTED_TARGETS_ENV", "").splitlines() if item],
    "bundles": [item for item in os.environ.get("BUNDLE_TARGETS_ENV", "").splitlines() if item],
    "app_executable": os.environ["APP_BINARY_ENV"],
    "app_bundle": os.environ["APP_DIR_ENV"],
    "identity_mode": os.environ["SIGN_IDENTITY_MODE_ENV"],
}
identity = os.environ.get("SIGN_IDENTITY_ENV", "")
if identity == "-":
    targets["identity"] = "adhoc"
elif identity and len(identity) == 40 and all(ch in "0123456789abcdefABCDEF" for ch in identity):
    targets["identity"] = f"sha1:{identity[:12]}..."
elif identity:
    targets["identity"] = "configured-label"
Path(os.environ["MANIFEST_PATH_ENV"]).write_text(
    json.dumps(targets, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
PY
}

typeset -a nested_targets
typeset -a bundle_targets
typeset -a critical_python_targets
nested_targets=()
bundle_targets=()
critical_python_targets=(
  "$PYTHON_RUNTIME/Python"
  "$PYTHON_APP/Contents/MacOS/Python"
  "$PYTHON_RUNTIME/bin/python3.12"
)
resolve_identity
while IFS= read -r target; do
  case "$target" in
    "$PYTHON_RUNTIME/Python"|"$PYTHON_APP/Contents/MacOS/Python"|"$PYTHON_RUNTIME/bin/python3.12")
      ;;
    *)
      nested_targets+=("$target")
      ;;
  esac
done < <(
  find "$PYTHON_RUNTIME" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) | sort
)
if [[ -d "$PYTHON_APP" ]]; then
  bundle_targets+=("$PYTHON_APP")
fi
bundle_targets+=("$PYTHON_RUNTIME")

SIGN_IDENTITY_ENV="$SIGN_IDENTITY" \
SIGN_IDENTITY_MODE_ENV="$SIGN_IDENTITY_MODE" \
write_manifest

if (( DRY_RUN )); then
  echo "Dry run complete. Manifest: $MANIFEST_PATH"
  exit 0
fi

for target in "${nested_targets[@]}"; do
  sign_basic "$target"
done

for target in "${bundle_targets[@]}"; do
  sign_basic "$target"
done

for target in "${critical_python_targets[@]}"; do
  if [[ -e "$target" ]]; then
    sign_basic "$target"
  fi
done

sign_runtime "$APP_BINARY"
sign_runtime "$APP_DIR"

echo "Signed app bundle: $APP_DIR"
