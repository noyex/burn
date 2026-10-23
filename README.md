# Burn

A macOS menu bar app that shows AI subscription limits (Claude, Codex, Cursor) and
usage/cost stats from the `t3-usage` SQLite database (`~/.t3-usage/usage.sqlite`).

## Build & install

```sh
scripts/build-app.sh          # builds build/Burn.app
scripts/build-app.sh --install # also copies it to /Applications and launches it
```

## Data sources

| What | Where |
|---|---|
| Claude limits | `api.anthropic.com/api/oauth/usage`, token from the `Claude Code-credentials` Keychain item |
| Codex limits | `chatgpt.com/backend-api/wham/usage`, token from `~/.codex/auth.json` |
| Cursor limits | `api2.cursor.sh` `DashboardService/GetCurrentPeriodUsage`, token from the Cursor Keychain item or Cursor's `state.vscdb` |
| Cost / tokens | `~/.t3-usage/usage.sqlite`, refreshed by running `t3usage.py sync` |

Tokens are only read, never refreshed or written, and never leave the machine except
to the provider they belong to.
