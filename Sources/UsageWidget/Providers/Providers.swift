// Providers/
//
// One module per provider. Phase 2 wires Claude, Codex, and Copilot. Mistral is deferred
// (its usage/billing API is Enterprise-only). Phase 3 wires Scaleway and OpenCode Go.
// Gemini and OpenCode Zen are deferred (no public usage endpoint — see docs/spike-findings.md).
// Phase 5 wires Cursor (local state.vscdb read behind Full Disk Access, opt-in).
// Each conforms to `UsageProvider` (Domain/) and returns a normalized `ProviderUsage`.
