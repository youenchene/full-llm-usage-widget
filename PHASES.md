# PHASES.md — One prompt per phase

Each section below is a **self-contained prompt** you can paste into a fresh agent session to execute that phase. They build on each other in order — Phase 0 gates Phases 2/3, and each phase assumes the prior ones are done.

Run them in order, commit between phases.

---

## Phase 0 — Spike: confirm the three uncertain endpoints

```text
You are working in the `Full-LLM-Usage-Widget` repo — a macOS menu-bar app (Swift 6 / SwiftUI)
that surfaces live LLM consumption across 8 plans, unifying quota and spend under a "progress
toward a limit" view.

Before writing anything, read these files in the repo and follow them exactly:
- CONTEXT.md        — domain glossary; use ONLY these terms (Provider, Plan, Kind, LimitWindow,
                      Balance, Budget, Progress, Snapshot). Do not invent new vocabulary.
- SPEC.md           — spec, architecture, provider matrix, phased plan.
- docs/adr/*.md     — why key decisions were made (greenfield not fork; unified consumption
                      model; heterogeneous data acquisition).

This is Phase 0 (the spike) of SPEC.md's plan. It is RESEARCH ONLY — write no production code.

Objective: nail down the exact usage endpoints + auth for the three uncertain providers.

1. OpenCode Go & Zen — determine whether an API key (Bearer) can query usage, or whether usage
   is only in the web console (opencode.ai/auth). Check the anomalyco/opencode source and docs
   for any usage/balance endpoint. If console-only, identify the scrape target (the page/API the
   console itself calls) and the cookie requirements.
2. Scaleway — find the exact Billing/FinOps API call (api.scaleway.com, `X-Auth-Token` header)
   that returns monthly spend for the "Generative APIs" product (slug `inference`). Give the full
   path and parameters.
3. Gemini — determine where individual usage lives: Google AI Studio, Antigravity
   (antigravity.google / `agy` CLI), or Google Cloud billing — and what it returns (quota %,
   rate limits, or cost).

Do NOT re-derive these already-confirmed facts (they're done):
- Claude  → GET api.anthropic.com/api/oauth/usage (+ /api/oauth/profile for the plan badge)
- Codex   → GET chatgpt.com/backend-api/wham/usage (5h + weekly windows)
- Copilot → GET api.github.com/copilot_internal/user (quota_snapshots + reset)
- Mistral → GET api.mistral.ai/v1/admin/usage (admin API key)

Deliverable: write `docs/spike-findings.md` with, per uncertain provider: endpoint URL, HTTP
method, auth (header/cookie), a real or representative JSON response, and a `verified` /
`unverified` flag. Optionally include a throwaway curl/python script demonstrating each endpoint.
Explicitly flag any provider that must be deferred to a later phase.

Verification: `docs/spike-findings.md` is concrete enough that Phase 2/3 can write fetchers with
no further research.
```

---

## Phase 1 — Skeleton

```text
You are working in the `Full-LLM-Usage-Widget` repo — a macOS menu-bar app (Swift 6 / SwiftUI)
that surfaces live LLM consumption across 8 plans, unifying quota and spend under a "progress
toward a limit" view.

Before writing anything, read these files in the repo and follow them exactly:
- CONTEXT.md        — domain glossary; use ONLY these terms (Provider, Plan, Kind, LimitWindow,
                      Balance, Budget, Progress, Snapshot). Do not invent new vocabulary.
- SPEC.md           — spec, architecture, provider matrix, phased plan.
- docs/adr/*.md     — why key decisions were made.

This is Phase 1 (skeleton) of SPEC.md's plan. Assume Phase 0 is done (docs/spike-findings.md
exists) but do not wire any providers yet.

Deliverables:
- Swift 6 package + app target with the module layout from SPEC.md "Architecture":
  App/, MenuBar/, Domain/, Providers/ (empty stub), Auth/ (empty stub), Engine/, Settings/, Views/.
- Domain/ — the model from CONTEXT.md: `UsageProvider` protocol, `Provider`, `Plan`, `Kind`
  (quota|spend), `LimitWindow` (used, limit, resetsAt), `Balance`, `Progress` (0–1 normalized).
- Engine/ — `UsageStore` (@Observable), `RefreshScheduler`, `BackoffPolicy`, `SnapshotCache`
  (read/write last-good JSON under ~/Library/Application Support/<bundle-id>/).
- MenuBar/ — menu-bar gauge label (LSUIElement, no Dock icon) + empty popover root.
- App/ — @main entry, AppDelegate, composition root wiring store + scheduler.
- Build scripts mirroring LLM-Usage-Widget: `run.sh` (build → package .app → launch) and a
  `--check` self-check runner stub.

Constraints: follow CONTEXT.md terms exactly; snapshot cache only (no history DB); keep
Providers/ and Auth/ stubbed but present so later phases slot in.

Verification: `swift build` succeeds; the app launches showing an empty/placeholder menu-bar
label and popover; `--check` runs (even if trivial).
```

---

## Phase 2 — High-confidence providers (Claude, Codex, Copilot, Mistral)

```text
You are working in the `Full-LLM-Usage-Widget` repo — a macOS menu-bar app (Swift 6 / SwiftUI)
that surfaces live LLM consumption across 8 plans, unifying quota and spend under a "progress
toward a limit" view.

Before writing anything, read these files in the repo and follow them exactly:
- CONTEXT.md        — domain glossary; use ONLY these terms. Do not invent new vocabulary.
- SPEC.md           — spec, architecture, provider matrix, phased plan.
- docs/adr/*.md     — why key decisions were made.

This is Phase 2 of SPEC.md's plan. Phase 1 (skeleton) is done; the Domain model and Engine exist.
Wire the four providers whose endpoints are already known.

For each provider, conform to `UsageProvider` and return a normalized `ProviderUsage`
(LimitWindows for quota; balance + spent for spend):

- Claude (quota, 5h + weekly): OAuth paste-code — Anthropic rejects loopback redirects, so show a
  code the user pastes back. GET api.anthropic.com/api/oauth/usage, sending the `anthropic-beta`
  header and a `claude-code/<ver>` User-Agent. Plan badge via
  GET api.anthropic.com/api/oauth/profile (fetch once, cache on token). Poll at most every 5 min
  with exponential backoff.
- Codex (quota, 5h + weekly): OAuth browser redirect with loopback capture on 127.0.0.1:1455.
  GET chatgpt.com/backend-api/wham/usage (primary 5h + secondary weekly windows).
- Copilot (quota, monthly premium requests): GitHub device flow (show a code, user enters it at
  github.com/login/device). GET api.github.com/copilot_internal/user (quota_snapshots + reset date).
- Mistral (spend): admin API key. GET api.mistral.ai/v1/admin/usage (cost/usage + currency).
  Optionally surface GET /v1/admin/spend-limit for its native monthly limit.

Deliverable: each provider renders as a plan card in the popover (quota → % bars + reset
countdown; spend → raw currency, or % if a budget is set).

Constraints: store tokens/keys in the Keychain only; on a failed refresh fall back to the
last-good snapshot with a clear stale/error status — never crash, never blank the UI.

Verification: `--check` self-checks pass (parsing, PKCE, backoff); sign in and see live usage for
each of the four providers.
```

---

## Phase 3 — Remaining providers (Gemini, Scaleway, OpenCode Go + Zen)

```text
You are working in the `Full-LLM-Usage-Widget` repo — a macOS menu-bar app (Swift 6 / SwiftUI)
that surfaces live LLM consumption across 8 plans, unifying quota and spend under a "progress
toward a limit" view.

Before writing anything, read these files in the repo and follow them exactly:
- CONTEXT.md        — domain glossary; use ONLY these terms. Do not invent new vocabulary.
- SPEC.md           — spec, architecture, provider matrix, phased plan.
- docs/adr/*.md     — why key decisions were made.
- docs/spike-findings.md — the Phase 0 findings you must implement against.

This is Phase 3 of SPEC.md's plan. Phases 1–2 are done; the Domain model, Engine, and the four
high-confidence providers already exist and define the pattern to follow.

Wire the four remaining providers, using docs/spike-findings.md (do not redo the research):

- Gemini (quota): API key. Use the spike's finding (AI Studio / Antigravity / `agy`).
- Scaleway (spend): secret key sent as `X-Auth-Token`. Use the spike's Billing/FinOps endpoint.
- OpenCode Go (quota, $12/5h · $30/wk · $60/mo) and OpenCode Zen (spend, $ balance): these are
  ONE Provider with TWO Plans — a single credential yields two usage entities. Use the spike's
  finding: an API-key usage endpoint if one exists, else a console scrape (cookie) with manual
  setup. Model it as 1 Provider → 2 Plans per CONTEXT.md.

Deliverable: normalized `ProviderUsage` + plan cards, consistent with the Phase 2 providers.

Constraints: OpenCode is the only 1-Provider→2-Plan case — store the shared credential once and
make sure Go and Zen render as two distinct cards with their own Progress.

Verification: `--check` passes; live usage renders for all four; OpenCode shows Go and Zen as two
separate cards.
```

---

## Phase 4 — Polish

```text
You are working in the `Full-LLM-Usage-Widget` repo — a macOS menu-bar app (Swift 6 / SwiftUI)
that surfaces live LLM consumption across 8 plans, unifying quota and spend under a "progress
toward a limit" view.

Before writing anything, read these files in the repo and follow them exactly:
- CONTEXT.md        — domain glossary; use ONLY these terms. Do not invent new vocabulary.
- SPEC.md           — spec, architecture, provider matrix, phased plan.
- docs/adr/*.md     — why key decisions were made.

This is Phase 4 (polish) of SPEC.md's plan. Phases 1–3 are done; all 8 plans render live usage.

Deliverables:
- Settings: enable/disable providers, an optional monthly Budget per spend plan, menu-bar focus
  (auto most-urgent vs pinned to a specific plan), threshold colors, poll interval,
  launch-at-login (SMAppService).
- Near-limit notifications when any plan crosses 90% — once per window/reset cycle.
- App icon + a `make_icon` script.
- Robust `--check` self-checks (parsing, backoff, snapshot-cache round-trip).

Constraints: a budget renders a spend plan as progress (per ADR-0002); an unset budget means "no
urgency". Launch-at-login via SMAppService, not a Login Item.

Verification: full `--check` suite passes; settings persist across launches; notifications fire
exactly once per cycle.
```

---

## Phase 5 — v2 backlog (Cursor + notarization)

```text
You are working in the `Full-LLM-Usage-Widget` repo — a macOS menu-bar app (Swift 6 / SwiftUI)
that surfaces live LLM consumption across 8 plans, unifying quota and spend under a "progress
toward a limit" view.

Before writing anything, read these files in the repo and follow them exactly:
- CONTEXT.md        — domain glossary; use ONLY these terms. Do not invent new vocabulary.
- SPEC.md           — spec, architecture, provider matrix, phased plan.
- docs/adr/*.md     — why key decisions were made (note the Cursor deferral rationale in ADR-0003).

This is Phase 5 (v2 backlog) of SPEC.md's plan. Phases 1–4 are done and shipped.

Deliverables:
- Cursor (quota, monthly fast requests): Cursor has no public usage API. Implement the
  least-fragile path — read its local SQLite (state.vscdb), which requires a Full Disk Access
  entitlement and an internal/undocumented schema, OR scrape the cursor.com dashboard. Make the
  Full Disk Access permission opt-in and clearly documented.
- Notarization: Developer-ID signing + hardened runtime + `notarytool` staple (mirroring
  LLM-Usage-Widget's `Scripts/notarize.sh`), then a signed `.dmg` release.

Constraints: Cursor is the only Full-Disk-Access provider — isolate it behind the same
`UsageProvider` seam and never request the permission implicitly.

Verification: Cursor usage renders; the notarized build passes `spctl --assess`.
```
