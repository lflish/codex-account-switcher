# Usage Statistics

Token usage statistics per ChatGPT account, with an all-accounts overview.

## Data Source

- **API**: `GET https://chatgpt.com/backend-api/wham/profiles/me`
- **Authentication**: Each profile's `auth.json` provides `access_token` and `account_id`.
- **Headers**: `Authorization: Bearer <token>`, `chatgpt-account-id: <id>`, `User-Agent: codex-cli/1.0.0`, `Accept: application/json`

## Data Coverage

The API returns:
- `lifetime_tokens` — cumulative token count as of `stats_as_of`
- `peak_daily_tokens` — highest single-day usage
- `daily_usage_buckets` — per-day token totals with `start_date` labels
- `current_streak_days`, `longest_streak_days` — usage streak info
- `total_threads` — conversation count
- Various other summary fields (fast mode %, reasoning effort, skills)

The API does **not** provide:
- Input/output/cache/reasoning token breakdowns
- Per-model or per-client breakdowns
- Per-client attribution (desktop vs CLI vs cloud) is not provided; the endpoint returns account-level Codex usage as aggregated by the backend, and exactly which clients feed into it is not documented upstream

## Date Handling

- Daily bucket `start_date` labels are used as-is from the upstream API. No timezone re-bucketing is performed.
- The macOS switcher offers Yesterday, 7 days, and 30 days. Yesterday matches the previous calendar date in the display timezone (default: Asia/Shanghai) against the upstream bucket label. The 7- and 30-day ranges include today.
- The UI notes: "Daily data is aggregated by the upstream service."

## Aggregation Rules

- **Daily average** = total tokens / number of days with data (not calendar days in range).
- **Missing days**: If a date in the selected range has no bucket, it is excluded from the daily series and listed as missing. Missing ≠ zero.
- **Cumulative display**: `lifetime_tokens` is shown as "Lifetime tokens (as of `stats_as_of`)" with bucket coverage dates, not "all-time total."
- **Account key**: `chatgpt account_id` is the primary key. Renaming an account does not lose history.
- **Never-synced accounts** are excluded from totals but counted in "synced X/N". The overview is marked partial.
- **Stale accounts** (sync failed but have old data) are included with a stale indicator.

## Error Handling

| HTTP Status | Behavior |
|---|---|
| 200 | Success. If `metadata.stats_error` is non-empty, mark as `unavailable` with the error message. |
| 401 | Mark as `authExpired`. Prompt user to sign in again. No retry. |
| 403 | Mark as `stale` (possible rate-limiting). Preserve old data. |
| Other | Mark as `stale`. Preserve old data. |

No OAuth token refresh is performed. Only the current `auth.json` snapshot is used.

## Sync Behavior

- Each successful sync **replaces** the account's daily buckets entirely (deduped by date, sorted).
- Repeated syncs do not accumulate — this is idempotent by design.
- Single account failure does not affect other accounts.

## Storage

- **File**: `usage-stats.json` in the app data directory
- **Permissions**: 0600 (owner read/write only)
- **Writes**: Atomic (temp file + rename), same pattern as `accounts.json`

## CSV Export

Columns: `account_id`, `display_name`, `date`, `timezone`, `tokens_total`

The export:
- Includes only dates within the selected range
- Correctly escapes fields containing commas or quotes
- Never includes email addresses, tokens, or Bearer strings

## Development Version Isolation

To run a development build with isolated data:

```bash
# Set custom data directory name
export SWITCHER_DATA_DIR_NAME="Codex Account Switcher Dev"

# Optional: custom bundle ID suffix (set in Xcode build settings or Info.plist)
# APP_BUNDLE_ID_SUFFIX=.dev
```

This keeps dev data separate from the production app's data directory.

## Installation and Rollback

### Normal installation
Usage statistics is included in the standard Codex Account Switcher build. No separate installation is needed.

### Rollback
To revert to a version without usage statistics:
1. Install the previous version of Codex Account Switcher.
2. The `usage-stats.json` file will be ignored by older versions.
3. To clean up, manually delete `usage-stats.json` from the app data directory.

## Known Limitations

1. **No input/output/cache/reasoning breakdown** — the API only provides total daily tokens.
2. **No per-model breakdown** — all models are aggregated together.
3. **Upstream date bucketing** — daily boundaries are determined by the upstream service, not the local timezone.
4. **Local CLI usage not included** — only usage tracked by the ChatGPT backend API is shown.
5. **macOS UI only** — the usage statistics window requires macOS. Core functionality (sync, aggregation, CSV export) works cross-platform.
6. **UI not compiled on Linux** — the macOS-only UI target does not build on Linux (gated by `#if os(macOS)` in Package.swift). UI correctness is verified by following existing view idioms and compilation on macOS.
