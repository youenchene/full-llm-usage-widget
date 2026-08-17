# Full LLM Usage Widget — Context

A macOS menu-bar widget that shows live LLM consumption across multiple providers, unifying two consumption models — **quota** and **spend** — under a single "progress toward a limit" view.

## Language

**Provider**:
A vendor account the widget authenticates against to read usage (OpenAI, Anthropic, Google, Mistral, Scaleway, Anomaly/OpenCode).
_Avoid_: vendor, service, account

**Plan**:
A distinct tracked consumption entity under a Provider. A Provider can expose more than one — OpenCode has `Go` and `Zen`; every other provider has exactly one.
_Avoid_: virtual provider, subscription

**Kind**:
The classification of a Plan's consumption signal: `quota` or `spend`.
_Avoid_: type, category, mode

**Quota**:
A Plan whose limit is provider-imposed and resets on a fixed window (e.g. Codex 5-hour, OpenCode Go monthly).
_Avoid_: limit plan, allowance

**Spend**:
A Plan whose consumption is measured in currency with no provider-imposed ceiling (pay-as-you-go, e.g. Mistral, Scaleway, OpenCode Zen).
_Avoid_: metered, pay-as-you-go, billed

**LimitWindow**:
A single `(used, limit, resetsAt)` measurement inside a quota Plan (a quota Plan has one or more windows).
_Avoid_: window, period, bucket

**Balance**:
Remaining prepaid credit on a spend Plan (OpenCode Zen auto-reloads its balance).
_Avoid_: credit, remaining funds

**Budget**:
A user-set monthly currency ceiling applied to a spend Plan so it can render as a percentage.
_Avoid_: cap, spending limit — Mistral's own `spend-limit` is a distinct, provider-side concept.

**Progress**:
The normalized 0–1 ratio every Plan renders as — `used/limit` for quota, `spent/budget` for spend.
_Avoid_: percentage, utilization, fill

**Snapshot**:
A cached copy of a Plan's latest usage, persisted so the widget renders instantly and survives a failed refresh.
_Avoid_: cache entry, last-known value
