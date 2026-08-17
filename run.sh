#!/usr/bin/env bash
set -euo pipefail

# Build → package .app → launch (or `--check` self-check runner).
# Mirrors the reference LLM-Usage-Widget's run.sh.

cd "$(dirname "$0")"

APP_NAME="FullLLMUsageWidget"   # .app bundle name
EXECUTABLE="UsageWidget"        # SwiftPM target / binary name
APP_BUNDLE=".build/${APP_NAME}.app"

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
