# OpenCode Console login via the `opencode-cli` device flow

OpenCode v2 renamed Zen to **OpenCode Console** and moved its data behind a bearer-authenticated
API (`/console/api/…`). The previous Zen integration scraped the billing page with a pasted session
cookie that expires (ADR-0003's fragile path). The OpenCode CLI now signs in to the Console with an
OAuth **device flow** that issues refreshing tokens, but Anomaly offers no client registration for
third-party apps: the only client ID that exists is OpenCode's own public `opencode-cli`.

## Decision

Offer three independent OpenCode auth methods (see `docs/opencode-console.md`):

1. **Console account**: the device flow with `client_id: "opencode-cli"`, tokens refreshed and
   stored in the Keychain. We send our own User-Agent (`full-llm-usage-widget`), not OpenCode's.
2. **Personal API key** (`oc_sk_…`) plus workspace ID: the documented, supported path.
3. **Balance cookie**: kept, now optional, only for the credit `Balance`, which no API exposes.

Both bearer methods read Go usage (`/zen/go/v1/usage`) and Console budgets
(`/console/api/policies/current-budgets`). Plan IDs (`openCode.go`, `opencode.zen`) are kept;
display names become **OpenCode Go subscription** and **OpenCode Console**.

## Consequences

- One sign-in covers both Plans with no pasting, and it no longer expires every few days.
- Reusing `opencode-cli` is undocumented: Anomaly can block it, rate-limit it, or change the token
  response at any time. The API-key method is the fallback and needs no change if that happens.
- Console spend is only visible through **budgets**: with no budget policy there is no spend figure,
  and the figure is the budget's scope (the member's spend, or pooled spend for a shared budget),
  not total workspace spend.
- The balance still depends on a cookie scrape; its new page path is a guess with a fallback.

## Alternatives considered

- **API key only**: simplest and documented, but users must create and paste a key with the right
  permissions; kept as method 2 rather than the only option.
- **Read OpenCode's own stored credential** from its local storage: zero setup, but couples us to
  another app's internal storage format; rejected.
- **Keep the cookie as the only Console source**: it expires and the page moved; rejected.
