# Burn for Windows

Burn's Windows app: the same limits, spend, shelf and settings as the Mac app, living in the
Windows 11 taskbar instead of the menu bar.

## Install

Download `Burn-Setup.exe` from the [latest release](https://github.com/noyex/burn/releases/latest)
and run it. It installs for the current user (no admin rights) and starts Burn; Burn updates itself
from then on.

The installer isn't signed yet. Windows shows "Windows protected your PC": click **More info →
Run anyway**. With Smart App Control turned on, Windows blocks unsigned apps outright.

## How it works

| Part | Where |
|---|---|
| Taskbar widget | `crates/burn-taskbar`: a native Direct2D window inside Explorer's taskbar, next to the notification area. A tray icon replaces it when it can't be placed, or when Settings asks for one. |
| Panel | `ui/` (Svelte) in one frameless, transparent WebView2 window (`crates/burn-app`, Tauri 2), suspended after 3 minutes hidden. |
| Data | `crates/burn-core`: a port of the Mac app's `Sources/Burn/Data`. Per-record results match the Mac app exactly. |

Burn reads provider credentials, read only, and never refreshes or prints tokens:

| Provider | File |
|---|---|
| Claude | `%USERPROFILE%\.claude\.credentials.json` |
| Codex | `%USERPROFILE%\.codex\auth.json` |
| Cursor | `%APPDATA%\Cursor\User\globalStorage\state.vscdb` |

Its own files are in `%LOCALAPPDATA%\Burn`: `usage.sqlite`, `settings.json`, `themes\`, `Shelf\`, `burn.log`.

Themes are the same JSON files as on the Mac: see [docs/themes.md](../docs/themes.md).

## Develop

Needs Rust and Node. On macOS everything but the widget, the tray icon and the clipboard runs.

```sh
cd windows
cargo test                                         # data layer, settings, shelf, share card
(cd ui && npm ci && npm test && npm run check)     # panel UI
(cd crates/burn-app && ../../ui/node_modules/.bin/tauri dev)   # the panel with real data
cargo run -p burn-core --bin burn-cli -- import    # import and print totals (store in ~/.burn-dev)
```

`cargo test` includes `tests/fixtures.rs`, which imports a fixture home and compares every row with
`expected-usage.tsv`, written by the Mac app's importer. After changing the fixtures or the Swift
parsers, regenerate it on a Mac with `scripts/update-usage-fixture.sh`.

In a plain browser (`cd ui && npm run dev`) the panel shows demo data: `?demo=loading`,
`?demo=signedOut`, `?demo=empty`, `?demo=importing`, `?demo=emptyShelf`. `?theme=terminal` turns
on a built-in theme and `#settings/theme` opens the theme page.

`cargo clippy -p burn-taskbar --target x86_64-pc-windows-msvc` type-checks the widget from a Mac.
The rest bundles SQLite (C) and needs the Windows SDK: the **Windows** workflow lints, tests and
builds everything on `windows-latest` and uploads `burn.exe` and `burn-cli.exe`.

Releases come from the **Release** workflow, which builds the Mac app and the Windows installer
and publishes both in one GitHub release.
