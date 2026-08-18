# Gemini — Actual billed spend (GCP)

An optional Gemini connection mode that surfaces Gemini API spend from your Google Cloud billing
export in BigQuery. It is a **spend** Plan: the card always shows currency + spent, and a
user-set **Budget** turns it into a progress percentage.

## How it works

The widget queries the Cloud Billing **Standard usage-cost export** table in BigQuery for the
**current calendar month**, summing gross cost plus credits for the services you select as
Gemini-related. Values are **billing-export estimates** — they can lag and be adjusted until
Google finalizes charges.

## Prerequisites (one-time, in Google Cloud)

1. **Enable the billing export.** Cloud Console → Billing → your billing account →
   **Billing export** → **Standard usage cost** → **Edit exports** → **BigQuery**, choose a
   dataset and save. Note the fully-qualified table name
   (`project.dataset.gcp_billing_export_v1_<billing-account-id>`).
2. **Create a read-only service account.** IAM & Admin → Service Accounts → Create. Grant it
   exactly two roles on the project (least privilege):
   - `roles/bigquery.jobUser` — run queries
   - `roles/bigquery.dataViewer` — read the billing-export table
   Create a JSON key and download it.
3. **Connect in the widget.** Accounts → Gemini → Connect → "Actual billed spend (GCP)", paste
   the project ID, table identifier, and service-account JSON, then pick the Gemini-related
   services the widget discovers in your export.

## Security

- The service-account JSON is stored only in the Keychain and is never logged.
- The widget uses the documented BigQuery REST API with a short-lived OAuth2 access token
  obtained via the standard service-account JWT-bearer grant (RFC 7523).
- Table identifiers are validated before being embedded in SQL; all values are query parameters.
- No API key, browser cookie, AI Studio scrape, or undocumented endpoint is used.

## Notes

- The figure is **billing-export data**: supported, but not real-time and not invoice-final
  until Google finalizes charges. It can lag by hours and be adjusted.
- Only the current calendar month is queried.
- A monthly Budget can be set during sign-in or later in Settings → Monthly budgets.