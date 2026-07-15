#!/bin/zsh
# Builds OpenAvatar.app from the SwiftPM package.
# SwiftPM executables can't carry Info.plist/TCC usage strings on their own,
# so this assembles a proper .app bundle (with the Sparkle auto-update
# framework embedded) and ad-hoc signs it.
#
# Env: VERSION (CFBundleShortVersionString, default 0.0.0-dev)
#      BUILD_NUMBER (CFBundleVersion, must increase per release, default 1)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/OpenAvatar.app"
VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

echo "▸ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN="$(swift build -c "${CONFIG}" --show-bin-path)/OpenAvatar"

echo "▸ assembling ${APP} (v${VERSION}, build ${BUILD_NUMBER})"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Frameworks"
cp "${BIN}" "${APP}/Contents/MacOS/OpenAvatar"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "${VERSION}" "${APP}/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${BUILD_NUMBER}" "${APP}/Contents/Info.plist"

# Embed the Sparkle framework (SwiftPM binary artifact) so auto-update works
# from the bundle.
SPARKLE_FW="$(find .build -type d -name 'Sparkle.framework' -path '*macos*' | head -1 || true)"
if [[ -n "${SPARKLE_FW}" ]]; then
  echo "▸ embedding Sparkle.framework"
  cp -R "${SPARKLE_FW}" "${APP}/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${APP}/Contents/MacOS/OpenAvatar" 2>/dev/null || true
else
  echo "⚠ Sparkle.framework not found in .build — auto-update disabled in this build"
fi

echo "▸ codesign (ad-hoc, with entitlements)"
# Sign nested frameworks first, then the app with the keychain-access-group
# entitlement so the data-protection keychain grants silent access to our
# own items (no repeated login-keychain password prompts across updates).
#
# CRITICAL: Sparkle.framework ships nested helper binaries (Autoupdate,
# Updater.app, XPCServices/*.xpc). They must each be validly signed or macOS
# refuses to launch the whole app ("OpenAvatar.app can't be opened"). --deep
# signs every nested executable inside the framework in one pass; without it
# only the framework's own Mach-O gets a signature and the helpers stay
# unsigned. Sign nested items before the outer bundle that references them.
find "${APP}/Contents/Frameworks" -name '*.framework' -maxdepth 1 -print 2>/dev/null | while read -r fw; do
  codesign --force --deep --sign - "${fw}"
done
codesign --force --sign - \
  --entitlements Resources/OpenAvatar.entitlements \
  --identifier com.openavatar.app \
  "${APP}"

echo "▸ verifying signature (Gatekeeper launch validity)"
codesign --verify --deep --strict --verbose=2 "${APP}"

echo "✓ Built ${APP}"
echo "  Run with: open ${APP}"
