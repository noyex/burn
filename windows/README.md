# Burn for Windows (work in progress)

Milestone 1: a spike that embeds Burn's widget in the Windows 11 taskbar, next to the
notification area, with demo data. It also adds a tray icon (fallback and menu) and a
placeholder panel that opens away from the taskbar.

## Try it

Download `burn-spike` from the latest run of the **Windows** workflow and run `burn-spike.exe`.
Right-click the widget or the tray icon for **Next demo values**, **Open log** and **Quit Burn**.
The log (`%LOCALAPPDATA%\Burn\spike.log`) lists the taskbar's windows and every placement.

## Develop

```sh
cd windows
cargo test                                        # shared layout code, runs on macOS too
cargo clippy --target x86_64-pc-windows-msvc      # type-checks the Windows code from a Mac
```

Linking and running need Windows; CI builds the exe on `windows-latest`.
