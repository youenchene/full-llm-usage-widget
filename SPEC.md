# Full LLM Usage Widget — Spec

A macOS menu-bar widget showing live LLM consumption across eight plans, unifying **quota** and **spend** providers under a single "progress toward a limit" view. Native Swift 6 / SwiftUI, menu-bar-only (`LSUIElement`).

## Goal

Answer one question at a glance: *"Am I about to hit a limit, or overspend, on any of my LLM providers?"* — with per-provider detail a click away.

## Scope

### In scope (v1)

Eight plans across seven providers:

| Plan | Kind | Limit signal | Auth / data source | Confidence |
|---|---|---|---|---|
| Claude | quota | 5h + weekly | OAuth paste-code → `api.anthropic.com/api/oauth/usage` | High |
| Codex | quota | 5h + weekly | OAuth browser → `chatgpt.com/backend-api/wham/usage` | High |
| Copilot | quota | monthly premium requests | GitHub device flow → `api.github.com/copilot_internal/user` | High |
| Gemini | quota | rate-limit / quota | API key → AI Studio / Antigravity | Low |
| OpenCode Go | quota | $12/5h · $30/wk · $60/mo | API key / console → `opencode.ai/auth` | Medium |
| Mistral | spend | € | admin API key → `api.mistral.ai/v1/admin/usage` | High |
| Scaleway | spend | € | secret key (`X-Auth-Token`) → Billing API | Medium |
| OpenCode Zen | spend | $ balance | API key / console → `opencode.ai/auth` | Medium |

### Deferred (v2+)

- **Cursor** — no public usage API; would need Full Disk Access to read its local SQLite, or a dashboard scrape. Deliberately deferred.
- **Notarization** — the user has a signing setup; defer until distribution beyond the user's own Mac.

## Domain model

See `CONTEXT.md`. The load-bearing terms: **Provider** (one auth) → **Plan** (N usage entities; OpenCode has Go + Zen) → **Kind** (`quota` | `spend`) → **Progress** (normalized 0–1).

## Architecture

Borrowed from `LLM-Usage-Widget`, owned, not forked:

```
Sources/UsageWidget/
  App/         @main entry, AppDelegate, composition root
  MenuBar/     menu-bar gauge label + popover root
  Domain/      UsageProvider protocol, LimitWindow, ProviderUsage, Progress
  Providers/   one module per provider (Claude, Codex, Copilot, Gemini, OpenCode, Mistral, Scaleway)
  Auth/        OAuth (PKCE), device flow, Keychain-backed token/secret store, console-scrape helper
  Engine/      UsageStore (@Observable), RefreshScheduler, BackoffPolicy, SnapshotCache
  Settings/    SettingsModel/View, LaunchAtLogin (SMAppService)
  Views/       design tokens, plan card, progress bar, states
```

Each provider conforms to `UsageProvider`, returning a normalized `ProviderUsage` (one or more `LimitWindow`s for quota; a balance plus spent figure for spend). The engine polls on per-provider intervals with exponential backoff and caches the last-good snapshot.

## Consumption model

- **Quota** plan → progress = `used / limit` per `LimitWindow`; render % bars + reset countdown.
- **Spend** plan → raw currency always shown; an optional user **Budget** turns it into a % toward that budget.
- **Menu bar** shows the single most-urgent plan (closest to limit/budget); an unset budget means "no urgency."

## Data acquisition

Isolated per provider behind `UsageProvider`. Secrets (OAuth tokens, API keys, session cookies) live in the Keychain. OpenCode Go/Zen and the exact Scaleway/Gemini endpoints are confirmed in a **v1 spike** (see Phased plan).

## Storage

Local-only, simplest possible: a last-good **snapshot cache** under `~/Library/Application Support/`, no history database in v1.

## Distribution

Ad-hoc signed `.app`, menu-bar-only, launch-at-login via `SMAppService`, built for the user's own Mac. Notarization deferred to v2.

## Phased plan

**Phase 0 — Spike (blocking, three uncertain endpoints).** Confirm, with a throwaway script, the real endpoints for Gemini, Scaleway, and OpenCode Go/Zen usage: does OpenCode expose a usage endpoint behind its API key, or must we scrape the console? What is the exact Scaleway billing call? What does Gemini's Antigravity / AI Studio usage endpoint return? These three results gate everything else.

**Phase 1 — Skeleton.** Composition root, `Domain` model, `Engine` (store, scheduler, backoff, snapshot cache), menu-bar label + empty popover. No providers yet.

**Phase 2 — High-confidence providers.** Claude, Codex, Copilot, Mistral (endpoints known). Auth flows + fetchers + plan cards end-to-end.

**Phase 3 — Remaining providers.** Gemini, Scaleway, OpenCode Go + Zen, using the spike's findings.

**Phase 4 — Polish.** Settings (enable/disable, budgets, menu-bar focus, thresholds, launch-at-login), near-limit notifications, app icon, self-checks (`--check`, like the reference).

**Phase 5 — v2 backlog.** Cursor provider (Full-Disk-Access SQLite read or dashboard scrape), notarization + signed `.dmg`.

## Risks

- **Undocumented endpoints** (Claude/Codex/Copilot already; OpenCode/Gemini/Scaleway to be found) may change without notice — mitigated by snapshot cache + graceful degradation.
- **Gemini migration** (to Antigravity) is in flight — highest chance of a breaking change in v1.
- **OpenCode usage access** is console-only today; a cookie-scrape fallback is fragile (cookie expiry).
- **Rate limits** on quota endpoints require backoff + last-good cache.

## Non-goals

- No cost accounting or invoicing — this is consumption *surfacing*, not billing.
- No cross-platform (Windows) build.
- No cloud/history mirror in v1.
- No automated inference — read-only usage queries.
