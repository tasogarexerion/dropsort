#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${APPLE_LOCAL_AI_RELEASE_BUILD_DIR:-$ROOT_DIR/release/build}"
APP_DIR="$BUILD_DIR/AppleLocalOrganizer.app"
APP_CONTENTS="$APP_DIR/Contents"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/AppleLocalOrganizerApp"
APP_VERSION="${APPLE_LOCAL_AI_APP_VERSION:-0.1.1}"
BUNDLE_ID="com.taso.apple-local-organizer"
PYTHON_RUNTIME_SRC="${APPLE_LOCAL_AI_VENDOR_PYTHON:-$ROOT_DIR/vendor/python-runtime/macos-arm64}"
SWIFT_BINARY_OVERRIDE="${APPLE_LOCAL_AI_SWIFT_BINARY:-}"
DRY_RUN=0
SKIP_SWIFT_BUILD=0
SKIP_FIXTURES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --skip-swift-build)
      SKIP_SWIFT_BUILD=1
      ;;
    --skip-fixtures)
      SKIP_FIXTURES=1
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done

function require_dir() {
  if [[ ! -d "$1" ]]; then
    echo "Required directory not found: $1" >&2
    exit 1
  fi
}

function require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Required file not found: $1" >&2
    exit 1
  fi
}

function swift_binary_path() {
  if [[ -n "$SWIFT_BINARY_OVERRIDE" ]]; then
    echo "$SWIFT_BINARY_OVERRIDE"
    return
  fi
  echo "$ROOT_DIR/shell/.build/arm64-apple-macosx/release/AppleLocalOrganizerApp"
}

function write_info_plist() {
  cat >"$APP_CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ja</string>
  <key>CFBundleDisplayName</key>
  <string>Apple Local Organizer</string>
  <key>CFBundleExecutable</key>
  <string>AppleLocalOrganizerApp</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Apple Local Organizer Supported Files</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.plain-text</string>
        <string>net.daringfireball.markdown</string>
        <string>com.adobe.pdf</string>
        <string>public.image</string>
      </array>
    </dict>
  </array>
  <key>CFBundleName</key>
  <string>Apple Local Organizer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF
}

function write_build_manifest() {
  local manifest_path="$BUILD_DIR/build-manifest.json"
  APP_DIR_ENV="$APP_DIR" \
  PYTHON_RUNTIME_SRC_ENV="$PYTHON_RUNTIME_SRC" \
  APP_BINARY_ENV="$APP_BINARY" \
  APP_RESOURCES_ENV="$APP_RESOURCES" \
  APP_CONTENTS_ENV="$APP_CONTENTS" \
  MANIFEST_PATH_ENV="$manifest_path" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

manifest = {
    "app_path": os.environ["APP_DIR_ENV"],
    "python_runtime_source": os.environ["PYTHON_RUNTIME_SRC_ENV"],
    "app_binary": os.environ["APP_BINARY_ENV"],
    "resources": [
        os.environ["APP_RESOURCES_ENV"] + "/python",
        os.environ["APP_RESOURCES_ENV"] + "/python-runtime",
        os.environ["APP_RESOURCES_ENV"] + "/bridge_runner.py",
        os.environ["APP_CONTENTS_ENV"] + "/Info.plist",
    ],
}
Path(os.environ["MANIFEST_PATH_ENV"]).write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
PY
}

function fixup_python_runtime() {
  local runtime_root="$APP_RESOURCES/python-runtime"
  local python_dylib="$runtime_root/Python"
  local bin_python="$runtime_root/bin/python3.12"
  local app_python="$runtime_root/Resources/Python.app/Contents/MacOS/Python"
  local dylib_install_name
  local bin_install_name
  local app_install_name

  if [[ ! -f "$python_dylib" ]]; then
    return
  fi
  if ! command -v otool >/dev/null 2>&1 || ! command -v install_name_tool >/dev/null 2>&1; then
    return
  fi

  dylib_install_name="$(otool -L "$python_dylib" | awk 'NR==2 { print $1 }')"
  if [[ -z "$dylib_install_name" ]]; then
    return
  fi

  install_name_tool -id "@rpath/Python" "$python_dylib" || true
  if [[ -f "$bin_python" ]]; then
    bin_install_name="$(otool -L "$bin_python" | awk '/Python\.framework/ { print $1; exit }')"
    if [[ -n "$bin_install_name" ]]; then
      install_name_tool -change "$bin_install_name" "@executable_path/../Python" "$bin_python" || true
    fi
  fi
  if [[ -f "$app_python" ]]; then
    app_install_name="$(otool -L "$app_python" | awk '/Python\.framework/ { print $1; exit }')"
    if [[ -n "$app_install_name" ]]; then
      install_name_tool -change "$app_install_name" "@executable_path/../../../../Python" "$app_python" || true
    fi
  fi
}

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"

if (( ! SKIP_FIXTURES )); then
  echo "[1/4] Generate fixtures"
  python3 "$ROOT_DIR/fixtures/generate_fixtures.py"
fi

echo "[2/4] Validate inputs"
require_dir "$PYTHON_RUNTIME_SRC"

if (( ! SKIP_SWIFT_BUILD )); then
  echo "[3/4] Build Swift shell"
  swift build --package-path "$ROOT_DIR/shell" -c release
fi

SWIFT_BINARY="$(swift_binary_path)"
if [[ ! -f "$SWIFT_BINARY" ]]; then
  if (( DRY_RUN )); then
    echo "#!/bin/zsh" >"$APP_BINARY"
    echo "exit 0" >>"$APP_BINARY"
    chmod +x "$APP_BINARY"
  else
    require_file "$SWIFT_BINARY"
  fi
else
  cp "$SWIFT_BINARY" "$APP_BINARY"
  chmod +x "$APP_BINARY"
fi

echo "[4/4] Stage app bundle"
rsync -a "$ROOT_DIR/core/src/" "$APP_RESOURCES/python/"
rsync -a "$PYTHON_RUNTIME_SRC/" "$APP_RESOURCES/python-runtime/"
cp "$ROOT_DIR/shell/Sources/AppleLocalOrganizerApp/Resources/bridge_runner.py" "$APP_RESOURCES/bridge_runner.py"
chmod +x "$APP_RESOURCES/bridge_runner.py"
fixup_python_runtime
write_info_plist
printf 'APPL????' >"$APP_CONTENTS/PkgInfo"
write_build_manifest

echo "Staged app bundle at $APP_DIR"
if (( DRY_RUN )); then
  echo "Dry run complete. Manifest: $BUILD_DIR/build-manifest.json"
fi
