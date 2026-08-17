#!/usr/bin/env bash
#
# release.sh - wrap the notarized + stapled .app in a drag-to-Applications .dmg and sign it.
# Run Scripts/notarize.sh first (which produces .build/FullLLMUsageWidget.app).

set -euo pipefail

APP_NAME="FullLLMUsageWidget"
DMG_NAME="Full-LLM-Usage-Widget"
VOL_NAME="Full LLM Usage Widget"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

APP="${ROOT}/.build/${APP_NAME}.app"
if [[ ! -d "${APP}" ]]; then
  echo "ERROR: ${APP} not found. Run Scripts/notarize.sh first." >&2
  exit 1
fi

DIST="${ROOT}/dist"
mkdir -p "${DIST}"
DMG_PATH="${DIST}/${DMG_NAME}.dmg"
rm -f "${DMG_PATH}"

STAGE="$(mktemp -d)"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

echo "==> Creating .dmg..."
hdiutil create -volname "${VOL_NAME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG_PATH}" >/dev/null
rm -rf "${STAGE}"

echo "==> Signing .dmg..."
if [[ -n "${DEV_ID:-}" ]]; then
  codesign --force --sign "${DEV_ID}" "${DMG_PATH}"
else
  echo "⚠️  DEV_ID not set — .dmg left unsigned. Set DEV_ID to sign it."
fi

SIZE="$(du -h "${DMG_PATH}" | cut -f1)"
echo ""
echo "OK: wrote ${DMG_PATH} (${SIZE})"
echo "To install: open the .dmg and drag ${APP_NAME} to Applications."
echo "Verify the notarized app inside:"
echo "  spctl --assess --type execute --verbose=4 \"/Applications/${APP_NAME}.app\""
