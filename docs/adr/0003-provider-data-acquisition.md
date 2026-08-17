# Heterogeneous data acquisition per provider

No two providers expose usage the same way, so a uniform auth strategy is impossible. Claude, Codex and Copilot expose OAuth flows and usage endpoints; Mistral exposes an admin usage endpoint over an API key; Scaleway exposes a billing API over an `X-Auth-Token` secret key; Gemini's usage sits behind an API key on a platform mid-migration to Antigravity; OpenCode Go/Zen track usage only in a web console with no documented endpoint.

We decided to accept a heterogeneous mix, isolated behind the `UsageProvider` protocol: each Provider owns its own authentication and fetcher, secrets live in the Keychain, and anything without a documented endpoint (OpenCode usage, and the exact Scaleway/Gemini endpoints) is resolved in a v1 spike — console scrape or an undocumented endpoint, whichever proves reliable.

**Consequences**: the `UsageProvider` seam is the load-bearing boundary — adding a provider is one new module with zero changes to the core engine, and no attempt is made to force OAuth or scraping uniformly across providers.
