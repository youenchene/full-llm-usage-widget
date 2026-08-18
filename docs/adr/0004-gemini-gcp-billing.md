# Gemini spend via the Cloud Billing export in BigQuery

ADR-0003 deferred Gemini because no public usage endpoint exists (private Antigravity backend, AI
Studio rate limits only). The SPEC's "API key → AI Studio / Antigravity" assumption cannot surface
spend. But Gemini usage that runs through Google Cloud (Vertex AI, Gemini API, Gemini Code Assist)
is billed through Cloud Billing, and Cloud Billing can export every usage-cost row to BigQuery.

We decided to add an **optional** Gemini connection mode that queries the user's Cloud Billing
Standard usage-cost export in BigQuery: a spend Plan whose spent figure is the current calendar
month's gross cost plus credits for the services the user identifies as Gemini-related. Auth is a
read-only service account (`roles/bigquery.jobUser` + `roles/bigquery.dataViewer`) via the
documented JWT-bearer grant (RFC 7523) and the BigQuery REST API — no API key, browser cookie, AI
Studio scrape, or undocumented endpoint. The user picks the Gemini-related `service.description`
rows from a discovery query against their own export; nothing is hard-coded.

**Consequences**: the mode is isolated behind `UsageProvider` (one new module, zero engine
changes). Values are billing-export estimates — they can lag and be adjusted until Google
finalizes charges, so the plan card labels them as such and the engine's last-good Snapshot
fallback covers failures. The Gemini quota mode (AI Studio / Antigravity) remains deferred.