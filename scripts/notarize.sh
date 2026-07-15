#!/bin/bash
# Submits an artifact to Apple's notary service and staples the ticket.
# Usage: scripts/notarize.sh <path-to-.app|.dmg|.zip>
#
# A .app can't be submitted directly — it's zipped for submission, then the
# ticket is stapled onto the .app itself. A .dmg/.zip is submitted and stapled
# as-is.
#
# Required env (App Store Connect API key):
#   APPLE_API_KEY_ID        the key's ID
#   APPLE_API_ISSUER_ID     the issuer UUID
#   APPLE_API_KEY_P8_BASE64 base64 of the AuthKey_XXXX.p8 file
#   RUNNER_TEMP             provided by GitHub Actions
set -euo pipefail

TARGET="${1:?usage: notarize.sh <path>}"
: "${APPLE_API_KEY_ID:?}"
: "${APPLE_API_ISSUER_ID:?}"
: "${APPLE_API_KEY_P8_BASE64:?}"
: "${RUNNER_TEMP:?}"

KEY_PATH="${RUNNER_TEMP}/AuthKey.p8"
echo "${APPLE_API_KEY_P8_BASE64}" | base64 --decode > "${KEY_PATH}"

submit() {
  xcrun notarytool submit "$1" \
    --key "${KEY_PATH}" \
    --key-id "${APPLE_API_KEY_ID}" \
    --issuer "${APPLE_API_ISSUER_ID}" \
    --wait
}

case "${TARGET}" in
  *.app)
    ZIP="${RUNNER_TEMP}/notarize-$(basename "${TARGET}").zip"
    ditto -c -k --keepParent "${TARGET}" "${ZIP}"
    echo "▸ notarizing ${TARGET} (submitting ${ZIP})"
    submit "${ZIP}"
    xcrun stapler staple "${TARGET}"
    ;;
  *)
    echo "▸ notarizing ${TARGET}"
    submit "${TARGET}"
    xcrun stapler staple "${TARGET}"
    ;;
esac

rm -f "${KEY_PATH}"
echo "✓ notarized + stapled ${TARGET}"
