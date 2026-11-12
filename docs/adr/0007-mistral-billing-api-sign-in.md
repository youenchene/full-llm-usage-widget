# Mistral usage via the billing API and the Vibe CLI browser sign-in

ADR-0005 read Mistral's included monthly usage by scraping `admin.mistral.ai/subscription` with a
pasted Ory session cookie, because the Admin API is Enterprise-only. The cookie expires and must be
re-pasted. The official Vibe CLI reads the same budgets from `api.mistral.ai/v1/billing/budget` with
a regular API key, and obtains that key through a browser sign-in (PKCE, no client registration).
See `docs/mistral-billing-api.md`.

## Decision

Add a **Mistral account** auth method that runs the Vibe CLI's browser sign-in, stores the returned
API key in the Keychain, and reads `/v1/billing/budget` (+ `/v1/billing/subscription` for the
pay-as-you-go flag). It produces the same Plans as the scrape (`mistral.api`, `mistral.vibe`).

The console cookie stays as an **optional** method: when both are connected, the account's Plans win
and the cookie only adds the priced overage card (`mistral.api.extra`). The Enterprise Admin key
method is unchanged.

## Consequences

- No more expiring cookie for the main cards: the key lasts until revoked or its expiry policy.
- The endpoints and the sign-in flow are undocumented, but they are what Mistral's own CLI ships;
  if they break, the cookie method still works.
- Sign-in creates a Vibe-type API key in the user's workspace. It shows in the key list; signing out
  of the widget doesn't delete it (no API for that).
- `/budget` needs the `see_org_inference_usage` permission: members without it get a clear error.
- The € overage still needs the cookie.

## Alternatives considered

- **Paste an existing API key**: works with the same endpoints (verified) and needs no sign-in flow;
  easy to add later, not chosen as the main path.
- **Mistral OIDC login** (`auth.mistral.ai`, CLI client ID): behind an experiment flag in the CLI;
  rejected for now.
- **Keep the cookie only**: it expires; rejected.
