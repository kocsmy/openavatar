#!/bin/bash
# Imports the Developer ID Application certificate into a temporary keychain so
# codesign can find it in CI. Prints the signing identity's common name on the
# last line (capture it into CODESIGN_IDENTITY).
#
# Required env:
#   DEVELOPER_ID_CERT_P12_BASE64  base64 of the exported .p12 (cert + private key)
#   DEVELOPER_ID_CERT_PASSWORD    password set when exporting the .p12
#   KEYCHAIN_PASSWORD             any throwaway password for the temp keychain
#   RUNNER_TEMP                   provided by GitHub Actions
set -euo pipefail

: "${DEVELOPER_ID_CERT_P12_BASE64:?}"
: "${DEVELOPER_ID_CERT_PASSWORD:?}"
: "${KEYCHAIN_PASSWORD:?}"
: "${RUNNER_TEMP:?}"

KEYCHAIN="${RUNNER_TEMP}/app-signing.keychain-db"
CERT_PATH="${RUNNER_TEMP}/developer_id.p12"

echo "${DEVELOPER_ID_CERT_P12_BASE64}" | base64 --decode > "${CERT_PATH}"

# Fresh keychain, unlocked, added to the search list so codesign can see it.
security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
security set-keychain-settings -lut 21600 "${KEYCHAIN}"
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
security import "${CERT_PATH}" -P "${DEVELOPER_ID_CERT_PASSWORD}" \
  -A -t cert -f pkcs12 -k "${KEYCHAIN}"
# Let codesign use the key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}" >/dev/null
# Keep the login keychain in the list too, but search ours first.
security list-keychains -d user -s "${KEYCHAIN}" \
  $(security list-keychains -d user | sed 's/[";]//g')

rm -f "${CERT_PATH}"

# Emit the identity name (e.g. "Developer ID Application: Name (TEAMID)").
security find-identity -v -p codesigning "${KEYCHAIN}" \
  | awk -F'"' '/Developer ID Application/{print $2; exit}'
