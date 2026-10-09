# AGENTS.md

Guidance for coding agents working in this repo. Humans: start with [README.md](README.md).

## What this is

A macOS menu-bar widget (Swift 6 / SwiftUI, SwiftPM, `LSUIElement`) that shows LLM usage across
providers. There is no Xcode project; everything builds with `swift build`.

Read before changing behaviour:

- [CONTEXT.md](CONTEXT.md): the domain glossary (Provider, Plan, Kind, Quota, Spend,
  LimitWindow, Balance, Budget, Progress, Snapshot). Use these terms in code, comments and
  commits, and avoid the synonyms it lists.
- [SPEC.md](SPEC.md) and [PHASES.md](PHASES.md): architecture, provider matrix, phased plan.
- [docs/adr/](docs/adr/): decisions. Add an ADR when you make a decision that is hard to reverse.

## Build, run, verify

```bash
./run.sh            # build → package .build/FullLLMUsageWidget.app → sign → launch
./run.sh --check    # in-process self-check suite; must print "Self-check OK"
swift build -c release   # compile only
```

Run `./run.sh --check` after every change. New parsing, backoff or snapshot logic should come
with a check in `Sources/UsageWidget/App/SelfCheck.swift`. There is no XCTest target.

### Gotcha: macOS 27 SDK breaks `@State` with Command Line Tools only

If only the Command Line Tools are installed (`xcode-select -p` →
`/Library/Developer/CommandLineTools`, no Xcode.app), the default `MacOSX27.0.sdk` makes
`@State` a macro. Its plugin (`SwiftUIMacros`) does not ship with the CLT, so the build fails
with:

```
error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'
```

That first error then cascades into misleading follow-ups such as
`cannot assign to property: 'self' is immutable` in `SignInView.swift`. **Do not "fix" the code.**
Build against the 26.x SDK instead:

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
./run.sh            # and ./run.sh --check
```

`run.sh` and `Scripts/package_app.sh` call plain `swift build`, so they pick up `SDKROOT`.
CI is not affected because it pins Xcode 16.2 on `macos-14`.

### Gotcha: dev code-signing identity

`run.sh` signs with a self-signed identity, `Full LLM Usage Widget`, so the Keychain keeps
"Always Allow" across rebuilds. If it prints `codesign failed; launching ad-hoc signed`, check:

```bash
security find-identity -v -p codesigning | grep "Full LLM"
```

`Invalid Key Usage for policy` means the cert is unusable (or untrusted). The app still runs
ad-hoc signed, but the Keychain will prompt again on each rebuild. This is a machine-setup
issue, not a code issue; the trust steps are in the `run.sh` warning text. Never commit
signing material.

## Code layout (`Sources/UsageWidget/`)

| Dir | Role |
|---|---|
| `Domain/` | pure model types: `Plan`, `Kind`, `LimitWindow`, `Progress`, `Snapshot`, `UsageProvider` protocol |
| `Engine/` | refresh scheduling, backoff, snapshot cache, near-limit notifications |
| `Providers/<Name>/` | one folder per Provider: `*Provider` (conforms to `UsageProvider`), `*Fetcher` (HTTP/parsing), optional `*OAuthClient` |
| `Auth/` | OAuth (PKCE, loopback server), Keychain credential storage |
| `MenuBar/`, `Views/` | status item, popover, SwiftUI views |
| `Settings/` | persisted settings and settings UI |
| `App/` | entry point, `CompositionRoot` (wiring), `SelfCheck` |

To add a Provider: add `Providers/<Name>/`, register it in `App/CompositionRoot.swift` (and note
it in the overview comment in `Providers/Providers.swift`), add self-checks for its parser, and document any unusual data
acquisition in `docs/` plus an ADR (see the Gemini and Mistral examples).

## Conventions

- Swift 6 strict concurrency; minimum target macOS 14 (`Package.swift`).
- Secrets live only in the Keychain (`Auth/KeychainStore.swift`), never in `UserDefaults`,
  logs or snapshots.
- Commits use gitmoji + conventional type, e.g. `✨ feat: …`, `🚀 ci: …`, `📝 docs: …`,
  `⚰️ refactor: …`.
- Releases are cut by CI from git tags (SemVer; patch auto-bumps on merge to `main`). Don't
  edit the version in `Support/Info.plist`.
