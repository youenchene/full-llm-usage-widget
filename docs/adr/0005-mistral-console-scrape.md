# Mistral console scrape (included monthly usage)

Mistral's Admin API (`/v1/admin/usage` for spend, `/v1/admin/spend-limit`) is Enterprise-only, so
Pro/Free accounts have no server-side spend API. The only programmatic signal for those accounts is
the "included monthly usage" budget, embedded server-side in the `admin.mistral.ai/subscription`
page and authenticated by an Ory session cookie (see `docs/mistral-console-scrape.md`).

## Decision

Add a second auth method to `MistralProvider` (`mistral.console`) that scrapes the subscription
page, alongside the existing Enterprise `mistral.admin-key` method. The console method uses a
**pasted Ory session cookie** (WKWebView-based sign-in deferred) and maps the `api_budget` block to
a **quota** plan.

## Consequences

- Pro/Free users get a `quota` plan ("Mistral API": % of monthly included usage, reset countdown,
  euro figures in the plan note) with no Enterprise contract.
- The Ory session cookie expires and must be re-pasted — fragile, same class as the OpenCode Zen
  deferral noted in ADR-0003.
- Undocumented internal endpoint; may break silently (flagged in the spike doc).
- `vibe_budget` (Vibe Code) is not surfaced in v1 — deferred, easily added later.

## Alternatives considered

- **WKWebView sign-in** (harvest the cookie automatically after login): better UX, larger change
  (new sign-in UI pattern); deferred.
- **Model as spend + Budget**: rejected — `Budget` is user-set (and merged from settings), while
  the € included usage is provider-set; it would also clash with the settings-driven budget merge.
- **Self-track token spend** (Option 2 in the investigation): captures only widget-observed
  traffic, not account-wide usage, and needs a proxy/agent integration the widget doesn't have.
