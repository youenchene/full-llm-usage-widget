# Mistral billing API (key) and browser sign-in

Found 2026-11-12 in the official Vibe CLI (`mistralai/mistral-vibe`, `vibe/app_server/_billing.py`
and `vibe/setup/auth/http_browser_sign_in_gateway.py`). Undocumented on docs.mistral.ai, but the
CLI calls it "the public billing API". **Verified live** with a Pro + pay-as-you-go account.
Supersedes the cookie scrape (`mistral-console-scrape.md`) for the included-usage quotas.

## Billing API

Both take `Authorization: Bearer <regular Mistral API key>`. No Admin key or Enterprise plan needed.

`GET https://api.mistral.ai/v1/billing/budget` (needs the `see_org_inference_usage` permission, 403
otherwise):

```json
{"vibe_budget":{"usage_percentage":12.16,"initial_budget":255.0,"currency":"EUR","reset_at":"2026-12-01T00:00:00Z","payg_enabled":false},
 "api_budget":{"usage_percentage":3.49,"initial_budget":25.5,"currency":"EUR","reset_at":"2026-12-01T00:00:00Z","payg_enabled":false},
 "usage_percentage":3.49,"initial_budget":25.5,"currency":"EUR","reset_at":"2026-12-01T00:00:00Z"}
```

Same block shape as the console's `/subscription` payload, so the same Plans are built
(`mistral.api`, `mistral.vibe`).

`GET https://api.mistral.ai/v1/billing/subscription`:

```json
{"plan_name":"INDIVIDUAL","payg_enabled":true,"vibe_payg_enabled":false,"enterprise":false}
```

`api_budget.payg_enabled` was `false` on an org whose subscription says `payg_enabled: true`, so the
"Pay-as-you-go" / "Hard limit" note follows the subscription.

Not available here: the priced pay-as-you-go **overage** (the console's `/api/billing/v2/usage`,
cookie only) and the credit balance. The optional cookie method still adds the overage card.

## Browser sign-in (mints the key)

All on `https://console.mistral.ai/api`, no client ID:

1. `POST /vibe/sign-in` `{code_challenge, code_challenge_method: "S256"}` →
   `{process_id, sign_in_url, poll_url, expires_at}` (10 minutes). Open `sign_in_url`.
2. `GET poll_url` every 3 s → `{status: pending|completed|expired|denied|error, exchange_token?}`;
   `410` = expired.
3. `POST /vibe/sign-in/{process_id}/exchange` `{exchange_token, code_verifier}` → `{api_key}`.

The key is a regular Vibe-type key in the chosen workspace, visible (and revocable) under
**Admin Panel › API › API Keys**. `403` with `error_code: 9004` on exchange means the workspace
can't create keys. We only accept sign-in and poll URLs on `console.mistral.ai`, as the CLI does.
