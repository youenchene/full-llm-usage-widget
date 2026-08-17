# Phase 0 Spike — Provider Endpoint Findings

Research-only. No production code. This document is the source of truth Phase 2/3 fetchers
implement against. Per-provider: endpoint, method, auth, representative response, and a
`verified` / `unverified` flag.

## Summary

| Provider | Plan(s) | Kind | Endpoint | Auth | Status |
|---|---|---|---|---|---|
| OpenCode Go | Go | quota | `GET https://opencode.ai/zen/go/v1/usage` | `Authorization: Bearer sk-…` | **verified** (source) |
| OpenCode Zen | Zen | spend | *(none — console-only)* | session cookie (SolidStart RPC) | **defer** |
| Scaleway | — | spend | `GET https://api.scaleway.com/billing/v2beta1/consumptions` | `X-Auth-Token` | **verified** (docs + SDK) |
| Gemini | — | quota | *(no public endpoint)* | Google OAuth (OS keyring) | **defer** |

---

## 1. OpenCode Go & Zen

Source inspected: `anomalyco/opencode` (the console app lives in `packages/console`; the API
routes under `packages/console/app/src/routes/zen`). Base URL is `https://opencode.ai`
(`packages/console/app/src/config.ts`).

### 1a. OpenCode Go (quota) — verified (source)

OpenCode **does** expose a Bearer-API-key usage endpoint for the Go ("lite") subscription plan.
It is not console-only.

- **Endpoint**: `GET https://opencode.ai/zen/go/v1/usage`
- **Auth**: `Authorization: Bearer <api-key>` (no other headers required).
- **API key**: user-facing, created in the console at `/workspace/{id}/keys`. Format is
  `sk-` + 64 alphanumeric chars (generated in `packages/console/core/src/key.ts`).
- **Errors**:
  - `401` `{"type":"error","error":{"type":"AuthError","message":"Missing API key."}}` when the
    header is absent, or `"Unauthorized"` when the key doesn't resolve to a workspace.
  - `403` `{"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}`
    when the key's workspace has no Go (lite) row.

Response — three windows, each `{status, percent, resetsAt}` (from `…/zen/go/v1/usage.ts`):

```json
{
  "usage": {
    "rolling": { "status": "ok", "percent": 42, "resetsAt": "2026-08-17T20:12:00.000Z" },
    "weekly":  { "status": "ok", "percent": 17, "resetsAt": "2026-08-23T23:59:59.000Z" },
    "monthly": { "status": "ok", "percent": 3,  "resetsAt": "2026-08-31T23:59:59.000Z" }
  }
}
```

- `percent` is an integer `0–100` (already normalized); `status` is `"ok"` | `"rate-limited"`.
- `rolling` is a 5-hour window (the CLI itself reports "5 hour usage limit reached"; see
  `packages/opencode/test/session/retry.test.ts`). `weekly` resets on the week boundary;
  `monthly` on the subscription-anniversary month boundary.
- The dollar limits the SPEC cites (`$12/5h · $30/wk · $60/mo`) are **not** in the repo — they
  live in a `ZEN_LIMITS` production secret (`packages/console/core/src/subscription.ts` reads
  `Resource.ZEN_LIMITS.value`). They are irrelevant to the widget anyway: the endpoint returns
  `percent` directly, so a fetcher maps `percent → Progress` (used = percent, limit = 100) and
  `resetsAt → LimitWindow.resetsAt` without ever needing the dollar ceiling.

Mapping to the domain model: **1 Provider (OpenCode) → 2 Plans**, but only the Go plan has an
API-key endpoint. Go yields three `LimitWindow`s (`rolling`, `weekly`, `monthly`).

Curl probe (illustrative):

```bash
curl -s https://opencode.ai/zen/go/v1/usage \
  -H "Authorization: Bearer sk-<64-char-api-key>"
```

### 1b. OpenCode Zen (spend) — no endpoint; defer

There is **no** Bearer-API-key endpoint for the Zen balance. The route tree has `zen/go/v1/usage`
for Go only; there is no `zen/v1/usage`. The balance is a row in `BillingTable.balance`
(micro-cents), surfaced only in the web console at `/workspace/{id}/billing`.

The console fetches it via **SolidStart server functions** (`query`/`action` with `"use server"`),
i.e. an authenticated RPC over the session cookie — there is no plain REST JSON endpoint to
scrape. Reproducing it would mean reverse-engineering the SolidStart RPC and holding a live
`opencode.ai` session cookie, which is exactly the fragile path ADR-0003 warns against.

**Recommendation (Phase 3):**
- Implement Go now via the Bearer endpoint.
- For Zen, either (a) defer and let the user set a manual **Budget**/Balance, or (b) if a console
  scrape is attempted later, target the cookie-authenticated billing page and treat it as
  best-effort with a snapshot fallback. **Flag: defer Zen to a later phase** (v2 backlog,
  alongside Cursor).

---

## 2. Scaleway (spend) — verified (official docs + Go SDK)

- **Endpoint**: `GET https://api.scaleway.com/billing/v2beta1/consumptions`
- **Auth**: `X-Auth-Token: <secret-key>` + `Content-Type: application/json`.
  (The "secret key" is the secret half of a Scaleway IAM API key.)
- **IAM**: the key needs only `BillingReadOnly` to query consumption.

Query parameters (from `scaleway-sdk-go` `ListConsumptionsRequest`, and the official quickstart):

| Param | Type | Notes |
|---|---|---|
| `organization_id` | uuid | **required** (exactly one of `organization_id` / `project_id`) |
| `project_id` | uuid | alternative scope to `organization_id` |
| `billing_period` | `YYYY-MM` | current month if omitted |
| `category_name` | string | optional category filter (Compute, Network, …) |
| `page`, `page_size` | int | `page_size` ≤ 100 |
| `order_by` | enum | e.g. `updated_at_desc` |

There is **no** `product_name`/`product` filter — filter client-side. The product slug for
"Generative APIs" is `inference` (confirmed in the official "Product slugs" table), and the
`product_name` value on a consumption record is the human-readable `"Generative APIs"`.

Response schema (`ListConsumptionsResponse`):

```json
{
  "consumptions": [
    {
      "value":            { "units": 12, "nanos": 340000000, "currency_code": "EUR" },
      "product_name":     "Generative APIs",
      "resource_name":    "inference-…",
      "sku":              "inference/…",
      "project_id":       "…",
      "category_name":    "AI",
      "unit":             "…",
      "billed_quantity":  "12345",
      "consumer_id":      "…",
      "project_name":     "…",
      "organization_name": "…"
    }
  ],
  "total_count": 1,
  "total_discount_untaxed_value": 0,
  "updated_at": "2026-08-17T12:00:00Z"
}
```

- `value` is the money spent on that line (`google.type.Money`: `units`, `nanos`, `currency_code`).
- `billed_quantity` is a **string** (not number).
- Monthly spend for the "Generative APIs" product = sum of `value` over the current
  `billing_period` where `product_name == "Generative APIs"`.

Curl probe (illustrative):

```bash
curl -s \
  -H "X-Auth-Token: $SCW_SECRET_KEY" \
  -H "Content-Type: application/json" \
  "https://api.scaleway.com/billing/v2beta1/consumptions?organization_id=$SCW_ORGANIZATION_ID&billing_period=2026-08"
```

Alternative (more granular, per-invoice): `GET https://api.scaleway.com/billing/v2beta1/charges`
returns `charges[]` with `price`, `sku`, `start_date`, `end_date`. Prefer `consumptions` for a
simple monthly product-spend figure; use `charges` only if per-resource breakdown is needed.

Mapping: spend plan → `spent = Σ value` for the month; an optional user **Budget** turns it into
Progress (per ADR-0002).

---

## 3. Gemini — no public endpoint; defer

Where "Gemini" usage lives depends on which surface the user uses, and none of them exposes a
clean queryable endpoint.

### 3a. Antigravity (antigravity.google / `agy` CLI) — the migration target, but private backend

Google's current agent platform. Usage is **quota + credits**, not a simple spend:

- **Baseline quota (rate limits)** — surfaced as "Model Quotas" (`/usage`, alias `/quota`):
  a rolling **5-hour** window (Google AI Pro/Ultra) or weekly (Individual), plus weekly rate
  limits. Returned **per model** as "remaining requests/tokens" (e.g. Gemini 3.5 Flash, 3.1 Pro),
  not a single %.
- **AI credits (overages)** — a spend-like **Balance**: purchased at `one.google.com/ai/credits`,
  shown in the CLI statusline as `AI Credits: 42`, queried via `/credits`.

Auth & access:
- Default: Google OAuth, with the token stored in the **OS keyring** (Apple Keychain on macOS) —
  "local silent keyring sign-in". The CLI then calls a **private backend** (no public REST
  endpoint is documented anywhere).
- Headless alternative: a `GEMINI_API_KEY` (AI Studio key) with `modelProvider: "gemini"` in
  `~/.gemini/antigravity-cli/settings.json`. In this mode requests go **directly to the Gemini
  API** and the CLI never establishes an account session — so there is no credits/quota to query
  at all; the AI Studio key's own rate limits apply.

The `/usage` docs state the CLI "triggers a fresh check of your quotas **on disk** and from the
backend service" — meaning the CLI caches quota state locally (`~/.gemini/antigravity-cli/`),
which is a potential (unverified) on-disk scrape target for Phase 3, but the schema is not
documented.

### 3b. Google AI Studio (aistudio.google.com) — no usage endpoint

Gemini API keys have per-model rate limits (RPM / RPD / TPM) that are surfaced only in response
headers (`x-ratelimit-*`) and the dashboard. There is **no** REST endpoint to query a cumulative
quota or spend for an AI Studio key. Rate limits are not a quota window in the CONTEXT.md sense.

### 3c. Google Cloud billing — only if the user runs Gemini on Vertex AI / GCP

If usage is on Vertex AI / Gemini via Google Cloud, spend lives in Cloud Billing
(`cloudbilling.googleapis.com` + BigQuery billing export). This is a heavyweight path that
does not match the SPEC's "API key → AI Studio / Antigravity" assumption, and it is out of scope
for v1.

**Recommendation (Phase 3):**
- There is **no public endpoint** to target. Two viable, if imperfect, paths:
  1. **Shell out to `agy`** and read its local quota/credits cache under
     `~/.gemini/antigravity-cli/` (unverified — investigate schema in Phase 3), or
  2. **Defer** and let the user enter a manual Budget / ignore rate limits.
- **Flag: defer Gemini to a later phase** (or implement as a best-effort local-cache read with a
  snapshot fallback). Mark the whole plan `unverified` until a real `agy` cache is inspected.

---

## Deferral ledger

| Plan | Decision | Rationale |
|---|---|---|
| OpenCode Zen (spend) | **defer** | no API-key endpoint; console-only via SolidStart RPC + cookie (fragile) |
| Gemini (quota) | **defer** | no public endpoint; private Antigravity backend + OS-keyring OAuth; local cache unverified |

OpenCode Go and Scaleway are ready for Phase 3 implementation with no further research.

## Confidence notes

- **OpenCode Go**: endpoint, method, auth, response shape, and error codes are all read directly
  from `anomalyco/opencode` source (`packages/console/app/src/routes/zen/go/v1/usage.ts`,
  `…/core/src/key.ts`, `…/core/src/subscription.ts`). **Not** live-tested against a real key.
- **Scaleway**: endpoint, params, and response schema read from the official Billing API docs and
  the `scaleway-sdk-go` `api/billing/v2beta1/billing_sdk.go` (struct fields = JSON tags).
  **Not** live-tested against a real secret key.
- **Gemini/Antigravity**: drawn from the official Antigravity docs (pricing, plans, CLI
  install/auth, credits, usage). No endpoint exists to mark verified.
