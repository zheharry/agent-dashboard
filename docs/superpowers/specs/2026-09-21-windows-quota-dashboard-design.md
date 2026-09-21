# Windows Quota Dashboard — Design Spec

Date: 2026-09-21
Status: Approved (pending implementation plan)

## Context

`agent-dashboard` is currently a native macOS menu bar app (`Sources/AgentQuota`,
Swift Package Manager, AppKit + SwiftUI) that shows live quota usage for six
provider cards: Claude, Codex, Agy Claude/GPT, Agy Gemini, Copilot, and Grok.
It shells out to CLIs the user is already signed into (`claude`, `codex`,
`agy`, `gh`) or reads local auth files (`~/.grok/auth.json`) and official
billing endpoints, stores everything in macOS `UserDefaults`, and refreshes
on a timer.

This spec covers a **separate, independent Windows port** written in
Rust/Tauri. The Mac app is untouched and continues to be maintained in Swift.
Nothing here changes `Sources/AgentQuota`.

## Goals

- A Windows system-tray app with feature parity to the Mac app: all six
  quota cards, live refresh, manual edit, same data model semantics.
- Lives in this repo, in a new top-level `windows/` directory, built and
  versioned independently from the Swift target.
- Rust backend + a plain (no framework) HTML/CSS/TypeScript frontend
  rendered in Tauri's webview.

## Non-goals

- No shared codebase or shared abstraction between the Swift and Rust
  versions. Each is a complete, independent implementation of the same
  product idea.
- No live verification against real Windows-installed CLIs in this round
  — the user does not have a confirmed, signed-in `claude`/`codex`/`gh`/`agy`
  setup on a Windows machine to test against yet. Executable-discovery paths
  are best-effort based on Windows conventions and will need real-world
  adjustment later.
- No auto-update / installer / code-signing story. `cargo tauri build` output
  is enough for this round.

## Architecture

- **Tooling**: Tauri v2. Rust crate at `windows/src-tauri`, frontend static
  assets at `windows/src`.
- **Frontend**: vanilla HTML/CSS/TypeScript, no UI framework. The quota
  rings are drawn as SVG circles using `stroke-dasharray`/`stroke-dashoffset`
  (equivalent to `ConcentricQuotaGauge` in the Swift app). No build-time
  framework needed beyond a TS→JS compile step (esbuild or tsc, kept minimal).
- **Tray + window**: Tauri tray icon; a single small `WebviewWindow` toggles
  open/closed on tray click, positioned near the tray icon (Tauri's
  positioner plugin or manual screen-geometry placement). This is the
  Windows analogue of the macOS popover.
- **Background refresh**: a `tokio::time::interval` task inside the Tauri
  app runs every 120 seconds, calls the live-usage fetch module, and emits
  a Tauri event with the results to the frontend. The frontend itself ticks
  every 30 seconds purely to recompute "time until reset" style display
  values — no backend involvement needed for that tick.
- **IPC surface** (Tauri commands): `get_services`, `upsert_service`,
  `delete_service`, `reset_demo_data`, `refresh_live_data`. These mirror
  the public surface of `QuotaStore` in the Swift app.

## Data model & storage

Port `QuotaService` field-for-field into a `serde`-derived Rust struct:

```rust
struct QuotaService {
    id: Uuid,
    app_name: String,
    name: String,
    quota_label: String,
    plan: String,
    symbol: String,
    current: i64,
    max: i64,
    reset_at: DateTime<Utc>,
    accent_hex: String,
    reset_window: Option<String>,   // "5h", "5d", "week", "month"
    disabled_reason: Option<String>,
    reset_note: Option<String>,
}
```

`percentage`, `percent_label`, `reset_window_label` become plain methods on
the struct (same semantics as the Swift computed properties, including the
same window-label localization strings).

Storage: a single JSON file (`quota-store.json`) in Tauri's app-data
directory (`%APPDATA%\AgentQuota\` on Windows), replacing `UserDefaults`.
Keep the same `storageVersion` integer + migration-on-mismatch pattern the
Swift app uses, so a schema bump can safely discard stale data instead of
crashing on deserialize.

Demo data (`demoServices()` equivalent) ships as a Rust function producing
the same six starter cards, used on first launch when no store file exists.

## Live usage fetching

New Rust module `live_usage.rs`, one function per provider, all async via
`tokio::process::Command` / `reqwest`, mirroring `LiveUsageFetcher`
one-for-one:

- **Claude**: run `claude -p /usage --output-format json --no-session-persistence`,
  parse the outer JSON envelope, then regex-parse the embedded text report
  for "current session"/"5 hour" and "current week" lines, same percent +
  reset-date extraction as `parseClaudeUsage`/`parseClaudeDate`.
- **Codex**: spawn `codex app-server --listen stdio://`, write the three
  JSON-RPC lines (`initialize`, `initialized`, `account/rateLimits/read`)
  to stdin, read line-delimited JSON from stdout until the response with
  `id == 2` arrives (45s timeout), extract `primary`/`secondary` rate-limit
  windows exactly as the Swift version does (window-duration-minutes →
  `5h`/`weekly` label mapping).
- **Agy**: run `agy -p /usage --output-format json`, group buckets by
  family (name contains "claude" → Claude, "gemini" → Gemini, else raw
  name), same disabled/reset-time filtering rules as the Swift version.
- **Copilot**: `gh api user --jq .login`, then
  `gh api /users/{login}/settings/billing/usage`, filter to the current
  month + `copilot` product + `AI Credit` SKU, sum quantities, cap against
  1500.
- **Grok**: read `%USERPROFILE%\.grok\auth.json`, pull the first non-empty
  key as bearer token, call
  `https://cli-chat-proxy.grok.com/v1/billing?format=credits` with
  `reqwest`, same fallback chain for `creditUsagePercent`/history/plan-tier
  string matching as the Swift version.

Each fetcher returns `Result<Vec<LiveQuota>, LiveUsageError>`; a top-level
`fetch_all()` runs all five concurrently (`tokio::join!` or a `JoinSet`),
collects successes into `updates` and failures into a Swift-parity `issues`
list, so one provider failing never blocks the other five.

**Executable discovery**: a Windows-appropriate candidate list — user's
`%USERPROFILE%\.local\bin`, `%APPDATA%\npm`, and whatever `where <name>`
resolves via `PATH` — replacing the Swift version's hardcoded
Homebrew/`/usr/local` paths. This is explicitly best-effort per Non-goals;
expect to adjust the candidate list once tested against a real Windows
install.

## Error handling

Same posture as the Swift app: a failed provider never blocks the others.
Fetch failures produce a message in the `issues` list (executable not
found, process failed, timed out, invalid response — same four error
categories as `LiveUsageError`), surfaced in the UI as a small issues
banner/log rather than blocking the popover. Cards for a failed provider
keep showing their last-known values; `disabledReason`/`resetNote` continue
to carry provider-specific "why this looks odd" text (e.g. Grok's
"Free limit · usage unavailable").

## Testing

No Windows machine with signed-in CLIs is available this round, so live
end-to-end fetches cannot be verified now. Testing strategy:

- Fixture-based unit tests for every parser: copy the sample JSON/text
  payload shapes the Swift version expects (Claude's text usage report,
  Agy's grouped-bucket JSON, Codex's JSON-RPC response, Copilot's
  `usageItems` array, Grok's billing JSON) into `windows/src-tauri/tests`
  fixtures, and assert the Rust parsing produces the same `LiveQuota`
  values the Swift logic would.
- Storage round-trip test: write a `QuotaService` list, reload, assert
  equality; test the storage-version-mismatch migration path resets to
  demo data.
- CLI invocation itself (process spawning, executable discovery, real
  network calls) is left for manual verification once the user has a
  Windows machine with the CLIs installed and signed in.
