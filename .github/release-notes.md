# v0.2.0-rc.1 — macOS Community preview

- One native menu-bar panel for accounts, Today / 7-day / 30-day Token totals and per-account usage, including trillion-scale formatting.
- Read-only live five-hour / weekly quota, reset dates, reset-card availability / expiry and clear cached / unavailable states. Quota percentages are not remaining Token counts; daily Token reports may stop at yesterday.
- Email identity, explicit native switch confirmation, current-account colored weekly progress and an original application / menu icon.
- Shared Desktop credential protection avoids background session refresh and automatic reset; explicit switching retains confirmation and graceful Desktop exit.

This fork preview is macOS arm64 only (macOS 14 minimum); Windows has not been built or validated for this preview. The app is ad hoc signed, without Apple Developer ID signing or notarization. It uses a separate Community bundle and data directory, contains no accounts or credentials, and does not use the upstream automatic-update feed. Installing the archive does not migrate existing profiles. The current Desktop login is registered automatically at startup; add other accounts explicitly.

A real Desktop account handoff has not been performed for this release; automated fixture checks do not establish that end-to-end result. No reset redemption is offered by the new quota display. Upstream stable releases and their signed update channel remain separate.
