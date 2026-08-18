// Providers/
//
// One module per provider. Phase 2 wires Claude, Codex, and Copilot. Mistral connects via an
// admin API key (Enterprise) or a console session cookie (see docs/mistral-console-scrape.md).
// Phase 3 wires Scaleway and OpenCode Go.
// Gemini connects via the optional "Actual billed spend (GCP)" mode (BigQuery billing export —
// see docs/gemini-gcp-billing.md); its AI Studio / Antigravity quota mode is deferred (no public
// usage endpoint — see docs/spike-findings.md). OpenCode Zen ships inside OpenCodeProvider.
// Phase 5 wires Cursor (local state.vscdb read behind Full Disk Access, opt-in).
// Each conforms to `UsageProvider` (Domain/) and returns a normalized `ProviderUsage`.
