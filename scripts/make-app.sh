#!/bin/zsh
# Builds OpenAvatar.app from the SwiftPM package.
# SwiftPM executables can't carry Info.plist/TCC usage strings on their own,
# so this assembles a proper .app bundle and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/OpenAvatar.app"

echo "▸ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN="$(swift build -c "${CONFIG}" --show-bin-path)/OpenAvatar"

echo "▸ assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/OpenAvatar"
cp Resources/Info.plist "${APP}/Contents/Info.plist"

echo "▸ codesign (ad-hoc)"
codesign --force --deep --sign - "${APP}"

echo "✓ Built ${APP}"
echo "  Run with: open ${APP}"
