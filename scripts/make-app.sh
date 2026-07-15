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

echo "▸ codesign (ad-hoc, no entitlements)"
# We ad-hoc sign with NO custom entitlements. keychain-access-groups is a
# restricted entitlement that macOS only honors under a real Apple Developer
# team signature; on an ad-hoc (teamless) signature the integrity daemon (AMFI)
# rejects it and the whole app fails to launch ("OpenAvatar.app can't be
# opened"). KeychainStore uses the legacy keychain, which needs no entitlement.
#
# CRITICAL: Sparkle.framework ships nested helper binaries (Autoupdate,
# Updater.app, XPCServices/*.xpc). They must each be validly signed or macOS
# refuses to launch the whole app. --deep signs every nested executable inside
# the framework in one pass. Sign nested items before the outer bundle.
find "${APP}/Contents/Frameworks" -name '*.framework' -maxdepth 1 -print 2>/dev/null | while read -r fw; do
  codesign --force --deep --sign - "${fw}"
done
codesign --force --sign - --identifier com.openavatar.app "${APP}"

echo "▸ verifying signature (launch validity)"
codesign --verify --deep --strict --verbose=2 "${APP}"

# Guard against the v1.4.x regression: a restricted entitlement on an ad-hoc
# signature makes AMFI refuse to launch the app. Fail the build if any
# entitlement (esp. keychain-access-groups) sneaks back in.
echo "▸ asserting no restricted entitlements"
ENTS="$(codesign -d --entitlements - --xml "${APP}" 2>/dev/null || true)"
if printf '%s' "${ENTS}" | grep -q "keychain-access-groups"; then
  echo "::error::${APP} carries a keychain-access-groups entitlement; ad-hoc signing + AMFI will block launch. Remove it."
  exit 1
fi

echo "✓ Built ${APP}"
echo "  Run with: open ${APP}"
