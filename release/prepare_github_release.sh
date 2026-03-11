#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${APPLE_LOCAL_AI_RELEASE_BUILD_DIR:-$ROOT_DIR/release/build}"
APP_DIR="${APPLE_LOCAL_AI_APP_PATH:-$BUILD_DIR/AppleLocalOrganizer.app}"
DMG_PATH="${APPLE_LOCAL_AI_DMG_PATH:-$BUILD_DIR/AppleLocalOrganizer.dmg}"
OUTPUT_DIR="${APPLE_LOCAL_AI_GITHUB_RELEASE_DIR:-$BUILD_DIR/github-release}"
TAG_NAME="${GITHUB_RELEASE_TAG:-preview}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_DIR="$2"
      shift
      ;;
    --dmg)
      DMG_PATH="$2"
      shift
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift
      ;;
    --tag)
      TAG_NAME="$2"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
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

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

SIGNATURE_MODE="unknown"
if codesign_details="$(codesign -dv --verbose=2 "$APP_DIR" 2>&1)"; then
  if [[ "$codesign_details" == *"Signature=adhoc"* ]]; then
    SIGNATURE_MODE="adhoc"
  elif [[ "$codesign_details" == *"Authority=Developer ID Application"* ]]; then
    SIGNATURE_MODE="developer-id"
  else
    SIGNATURE_MODE="signed"
  fi
fi

DMG_NAME="$(basename "$DMG_PATH")"
SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
NOTES_PATH="$OUTPUT_DIR/GITHUB_RELEASE_NOTES.md"
MANIFEST_PATH="$OUTPUT_DIR/github-release-manifest.json"
PUBLIC_REPO_URL="${APPLE_LOCAL_AI_PUBLIC_REPO_URL:-https://github.com/tasogarexerion/apple-local-organizer}"
SCREENSHOT_URL="${APPLE_LOCAL_AI_RELEASE_SCREENSHOT_URL:-https://raw.githubusercontent.com/tasogarexerion/apple-local-organizer/main/docs/images/release-preview.png}"

DMG_PATH_ENV="$DMG_PATH" \
APP_DIR_ENV="$APP_DIR" \
OUTPUT_DIR_ENV="$OUTPUT_DIR" \
NOTES_PATH_ENV="$NOTES_PATH" \
MANIFEST_PATH_ENV="$MANIFEST_PATH" \
TAG_NAME_ENV="$TAG_NAME" \
DMG_NAME_ENV="$DMG_NAME" \
SHA256_ENV="$SHA256" \
SIGNATURE_MODE_ENV="$SIGNATURE_MODE" \
PUBLIC_REPO_URL_ENV="$PUBLIC_REPO_URL" \
SCREENSHOT_URL_ENV="$SCREENSHOT_URL" \
python3 - <<'PY'
import json
import os
from pathlib import Path

signature_mode = os.environ["SIGNATURE_MODE_ENV"]
dmg_name = os.environ["DMG_NAME_ENV"]
tag_name = os.environ["TAG_NAME_ENV"]
sha256 = os.environ["SHA256_ENV"]
public_repo_url = os.environ["PUBLIC_REPO_URL_ENV"]
screenshot_url = os.environ["SCREENSHOT_URL_ENV"]

if signature_mode == "developer-id":
    install_note = "Developer ID 署名済みです。Gatekeeper の警告は最小限の想定です。"
else:
    install_note = (
        "Developer ID / notarization なしのプレビュー配布です。"
        "初回起動時に Gatekeeper 警告が出る可能性があります。"
        "右クリックから「開く」または「システム設定 > プライバシーとセキュリティ」で許可してください。"
    )

notes = f"""# Apple Local Organizer {tag_name}

Apple Intelligence を使った、ローカル要約と Finder 整理提案の macOS メニューバーアプリです。

![Preview image]({screenshot_url})

## 配布物

- `{dmg_name}`
- SHA-256: `{sha256}`

## できること

- クリップボードやテキスト / PDF / 画像の日本語要約
- Desktop / Downloads の整理候補レビュー
- 完全オンデバイス前提の Foundation Models / Vision ワークフロー

## 動作前提

- Apple Silicon 向けの macOS アプリです
- AI 機能は macOS 26+ かつ Apple Intelligence 有効環境が前提です

## インストール時の注意

- {install_note}

## 既知の前提

- Finder 整理はレビュー専用で、ファイル移動は行いません。
- Foundation Models / Vision の動作確認は実機前提です。
- 開発者向けプレビューとしての配布を想定しています。

## ライセンス

- 個人利用、教育利用、研究利用、評価目的での利用は許可します。
- 商用利用は要問い合わせです。詳細は同梱またはリポジトリ上の `LICENSE` を確認してください。

## フィードバックと問い合わせ

- 不具合報告は GitHub Issues を使ってください: {public_repo_url}/issues
- 使い方の質問や改善アイデアは GitHub Discussions を想定しています
- 現時点で Discussions が未有効な場合は、当面は Issues にまとめてください

## フィードバック観点

- 日本語要約の自然さ
- OCR-only PDF やスクリーンショットの読み取り精度
- 整理候補フォルダ名の妥当性
"""

manifest = {
    "tag": tag_name,
    "app_path": os.environ["APP_DIR_ENV"],
    "dmg_path": os.environ["DMG_PATH_ENV"],
    "dmg_name": dmg_name,
    "sha256": sha256,
    "signature_mode": signature_mode,
    "notes_path": os.environ["NOTES_PATH_ENV"],
}

Path(os.environ["NOTES_PATH_ENV"]).write_text(notes, encoding="utf-8")
Path(os.environ["MANIFEST_PATH_ENV"]).write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
PY

if (( DRY_RUN )); then
  echo "Dry run complete. Notes: $NOTES_PATH"
  echo "Dry run complete. Manifest: $MANIFEST_PATH"
  exit 0
fi

echo "Prepared GitHub release notes: $NOTES_PATH"
echo "Prepared GitHub release manifest: $MANIFEST_PATH"
