#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

EXIT_CODE=0

function section() {
  echo
  echo "== $1 =="
}

function mark_failure() {
  EXIT_CODE=1
}

section "Workspace"
echo "Root: $ROOT_DIR"
if [[ -d .git ]]; then
  git status --short
else
  echo "Standalone git repo is not initialized yet."
fi

section "Secret scan"
if rg -n -I \
  --hidden \
  --glob '!.git/**' \
  --glob '!.github/**' \
  --glob '!.venv*/**' \
  --glob '!scripts/public_release_check.sh' \
  --glob '!release/build/**' \
  --glob '!vendor/python-runtime/**' \
  --glob '!fixtures/generated/**' \
  --glob '!validation/reports/**' \
  '(BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|AKIA[0-9A-Z]{16}|-----BEGIN CERTIFICATE-----|app-specific password)' \
  .; then
  echo "Potential secret-like content found."
  mark_failure
else
  echo "No obvious secret patterns found."
fi

section "Large files"
large_files="$(find . \
  -path './.git' -prune -o \
  -path './.venv-device' -prune -o \
  -path './.venv-fm312' -prune -o \
  -path './.swift-module-cache' -prune -o \
  -path './release/build' -prune -o \
  -path './vendor/python-runtime' -prune -o \
  -type f -size +20M -print | sort)"
if [[ -n "$large_files" ]]; then
  echo "$large_files"
  echo "Large files over 20 MB found."
  mark_failure
else
  echo "No large tracked-source candidates found over 20 MB."
fi

section "Metadata"
if [[ -f LICENSE || -f LICENSE.md || -f LICENSE.txt ]]; then
  echo "License file found."
else
  echo "Warning: no LICENSE file found. Public visibility is possible, but reuse conditions are not declared."
fi

section "Fixtures"
if ! python3 fixtures/generate_fixtures.py; then
  mark_failure
fi

section "Python tests"
if ! PYTHONPATH=core/src python3 -m unittest discover -s core/tests -v; then
  mark_failure
fi

section "Swift build"
mkdir -p "$ROOT_DIR/.swift-module-cache/clang" "$ROOT_DIR/.swiftpm-home"
if ! HOME="$ROOT_DIR/.swiftpm-home" \
  CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.swift-module-cache/clang" \
  swift build --package-path shell; then
  mark_failure
fi

section "Release notes preview"
if [[ -f release/build/DropSort.dmg ]]; then
  if ! release/prepare_github_release.sh --tag "preview-check" >/dev/null; then
    mark_failure
  else
    echo "Prepared GitHub release notes from the current DMG."
  fi
else
  echo "Skipped: release/build/DropSort.dmg does not exist yet."
fi

section "Summary"
if (( EXIT_CODE == 0 )); then
  echo "Public release check passed."
else
  echo "Public release check failed."
fi

exit "$EXIT_CODE"
