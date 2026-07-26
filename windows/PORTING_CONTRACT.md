# A-mon Windows native rewrite contract

The Windows client is a clean WPF rewrite of the current macOS product behavior.
The legacy Go client and the first WPF prototype are reference implementations
only and are removed by this rewrite.

## Product contract

- One user-facing Windows application: `A-mon.exe`.
- The application lives in the notification area and opens or closes the
  dashboard on a left click.
- The tray icon and pet expose the same right-click menu.
- Local usage supports Claude Code, Codex CLI, OpenCode, Cursor, Gemini CLI,
  Qwen Code, and Copilot CLI.
- Live quota supports Claude, Codex, Cursor, Copilot, Antigravity, Devin, Grok,
  OpenRouter, and Z.AI.
- Live activity, session history, transcripts, audits, and pet task previews
  remain local to the device.
- The pet shows only concurrently active sessions in its `1/N` carousel and
  exposes input, output, and token summaries.

## Privacy boundary

The local database may contain `tool_totals` and local session summaries.
An upload database is always created from scratch and contains exactly:

- `meta`
- `usage_daily`

It must never contain session IDs, project names, branches, prompts, response
previews, transcripts, audit results, pet state, or deleted SQLite pages from
the local database.

## Compatibility

- Existing data under `%APPDATA%\A-mon` is preserved.
- Existing `config.json` fields and unknown extension fields survive a
  load/save round trip.
- A missing `auto_update` field means automatic updates are enabled.
- Existing `device_id`, `usage.db`, session caches, and custom pet paths are
  migrated without destructive recreation.

## Automatic update behavior

- New installs default to automatic updates enabled.
- Enabled: periodically check, download, validate, stage, replace, restart, and
  roll back on failure.
- Disabled: checking remains available, but no background download or install
  is allowed.
- Manual **Check for updates** and **Install now** remain available.
- Settings are persisted immediately and survive restart.
- Update payloads are architecture-checked and SHA-256 verified. Release
  signing and Authenticode verification are required before production
  publishing.

## Baseline verification

Before deletion, the legacy first-party Go package tests passed on macOS except
for the root package, whose Windows-only popup package is excluded by build
constraints. This is the expected host limitation. Parser, provider, report,
session, store, update, and web UI packages passed.

The new implementation is accepted only after its frozen fixtures, privacy
tests, configuration migration tests, x64/Arm64 publish jobs, and Windows
runtime smoke tests pass.

## Current implementation status

- Local usage collectors are implemented for all seven contracted tools.
- Collection runs at startup and every ten minutes, refreshes the recent
  30-day window, and preserves older history.
- A failed scan cannot replace the last known good SQLite rows.
- The dashboard shows aggregate input, output, cache, today, total, and session
  counts without reading or storing prompt/response bodies.
- `AMon.Scanner` exposes the same normalized aggregate as local JSON for
  parser parity diagnostics.
- Live provider quotas, local active-session transcripts, and production
  Windows runtime smoke tests remain later milestones.
