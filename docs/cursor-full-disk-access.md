# Cursor — Full Disk Access (opt-in)

Cursor is the only **Provider** that needs Full Disk Access. This page explains why, and how to
enable it.

## Why

Cursor has no public usage API. The only reliable way to read its usage is from its local state,
which Cursor keeps in a SQLite database:

```
~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
```

That path sits inside `~/Library/Application Support/Cursor/`, which macOS protects with
**TCC**. Reading it requires the user to grant this app **Full Disk Access** in System Settings —
there is no programmatic way to request it, and macOS shows no permission prompt for it. Granting
it is a manual, user-initiated step.

## What the widget does with it

- Opens `state.vscdb` **read-only** (`SQLITE_OPEN_READONLY`, `PRAGMA query_only`), never writes.
- Reads only three keys — `cursorAuth/accessToken`, `cursorAuth/stripeMembershipType`, and the user
  id from Cursor's `sentry/*.json` — and uses the token to query Cursor's usage endpoints.
- The token never leaves the machine (it is sent only to `cursor.com` / `api2.cursor.sh`, which
  already hold it). It is **not** stored in this widget's Keychain.

## Enable (opt-in)

Cursor is **disabled by default** — the widget never reads the database implicitly. To turn it on:

1. Open the widget's **Settings**, and enable **Cursor** under *Providers*.
2. Open the widget's **Accounts** panel and click **Connect** next to *Cursor*.
3. The panel shows a Full Disk Access prompt. Click **Open System Settings** (or open
   *System Settings → Privacy & Security → Full Disk Access*).
4. Enable **Full LLM Usage Widget** (add it with `+` if it isn't listed).
5. **Quit and reopen** the widget, then click **Check access** in the Accounts panel.

If the check fails, confirm Cursor is installed and signed in, and that Full Disk Access is
granted to this app (not a different build of it).

## Notes / caveats

- **Undocumented schema.** Cursor's database layout and usage endpoints are reverse-engineered and
  version-dependent. The reader is tolerant and the last-good **Snapshot** keeps the card rendering
  if a read ever fails.
- **Two billing models.** Older accounts expose a "monthly fast requests" quota; newer accounts
  expose a monthly credit, which the widget renders as the same monthly **Progress** bar.
- **Revoking access.** To stop tracking Cursor, either disable it in Settings or revoke Full Disk
  Access in System Settings. Disabling in Settings is the cleaner option.
