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

# Bake in the built-in Google OAuth client (Desktop-app type) so users get a
# one-click "Connect Google Calendar" with no per-user Google Cloud setup.
# Sourced from CI secrets; absent in local dev builds (app then uses BYO creds).
if [[ -n "${GOOGLE_OAUTH_CLIENT_ID:-}" && -n "${GOOGLE_OAUTH_CLIENT_SECRET:-}" ]]; then
  plutil -replace GoogleOAuthClientID -string "${GOOGLE_OAUTH_CLIENT_ID}" "${APP}/Contents/Info.plist"
  plutil -replace GoogleOAuthClientSecret -string "${GOOGLE_OAUTH_CLIENT_SECRET}" "${APP}/Contents/Info.plist"
  # Client IDs are public; the secret is never printed. This just confirms the
  # one-click calendar client was baked in.
  echo "▸ built-in Google OAuth client embedded (one-click calendar enabled)"
else
  echo "▸ no built-in Google OAuth client — calendar will use the Advanced (BYO) fields"
fi

# App icon: generate AppIcon.icns from the 1024 master via sips + iconutil.
ICON_MASTER="design/icon-master-1024.png"
if [[ -f "${ICON_MASTER}" ]]; then
  echo "▸ generating AppIcon.icns"
  ICONSET="build/AppIcon.iconset"
  rm -rf "${ICONSET}"; mkdir -p "${ICONSET}"
  for pair in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
    px="${pair%%:*}"; name="${pair##*:}"
    sips -z "${px}" "${px}" "${ICON_MASTER}" --out "${ICONSET}/icon_${name}.png" >/dev/null
  done
  iconutil -c icns "${ICONSET}" -o "${APP}/Contents/Resources/AppIcon.icns"
else
  echo "⚠ ${ICON_MASTER} missing — building without a custom app icon"
fi

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

# Signing identity: set CODESIGN_IDENTITY to a "Developer ID Application: …"
# identity for a notarizable, hardened-runtime build. Left unset (or "-") it
# ad-hoc signs, which launches but isn't notarized.
#
# We never add keychain-access-groups: it's a restricted entitlement that even
# a real team signature validates against a provisioning profile we don't ship,
# and on ad-hoc it makes AMFI refuse to launch the app. A stable Developer ID
# signature already fixes the keychain re-prompt (the ACL is bound to the
# signature, which no longer changes each build), so the entitlement isn't
# needed. Under hardened runtime the app DOES need the audio-input entitlement
# for mic + system-audio capture — that one is unrestricted.
#
# CRITICAL: Sparkle.framework ships nested helper binaries (Autoupdate,
# Updater.app, XPCServices/*.xpc). They must each be validly signed with the
# same identity or macOS refuses to launch the app. --deep signs every nested
# executable in one pass. Sign nested items before the outer bundle.
IDENTITY="${CODESIGN_IDENTITY:--}"
SPARKLE_FRAMEWORK="${APP}/Contents/Frameworks/Sparkle.framework"

if [[ "${IDENTITY}" == "-" ]]; then
  echo "▸ codesign (ad-hoc, no entitlements)"
  # Ad-hoc: a blanket --deep is fine (no entitlements to preserve, not notarized).
  if [[ -d "${SPARKLE_FRAMEWORK}" ]]; then
    codesign --force --deep --sign - "${SPARKLE_FRAMEWORK}"
  fi
  codesign --force --sign - --identifier com.openavatar.app "${APP}"
else
  echo "▸ codesign (Developer ID + hardened runtime): ${IDENTITY}"
  HARDEN=(--force --options runtime --timestamp --sign "${IDENTITY}")
  # Sign Sparkle inside-out, preserving each helper's own entitlements. A
  # blanket --deep would strip the sandbox/network entitlements Sparkle's XPC
  # services ship with and break auto-update under hardened runtime. The (N)
  # glob qualifier is zsh nullglob so a missing path doesn't error.
  if [[ -d "${SPARKLE_FRAMEWORK}" ]]; then
    for helper in \
      "${SPARKLE_FRAMEWORK}"/Versions/*/XPCServices/*.xpc(N) \
      "${SPARKLE_FRAMEWORK}"/Versions/*/Autoupdate(N) \
      "${SPARKLE_FRAMEWORK}"/Versions/*/Updater.app(N); do
      codesign "${HARDEN[@]}" --preserve-metadata=entitlements "${helper}"
    done
    codesign "${HARDEN[@]}" "${SPARKLE_FRAMEWORK}"
  fi
  codesign "${HARDEN[@]}" \
    --entitlements Resources/OpenAvatar-hardened.entitlements \
    --identifier com.openavatar.app \
    "${APP}"
fi

echo "▸ verifying signature (launch validity)"
codesign --verify --deep --strict --verbose=2 "${APP}"

# Guard against the v1.4.x regression: keychain-access-groups on our signature
# blocks launch. Fail the build if it ever sneaks back in.
echo "▸ asserting no keychain-access-groups entitlement"
ENTS="$(codesign -d --entitlements - --xml "${APP}" 2>/dev/null || true)"
if printf '%s' "${ENTS}" | grep -q "keychain-access-groups"; then
  echo "::error::${APP} carries a keychain-access-groups entitlement; remove it."
  exit 1
fi

echo "✓ Built ${APP}"
echo "  Run with: open ${APP}"
