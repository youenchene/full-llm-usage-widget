#!/usr/bin/env bash
set -euo pipefail

# Build the SwiftPM executable and wrap it in a proper .app bundle (unsigned).
#
# Used by the notarization/release pipeline. The dev loop (`run.sh`) keeps its own packaging with
# a self-signed identity so the Keychain can bind its ACL to a stable anchor; that identity is not
# a Developer ID, so release builds must be signed + notarized separately (Scripts/notarize.sh).
#
# Usage: Scripts/package_app.sh [debug|release]   (default: release)

APP_NAME="FullLLMUsageWidget"
EXECUTABLE="UsageWidget"
APP_BUNDLE=".build/${APP_NAME}.app"
CONFIG="${1:-release}"

cd "$(dirname "$0")/.."

echo "==> Building (${CONFIG})..."
swift build -c "${CONFIG}"
BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${EXECUTABLE}"

if [[ ! -f "${BIN_PATH}" ]]; then
  echo "ERROR: built binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> Packaging ${APP_BUNDLE} ..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE}"
cp "Support/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
if [[ -f "Support/AppIcon.icns" ]]; then
  mkdir -p "${APP_BUNDLE}/Contents/Resources"
  cp "Support/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

echo "OK: packaged ${APP_BUNDLE} (unsigned)"
