#!/usr/bin/env bash
#
# notarize.sh - sign with a Developer ID + hardened runtime, notarize, and staple.
# Mirrors the reference LLM-Usage-Widget's Scripts/notarize.sh.
# Requires a paid Apple Developer account with a "Developer ID Application" certificate installed.
#
# Usage:
#   DEV_ID="Developer ID Application: Your Name (TEAMID)" \
#   APPLE_ID="you@example.com" TEAM_ID="TEAMID" APP_PW="app-specific-password" \
#   Scripts/notarize.sh
#
# Get APP_PW from appleid.apple.com > Sign-In & Security > App-Specific Passwords.
# After this succeeds, run Scripts/release.sh to wrap the notarized .app in a signed .dmg.

set -euo pipefail

APP_NAME="FullLLMUsageWidget"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

: "${DEV_ID:?set DEV_ID to your 'Developer ID Application: Name (TEAMID)' identity}"
: "${APPLE_ID:?set APPLE_ID to your Apple ID email}"
: "${TEAM_ID:?set TEAM_ID to your Apple Developer team id}"
: "${APP_PW:?set APP_PW to an app-specific password}"

echo "==> Building release .app..."
"${ROOT}/Scripts/package_app.sh" release

APP="${ROOT}/.build/${APP_NAME}.app"

echo "==> Signing with Developer ID + hardened runtime..."
codesign --force --options runtime --timestamp --sign "${DEV_ID}" "${APP}"
codesign --verify --strict --verbose=2 "${APP}"

DIST="${ROOT}/dist"
mkdir -p "${DIST}"
ZIP="${DIST}/${APP_NAME}-notarize.zip"
/usr/bin/ditto -c -k --keepParent "${APP}" "${ZIP}"

echo "==> Submitting to notarytool (a few minutes)..."
xcrun notarytool submit "${ZIP}" \
  --apple-id "${APPLE_ID}" --team-id "${TEAM_ID}" --password "${APP_PW}" --wait

echo "==> Stapling the ticket..."
xcrun stapler staple "${APP}"
rm -f "${ZIP}"

echo ""
echo "OK: ${APP} is signed + notarized + stapled."
echo "Verify locally:"
echo "  spctl --assess --type execute --verbose=4 \"${APP}\""
echo "Now run Scripts/release.sh to produce a signed .dmg."
