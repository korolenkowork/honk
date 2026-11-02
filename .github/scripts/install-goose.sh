#!/usr/bin/env bash
# Installs a Goose release for this runner and puts it on PATH.
#   GOOSE_VERSION  the release tag (default v2026.3)
set -euo pipefail
version="${GOOSE_VERSION:-v2026.3}"
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)          asset="goose-$version-linux-x64.tar.gz" ;;
  Darwin-arm64)          asset="goose-$version-macos-arm64.tar.gz" ;;
  Darwin-x86_64)         asset="goose-$version-macos-x64.tar.gz" ;;
  MINGW*|MSYS*|CYGWIN*)  asset="goose-$version-windows-x64.zip" ;;
  *) echo "no Goose release for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
dir="$RUNNER_TEMP/goose"
mkdir -p "$dir"
curl -fsSL -o "$RUNNER_TEMP/$asset" "https://github.com/aardappel/goose/releases/download/$version/$asset"
case "$asset" in
  *.zip) unzip -q "$RUNNER_TEMP/$asset" -d "$dir" ;;
  *)     tar -xzf "$RUNNER_TEMP/$asset" -C "$dir" ;;
esac
exe="$(find "$dir" -type f \( -name goose -o -name goose.exe \) | head -1)"
[ -n "$exe" ] || { echo "no goose executable in $asset" >&2; exit 1; }
chmod +x "$exe"
dirname "$exe" >> "$GITHUB_PATH"
"$exe" version
