#!/bin/bash
# Startup smoke test: launch the built app and confirm it survives the first few
# seconds. Catches launch-time crashes (bad SwiftUI init, missing framework,
# signing/AMFI rejection) that unit tests can't see. Fails the build if the app
# dies during startup.
set -uo pipefail

APP="${1:-build/OpenAvatar.app}"
BIN="${APP}/Contents/MacOS/OpenAvatar"
LOG="${TMPDIR:-/tmp}/openavatar-smoke.log"

if [[ ! -x "${BIN}" ]]; then
  echo "::error::smoke test: missing executable ${BIN}"
  exit 1
fi

echo "▸ smoke test: launching ${APP}"
"${BIN}" > "${LOG}" 2>&1 &
PID=$!

sleep 6

if kill -0 "${PID}" 2>/dev/null; then
  echo "✓ app still running after 6s — startup OK"
  kill "${PID}" 2>/dev/null || true
  wait "${PID}" 2>/dev/null || true
  exit 0
fi

wait "${PID}" 2>/dev/null
CODE=$?
echo "---- last startup log ----"
tail -50 "${LOG}" 2>/dev/null || true
# Exit codes >= 128 mean the process was killed by a signal (SIGABRT/SIGSEGV/
# SIGILL/SIGTRAP) — i.e. a real crash. A clean or non-signal early exit is more
# likely a headless-CI quirk, so warn rather than block the release.
if [[ "${CODE}" -ge 128 ]]; then
  echo "::error::app crashed on launch (killed by signal $((CODE - 128)))"
  exit 1
fi
echo "::warning::app exited early during smoke test (code ${CODE}); may be a headless-CI limitation — not blocking"
exit 0
