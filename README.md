# Full LLM Usage Widget

A macOS menu-bar widget showing live LLM consumption across providers, unifying **quota** and
**spend** under a single "progress toward a limit" view. Native Swift 6 / SwiftUI, menu-bar-only
(`LSUIElement`).

- [CONTEXT.md](CONTEXT.md) — domain glossary.
- [SPEC.md](SPEC.md) — spec, architecture, provider matrix, phased plan.
- [docs/adr/](docs/adr/) — key decisions.
- [docs/cursor-full-disk-access.md](docs/cursor-full-disk-access.md) — Cursor opt-in / Full Disk Access.

## Build & run

```bash
./run.sh            # build → package .app → launch (dev loop, self-signed)
./run.sh --check    # self-check suite (parsing, backoff, snapshot, Cursor reader)
./run.sh --release  # Developer ID sign → notarize → staple → signed .dmg
```

Requires only what ships with macOS (`swift`, `codesign`, `hdiutil`, `xcrun`). The dev loop
auto-creates a durable self-signed identity so the Keychain can remember "Always Allow" across
rebuilds; it is not a Developer ID.

## Release: environment variables

`./run.sh --release` needs four variables. Put them in `~/.config/fllm-signing/notarize.env`
(git-ignored, `chmod 600`), or export them in your shell — the file is sourced first, then the
environment takes precedence.

| Variable | Description | Example |
|---|---|---|
| `DEV_ID` | `Developer ID Application` signing identity | `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID` | Apple ID email (notarytool login) | `you@example.com` |
| `TEAM_ID` | Apple Developer team id | `XXXXXXXXXX` |
| `APP_PW` | App-specific password (not your account password) | `xxxx-xxxx-xxxx-xxxx` |

`notarize.env`:

```bash
DEV_ID="Developer ID Application: Name (TEAMID)"
APPLE_ID="you@example.com"
TEAM_ID="XXXXXXXXXX"
APP_PW="xxxx-xxxx-xxxx-xxxx"
```

### Getting the credentials

- **`DEV_ID`** — a "Developer ID Application" certificate installed in the Keychain (see
  `security find-identity -v -p codesigning`). Requires a paid Apple Developer account, plus the
  Apple intermediate `Developer ID Certification Authority G2` in the Keychain (Apple ships it via
  Xcode; otherwise download it from
  [apple.com/certificateauthority](https://www.apple.com/certificateauthority/)).
- **`APP_PW`** — an app-specific password from
  [appleid.apple.com](https://account.apple.com) → Sign-In & Security → App-Specific Passwords.
  Create one per machine; it is **not** your Apple ID password.

### Output

```text
.build/FullLLMUsageWidget.app        # signed + notarized + stapled
dist/Full-LLM-Usage-Widget.dmg       # signed .dmg, drag to /Applications
```

Verify the notarized app:

```bash
spctl --assess --type execute --verbose=4 .build/FullLLMUsageWidget.app
```

## Scripts

| Script | Purpose |
|---|---|
| `run.sh` | dev loop + `--check` + `--release` |
| `Scripts/package_app.sh` | build the SwiftPM executable and wrap it in a `.app` bundle |
| `Scripts/notarize.sh` | Developer ID + hardened runtime sign, `notarytool`, `stapler` |
| `Scripts/release.sh` | wrap the stapled `.app` in a signed `.dmg` |
| `make_icon` | render `Support/AppIcon.icns` |
