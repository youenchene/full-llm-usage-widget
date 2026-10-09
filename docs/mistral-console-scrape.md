# Mistral Console Scrape — Spike Findings

Research + live capture. Source of truth for the Phase-1+ console-scrape fetcher. The Mistral
Admin API (`/v1/admin/usage`) is Enterprise-only (see `spike-findings.md` and the Admin API docs),
so Pro/Free accounts have no server-side spend API. This documents the alternative: reading the
"included monthly usage" quota straight from the `admin.mistral.ai` subscription page.

Status: **verified** (live capture of a real Pro + Pay-As-You-Go account, 2026-08-18).

## Summary

| Provider | Plan | Kind | Endpoint | Auth | Status |
|---|---|---|---|---|---|
| Mistral (console) | API included usage | quota | `GET https://admin.mistral.ai/subscription` | Ory session cookie | **verified** (live) |
| Mistral (admin) | org spend | spend | `GET https://api.mistral.ai/v1/admin/usage` | `x-api-key` (Admin key) | Enterprise-only |

The two paths are complementary, not interchangeable:

- **Admin key** (`x-api-key`) → total org **spend** across all categories. Enterprise only.
- **Console session** (cookie) → the monthly **included usage** budget (a quota window with a
  reset date) that ships with Pro/Vibe plans. Any plan, no Admin key.

For a Pro user the console path is the only one available, and it surfaces the *quota* view
("how much of my €25.5 monthly API allowance have I used"), not raw spend.

---

## Endpoint

```
GET https://admin.mistral.ai/subscription
```

- Method: `GET`. No special headers required — a plain document navigation request returns the
  data (verified with `Accept: text/html` and no `RSC:` / `Next-Router-State-Tree` headers).
- Response: a Next.js App Router RSC document (`content-type: text/x-component`, `vary: rsc`).
  The data is **embedded server-side** in `<script>self.__next_f.push([1,"…"])</script>` blocks —
  there is no separate JSON/API endpoint to reverse-engineer (unlike OpenCode Zen's SolidStart
  RPC, which ADR-0003 deferred).
- `cache-control: private, no-cache` → the payload is session-scoped (personalized per org).

### Auth — Ory session cookie

Mistral's IdP is Ory (`NEXT_PUBLIC_IDP_PROVIDER:"ory"`, `NEXT_PUBLIC_ORY_API_URL:"https://auth.mistral.ai"`).
Authentication is a single session cookie:

```
ory_session_<ory-project-slug>="<opaque-session-value>"
```

- The cookie **name** is stable (the `coolcurranf83m3srkfl`-style suffix is the Ory project id).
- The **value** is the session and **expires** (Ory session, typically hours–days). When it does,
  the endpoint returns the login page instead of the subscription data.
- `csrftoken` / `csrf_token_*` cookies are only required for mutations (POST); a read does not
  need them. Other cookies (`_ga`, `__stripe_*`, `intercom-*`, `__cf_bm`, `hubspotutk`) are
  analytics/marketing and irrelevant to the data.

### Curl probe

```bash
curl -s 'https://admin.mistral.ai/subscription' \
  -H 'Cookie: ory_session_coolcurranf83m3srkfl="<PASTE_SESSION_VALUE>"' \
  | grep -o '"api_budget":{[^}]*}'
```

Expected output (one line, actual values vary):

```
"api_budget":{"usage_percentage":7.078156333333333,"initial_budget":25.5,"currency":"EUR","reset_at":"2026-09-01T00:00:00Z","payg_enabled":false}
```

---

## Response payload

The `SubscriptionPage` server component props carry a `budget` object (alongside `subscriptions`
and `billingInfo`, which we ignore). Extracted shape:

```json
"budget": {
  "api_budget": {
    "usage_percentage": 7.078156333333333,
    "initial_budget": 25.5,
    "currency": "EUR",
    "reset_at": "2026-09-01T00:00:00Z",
    "payg_enabled": false
  },
  "vibe_budget": {
    "usage_percentage": 0,
    "initial_budget": 255,
    "currency": "EUR",
    "reset_at": "2026-09-01T00:00:00Z",
    "payg_enabled": false
  },
  "usage_percentage": 7.078156333333333,
  "initial_budget": 25.5,
  "currency": "EUR",
  "reset_at": "2026-09-01T00:00:00Z"
}
```

Fields (per budget):

| Field | Meaning |
|---|---|
| `usage_percentage` | Fraction of the budget consumed, `0–100` (already normalized). |
| `initial_budget` | The monthly included usage, in the org's billing currency (whole units — `25.5` = €25.50, not cents). |
| `currency` | ISO currency code (`"EUR"`). |
| `reset_at` | ISO-8601 reset timestamp (monthly boundary). |
| `payg_enabled` | Whether pay-as-you-go overages are allowed past the included budget. |

`billingInfo.currency` is the authoritative org currency (verified `"EUR"` here).

## Mapping to the domain model

The console data maps to **up to three Plans** per `CONTEXT.md`:

### 1. `mistral.api` — API included usage (quota)

- **Kind**: `.quota` (provider-imposed limit, fixed reset window).
- **LimitWindow**:
  - `used` = `usage_percentage / 100 × initial_budget` (≈ €1.805 for the API budget).
  - `limit` = `initial_budget` (€25.5) — the **hard limit** (top of the progress indicator).
  - `resetsAt` = `reset_at`.
- **Note**: `"€1.81 of €25.50 included monthly • Hard limit"` (or `"• Pay-as-you-go"` when
  `payg_enabled: true`).

### 2. `mistral.api.extra` — API overage (spend, pay-as-you-go beyond the included budget)

- **Kind**: `.spend` (pay-as-you-go overage beyond the included budget).
- **Spent**: month's priced API cost − `initial_budget` (see "Usage endpoint" below). Fallback when
  that call fails: `(usage_percentage - 100) / 100 × initial_budget`, which only works on payloads
  that don't cap the percentage.
- **Currency**: `currency` from the budget.
- **Note**: `"€21.71 overage this month"`.
- **Omitted** when there is no overage.

> **Verified 2026-10-09**: the live budget **caps `usage_percentage` at 100** and no longer
> includes `payg_enabled`. A Pay-as-you-go account at €47.21 of API usage showed
> `usage_percentage: 100`, so the overage can't come from the budget block.

### Usage endpoint (`GET /api/billing/v2/usage?month=M&year=Y`)

This is the JSON the console's **Organization → Usage** page fetches in the browser. It uses the
same Ory cookie (no CSRF header is needed for GET). Shape (trimmed):

```json
{
  "completion": {"models": {"<display>::<metric>": {"input": [Row], "output": [Row], "cached": [Row]}}},
  "ocr": {"models": {}}, "connectors": {"models": {}}, "audio": {"models": {}},
  "libraries_api": {"pages": {"models": {}}, "tokens": {"models": {}}, "audio_seconds": {"models": {}}},
  "vibe_code": {"completion": {"models": {}}},
  "chat": {"models": {}},
  "currency": "EUR",
  "prices": [{"event_type": "api_tokens", "billing_metric": "mistral-large-2512",
              "billing_group": "input", "api_zone": "global", "service_tier": "standard",
              "price": "4.25E-7"}]
}
```

`Row` = `{billing_metric, billing_group, event_type, api_zone, service_tier, value, value_paid, timestamp, usage_type}`.

The cost is **Σ `value_paid` × unit price**, with the price matched on (metric, group, event type,
zone). This mirrors the console's own `calculateCost`. `vibe_code` (which has its own allowance)
and `chat` are excluded. Check: pricing the `vibe_code` rows reproduces the `vibe_budget` usage
to the cent (€8.4076). Implemented in `MistralUsageCost`.

### 3. `mistral.vibe` — Vibe Code included usage (quota, optional)

- **Kind**: `.quota`.
- **LimitWindow**: same shape as `mistral.api` (used/limit in currency, `resetsAt` from `reset_at`).
- **Note**: `"€0 of €255 included monthly (Vibe)"`.
- **Omitted** when `vibe_budget` is absent or `initial_budget == 0`.

The top-level `usage_percentage`/`initial_budget` mirror `api_budget` — use the per-budget blocks
for fidelity rather than the top-level shorthand.

## Caveats (why this is fragile, per ADR-0003)

- **Undocumented**: the endpoint and payload are internal and can change silently.
- **Cookie expiry**: the Ory session rotates/expires; the widget must detect an expired session
  (login page returned instead of data) and prompt re-auth.
- **ToS**: scraping an authenticated console may violate Mistral's terms — flagged, same as any
  other console-scrape integration.
- **Scope**: this exposes the *included monthly usage* (quota) and the *pay-as-you-go overage*
  (priced from the usage endpoint). It does not expose the monthly overage spending cap (that
  setting isn't in either payload).
