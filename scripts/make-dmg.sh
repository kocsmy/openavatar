#!/bin/zsh
# Builds a drag-and-drop DMG installer: OpenAvatar.app + /Applications symlink.
# Runs make-app.sh first unless build/OpenAvatar.app already exists.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/OpenAvatar.app"
DMG="build/OpenAvatar.dmg"
STAGE="build/dmg-stage"

if [[ ! -d "${APP}" ]]; then
  ./scripts/make-app.sh release
fi

echo "▸ staging DMG contents"
rm -rf "${STAGE}" "${DMG}"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

echo "▸ hdiutil create"
hdiutil create -volname "OpenAvatar" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}"
rm -rf "${STAGE}"

echo "✓ Built ${DMG}"
echo "  Note: the app is ad-hoc signed (not notarized). After dragging to"
echo "  Applications, first launch needs: xattr -cr /Applications/OpenAvatar.app"
