# Full LLM Usage Widget

A macOS menu-bar widget showing live LLM consumption across providers, unifying **quota** and
**spend** under a single "progress toward a limit" view. Native Swift 6 / SwiftUI, menu-bar-only
(`LSUIElement`).

- [CONTEXT.md](CONTEXT.md) — domain glossary.
- [SPEC.md](SPEC.md) — spec, architecture, provider matrix, phased plan.
- [docs/adr/](docs/adr/) — key decisions.
- [docs/cursor-full-disk-access.md](docs/cursor-full-disk-access.md) — Cursor opt-in / Full Disk Access.
- [docs/gemini-gcp-billing.md](docs/gemini-gcp-billing.md) — Gemini "Actual billed spend (GCP)" setup.

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

## GitHub Actions release

`.github/workflows/release.yml` builds a signed + notarized **arm64** `.dmg` and publishes a
GitHub Release automatically when a PR is merged into `main` — or when a commit is pushed directly
to `main` (fallback). The merged PR's title + body become the release note, and the `.dmg` is
attached as the asset.

Add these secrets under **Repository → Settings → Secrets and variables → Actions**:

| Secret | Description | Example |
|---|---|---|
| `APPLE_CERTIFICATE` | base64 of the `Developer ID Application` `.p12` (cert + private key) | see below |
| `APPLE_CERTIFICATE_PASSWORD` | the `.p12` export password | |
| `APPLE_SIGNING_IDENTITY` | signing identity name (same as local `DEV_ID`) | `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID` | Apple ID email (notarytool login) | `you@example.com` |
| `APPLE_TEAM_ID` | Apple Developer team id | `XXXXXXXXXX` |
| `APPLE_APP_PASSWORD` | app-specific password (same as local `APP_PW`) | `xxxx-xxxx-xxxx-xxxx` |

The last four are the same values you use locally for `./run.sh --release`. `APPLE_CERTIFICATE`
and `APPLE_CERTIFICATE_PASSWORD` are new — CI needs the cert in the repo's secrets because it
can't reach your local Keychain.

### Exporting the certificate

Find the identity, export it as a `.p12` (Keychain Access → right-click the identity → Export,
or `security export`), then base64-encode it for the secret:

```bash
security find-identity -v -p codesigning        # note the "Developer ID Application: ..." identity
base64 -i DeveloperIDApplication.p12 | pbcopy   # paste the clipboard into APPLE_CERTIFICATE
```

### Versioning

Versions are SemVer derived from git tags, not the plist. Every merge into `main` auto-bumps
the **patch** (`v0.1.0` → `v0.1.1` → `v0.1.2` …). The computed version is written into the built
app's `CFBundleShortVersionString`, so the shipped `.dmg` matches the release; `Support/Info.plist`
stays as a `0.1.0` bootstrap.

To bump **minor** (`v0.2.0`) or **major** (`v1.0.0`), run the workflow manually:

> **Actions → Release → Run workflow → bump: `minor`** (or `major`)

Subsequent merges then continue from the new version (`v0.2.0` → `v0.2.1` …,
`v1.0.0` → `v1.0.1` …).

## Scripts

| Script | Purpose |
|---|---|
| `run.sh` | dev loop + `--check` + `--release` |
| `Scripts/package_app.sh` | build the SwiftPM executable and wrap it in a `.app` bundle |
| `Scripts/notarize.sh` | Developer ID + hardened runtime sign, `notarytool`, `stapler` |
| `Scripts/release.sh` | wrap the stapled `.app` in a signed `.dmg` |
| `make_icon` | render `Support/AppIcon.icns` |
