# amon for Windows

Native Windows notification-area client implemented with .NET 10 and WPF. The
legacy Go client and the first WPF prototype were removed in favor of this clean
rewrite.

## Build and test

```powershell
dotnet restore AMon.Windows.slnx
dotnet build AMon.Windows.slnx -c Release
dotnet test AMon.Windows.slnx -c Release
dotnet run --project src/AMon.Scanner/AMon.Scanner.csproj -c Release
dotnet publish src/AMon.App/AMon.App.csproj -c Release -r win-x64 --self-contained true
```

Publishing `AMon.App` for `win-x64` or `win-arm64` also publishes the matching
self-contained, single-file Claude hook at
`Hooks/AMon.ClaudeHook.exe`. The app resolves the hook relative to
`AppContext.BaseDirectory`, so keep the `Hooks` directory beside the legacy
`A-mon.exe` filename when copying or packaging a published build. Existing
updaters require that filename; the product shown to users is `amon`.
`make dist` preserves this directory in both architecture-specific ZIP files.

The app scans Claude Code, Codex CLI, OpenCode, Cursor, Gemini CLI, Qwen Code,
and Copilot CLI on startup and every ten minutes. Only normalized token totals
are written to the compatibility path `%APPDATA%\A-mon\usage.db`; prompts and
response bodies are never stored or printed. The diagnostic scanner prints the
same aggregate model as JSON so it can be compared with the macOS scanner.

Cursor v3 no longer writes recent token counts to `state.vscdb`, so the Cursor
collector uses the existing local Cursor access token to request the official
`cursor.com` usage-events CSV. The token and response body are never persisted
by amon; offline or signed-out clients retain the local historical result.

Official artifacts are built on Windows CI for `win-x64` and `win-arm64`.
The uploaded release bundles use the server channel names `windows-x64` and
`windows-arm64`; each contains one architecture-specific ZIP plus `latest.json`
with a matching `architecture` field. The updater selects the channel from
`RuntimeInformation.ProcessArchitecture` and rejects a mismatched manifest
before downloading. Only x64 can fall back to the historical `windows`
channel, which is treated as legacy x64. ARM64 never falls back across
architectures.
Tray, pet, installer, signing, and update replacement tests require Windows.

## Bundled pet

Published builds copy `assets/pets/Amon.webp` to
`Assets/Pets/Amon.webp` beside the executable. Runtime selection is a valid
custom sprite first, bundled `amon` second, and the existing geometric avatar
last. Only the custom path is stored in `config.json`; reset clears that value
and returns to bundled `amon` without persisting an installation-specific
absolute path.

The bundled v3 sheet uses all twelve rows. Reviewing activity selects `Review`,
horizontal pet dragging selects `RunningLeft` or `RunningRight`, and a newly
completed task plays `Jumping`, then `RunningAway`, before `Waving`.

## Settings and privacy

Existing data remains under the legacy `%APPDATA%\A-mon\config.json` and
`usage.db` paths to preserve upgrades. A missing
`auto_update` setting means automatic updates are enabled. Changing the toggle
in the WPF settings page is persisted immediately.

Local session details, prompts, response previews, project names, and audits are
never uploaded. Reporting creates a new SQLite database containing only `meta`
and `usage_daily`.

See [PORTING_CONTRACT.md](PORTING_CONTRACT.md) for the acceptance contract.
