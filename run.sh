#!/usr/bin/env bash
set -euo pipefail

# Build → package .app → launch (or `--check` self-check runner).
# Mirrors the reference LLM-Usage-Widget's run.sh.

cd "$(dirname "$0")"

APP_NAME="FullLLMUsageWidget"   # .app bundle name
EXECUTABLE="UsageWidget"        # SwiftPM target / binary name
APP_BUNDLE=".build/${APP_NAME}.app"

# Stable code-signing identity. SwiftPM linker-signs ad hoc, so the cdhash changes on every
# rebuild and the Keychain can't remember "Always Allow" — it re-prompts for the login keychain
# password per secret. Signing with a durable self-signed identity lets the Keychain bind its ACL
# to a stable `anchor` + bundle id instead.
SIGN_ID="Full LLM Usage Widget"
SIGN_DIR="$HOME/.config/fllm-signing"
SIGN_CERT="$SIGN_DIR/fllm-signing.cer"
SIGN_KEY="$SIGN_DIR/fllm-signing.key"
SIGN_P12="$SIGN_DIR/fllm-signing.p12"
SIGN_P12_PASSWORD="fllm-signing"   # local-only; the key lives in the Keychain after import

# Create the signing identity if it's missing (idempotent). The private key is imported into the
# login keychain and the on-disk key/p12 copies are removed.
ensure_signing_identity() {
  if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    return 0
  fi
  echo "== create code-signing identity '$SIGN_ID' =="
  mkdir -p "$SIGN_DIR"
  if ! openssl req -new -x509 -days 3650 -nodes -newkey rsa:2048 \
        -keyout "$SIGN_KEY" -out "$SIGN_CERT" \
        -subj "/CN=$SIGN_ID" -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1; then
    echo "⚠️  failed to generate signing certificate" >&2
    return 0
  fi
  if openssl pkcs12 -export -inkey "$SIGN_KEY" -in "$SIGN_CERT" \
        -out "$SIGN_P12" -passout "pass:$SIGN_P12_PASSWORD" >/dev/null 2>&1; then
    security import "$SIGN_P12" -k "$HOME/Library/Keychains/login.keychain-db" \
      -P "$SIGN_P12_PASSWORD" -T /usr/bin/codesign >/dev/null 2>&1 || true
  fi
  rm -f "$SIGN_KEY" "$SIGN_P12"
}

# Sign the .app if the identity is trusted. A self-signed cert must be trusted once before
# `codesign` will use it (admin, one-time); until then we warn and leave the app ad-hoc signed.
sign_app() {
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    if codesign --force --sign "$SIGN_ID" "$APP_BUNDLE" >/dev/null 2>&1; then
      echo "Signed $APP_BUNDLE with '$SIGN_ID'"
    else
      echo "⚠️  codesign failed; launching ad-hoc signed" >&2
    fi
  else
    cat >&2 <<EOF
⚠️  '$SIGN_ID' is not yet trusted, so the app stays ad-hoc signed and the Keychain will keep
    prompting. Trust it once, then re-run ./run.sh:

      sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$SIGN_CERT"

    (or: Keychain Access → find "$SIGN_ID" → Get Info → Always Trust)
EOF
  fi
}

self_check() {
  echo "== self-check =="
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
  # In-process checks: backoff, progress normalization, snapshot round-trip.
  "$BIN_DIR/$EXECUTABLE" --check
}

build_app() {
  echo "== build =="
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"

  echo "== package =="
  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_BUNDLE/Contents/MacOS"
  cp "$BIN_DIR/$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
  cp "Support/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
  if [[ -f "Support/AppIcon.icns" ]]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources"
    cp "Support/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
  fi
  ensure_signing_identity
  sign_app
  echo "Packaged $APP_BUNDLE"
}

launch() {
  echo "== launch =="
  open "$APP_BUNDLE"
}

if [[ "${1:-}" == "--check" ]]; then
  self_check
  exit 0
fi

build_app
launch
