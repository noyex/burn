# Burn

A tiny native macOS menu bar app that shows how much of your AI coding subscriptions
you've burned through: live rate limits for **Claude Code**, **Codex** and **Cursor**,
plus what your usage would have cost at API prices — today, this week, this month and all time.

<img src="docs/screenshot.png" width="320" alt="Burn popover">

- **Menu bar**: each provider's logo with what's left of its most-used limit. Turns orange at 20% left, red at 0%.
- **Limits**: every window the provider reports (Claude 5h / weekly, Codex, Cursor monthly / API) with reset times.
- **Usage**: cost, tokens and a per-provider chart, computed locally from Claude Code and Codex session logs.
- **Settings**: choose which providers appear in the menu bar and which limit each one shows; launch at login.

Native SwiftUI + AppKit, no Electron, no dependencies, ~1 MB.

## Requirements

- macOS 14 or later
- At least one of: [Claude Code](https://claude.com/claude-code), [Codex CLI](https://github.com/openai/codex), [Cursor](https://cursor.com), signed in on this Mac
- Xcode command line tools (Swift 6) to build

## Install

```sh
git clone https://github.com/noyex/burn.git
cd burn
scripts/build-app.sh --install   # builds Burn.app, copies it to /Applications and launches it
```

`scripts/build-app.sh` without arguments only builds `build/Burn.app`.

## How it works

| What | Source |
|---|---|
| Claude limits | `api.anthropic.com/api/oauth/usage`, using Claude Code's token from the Keychain (`Claude Code-credentials`) |
| Codex limits | `chatgpt.com/backend-api/wham/usage`, using the token in `~/.codex/auth.json` |
| Cursor limits | `api2.cursor.sh` `DashboardService/GetCurrentPeriodUsage`, using Cursor's token |
| Usage & cost | Claude Code logs (`~/.claude/projects`) and Codex logs (`~/.codex/sessions`), imported incrementally into `~/Library/Application Support/Burn/usage.sqlite` |
| Prices | [LiteLLM's model price list](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json), cached for 24 h (or T3 Code's copy, if installed) |

Privacy: tokens are only read, never refreshed or written, and only sent to the provider they
belong to. Usage data never leaves your Mac. Costs are estimates at API list prices, not what
your subscription actually charges.

Claude Code and Codex delete old session logs, so Burn keeps everything it has imported in its own
database: history builds up from the first launch on.

## Development

```sh
swift build
.build/debug/Burn --dump     # print live limits and usage summaries
.build/debug/Burn --import   # run the log importer once and print timings
.build/debug/Burn --preview  # popover content in a plain off-screen window, for screenshots
```

## License

MIT. Provider logos come from [Simple Icons](https://simpleicons.org) (CC0) and are trademarks of their owners.
