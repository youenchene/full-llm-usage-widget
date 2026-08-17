// Providers/
//
// One module per provider. Phase 2 wires Claude, Codex, and Copilot. Mistral is deferred
// (its usage/billing API is Enterprise-only); Phase 3 adds Gemini, Scaleway, and OpenCode
// Go + Zen. Each conforms to `UsageProvider` (Domain/) and returns a normalized `ProviderUsage`.
