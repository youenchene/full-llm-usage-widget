# OpenCode Console (formerly Zen) and Go — data acquisition

Updated 2026-11-12 after OpenCode v2. Supersedes §1 of `spike-findings.md`. Source: the
`anomalyco/opencode` repo (`packages/core/src/usage-limits.ts`, `console-access.ts`,
`plugin/provider/opencode.ts`) and the Console docs (`opencode.ai/docs/console/*`). **None of the
endpoints below were tested live while writing this**; they are what the OpenCode client itself
calls.

## What changed upstream

- "Zen" is gone as a product name. The pay-as-you-go gateway is now **OpenCode Console**
  (`https://opencode.ai/console`, inference under `https://opencode.ai/inference/…`). The old
  `docs/zen` URL serves the Console "Models" page.
- Go comes in three tiers: **Go** ($10), **Go Plus** ($40), **Go Teams** ($20/member). Limits are a
  monthly dollar allowance per model; the 5-hour window is 20% of it, the weekly one 50%.
  **Extra Usage** pays from credits once a Go limit is hit.
- API keys are `oc_sk_…`, either personal (**Account › Personal API keys**) or service-account. Keys
  have permissions (All / Restricted / Read only); restricted resources include **Usage**,
  **Budgets** and **Billing** (Read).
- Console budgets are policies (**Controls**) in USD and reset on the 1st at 00:00 UTC.

## Widget Plans

| Plan (ID) | Display name | Source |
|---|---|---|
| `openCode.go` | OpenCode Go subscription | `GET https://opencode.ai/zen/go/v1/usage` |
| `opencode.zen` | OpenCode Console | `GET https://opencode.ai/console/api/policies/current-budgets` (+ optional balance scrape) |

The IDs are kept from before the rename so cached snapshots and saved budgets keep working.

## Auth methods

All three are independent rows in the Accounts panel. A login wins over a key when both exist.

1. **Console account** (`opencode.console`): the device flow the OpenCode CLI uses (ADR-0006).
   - `POST /console/auth/device/code` with JSON `{client_id: "opencode-cli", supports_org_scope: true}`
     → `{device_code, user_code, verification_uri_complete, expires_in, interval}`.
   - Poll `POST /console/auth/device/token` with
     `{grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code, client_id}`
     → `{access_token, refresh_token, expires_in, org_id?}` or `{error: authorization_pending | slow_down | …}`.
   - Refresh: same endpoint, `{grant_type: "refresh_token", refresh_token, client_id}`.
     `{error: "invalid_grant"}` means the session was revoked: we drop the login.
   - Workspace: `org_id` from the token, else the first of `GET /console/api/orgs` (Bearer) by name.
2. **API key** (`opencode.api-key`): a personal key plus an optional workspace ID (`wrk_…`). Without
   a workspace ID only Go is read. Legacy `sk-…` keys still work for Go.
3. **Balance cookie** (`opencode.zen`, optional): the `auth` cookie + workspace ID. The Console API
   has no documented balance endpoint, so this scrape is the only source of `Balance`. Tries
   `/console/{wrk}/settings/billing` first, then the pre-rename `/workspace/{wrk}/billing`.

## Requests

Both take `Authorization: Bearer <access token or oc_sk_ key>`.

- **Go**: `GET /zen/go/v1/usage`, header `x-opencode-org-id: wrk_…` (optional).
  `{"usage": {"rolling"|"weekly"|"monthly": {"status": "ok"|"rate-limited", "percent": 0–100, "resetsAt": ISO}}}`.
  `403` → no Go subscription in that workspace (no Plan). A `rate-limited` window renders as full.
- **Budgets**: `GET /console/api/policies/current-budgets`, header `x-org-id: wrk_…` (required).
  Returns an array of `{ruleID, limitDollars, spentDollars, scope: each|combined, per: set|model,
  coverage: all|models, models[], shared, resetsAt, …}`. `403` → the key can't read budgets
  (service-account key, or no Budgets › Read): no Console Plan unless the cookie is set.

The Console Plan shows the budget covering all spend that is closest to its limit (else the closest
model-scoped one): `spent` = its `spentDollars`, `budget` = its `limitDollars`. With no budget at
all, the Plan shows no spend and a note pointing to **Console › Controls**. Spend outside any
budget isn't visible through this API.
