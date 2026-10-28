# Contributing to Burn

Thanks for helping out. Bug fixes, small improvements and new providers are all welcome.
For anything bigger, open an issue first so we can agree on the approach before you write the code.

## Setup

You need macOS 14+ and the Xcode command line tools with Swift 6 (Xcode 26 to build the macOS 26 glass effects).

```sh
swift build
scripts/build-app.sh --install   # builds Burn.app, copies it to /Applications and launches it
.build/debug/Burn --dump         # print live limits and usage summaries
.build/debug/Burn --preview      # popover content in a plain window, handy for screenshots
```

## Pull requests

You can't push to this repo directly: every change goes through a pull request from your fork,
and only the maintainer (@noyex) can approve and merge it.

1. Fork the repo on GitHub, then clone your fork and create a branch:

   ```sh
   git clone https://github.com/<you>/burn.git
   cd burn
   git switch -c fix/<short-name>   # or feat/<short-name>
   ```

2. Make the change. Keep the PR focused on one thing: small PRs get merged faster.
3. Check that it builds and works: `scripts/build-app.sh --universal`, then run the app with your change
   (`scripts/build-app.sh --install`).
4. Push the branch to your fork and open a PR against `noyex/burn` `main`
   (GitHub shows a "Compare & pull request" button, or run `gh pr create --repo noyex/burn`).
5. Fill in the PR template: what and why, how to test, screenshots for anything visible.

### What happens next

- On your first PR, the checks (build, title, screenshots) start only after a maintainer approves the run.
  That's a GitHub safety rule for outside contributors, not a sign anything is wrong.
- The maintainer reviews the PR. Pushing new commits after an approval needs a fresh approval.
- All checks must pass and all review comments must be resolved before the PR can be merged.
- PRs are squash-merged into `main` by the maintainer. A new release with your change follows when the
  maintainer cuts one.

### Title

PRs are squash-merged, so the title becomes the commit on `main`. Use
[Conventional Commits](https://www.conventionalcommits.org): `feat: …`, `fix: …`, `refactor: …`,
`perf: …`, `style: …`, `docs: …`, `test: …`, `build: …`, `ci: …`, `chore: …`. Imperative mood, in English,
for example `fix: show Codex limits after the token rotates`.

### Screenshots

**Every change you can see in the app needs a screenshot or a short video in the PR description.**
If you change something that already exists, show it before and after. Light and dark mode both matter
when you touch colors.

A check enforces this: PRs that touch `Sources/Burn/UI/`, `Sources/Burn/Shelf/`, `assets/` or `docs/screenshot.png` fail
until the description has an image or video. If you only refactored UI code and nothing visible changed,
say so in the description and a maintainer will add the `no-ui` label.

`.build/debug/Burn --preview` opens the popover in a plain window, which is the easiest way to capture it.

### Network and privacy

Burn reads tokens for Claude Code, Codex and Cursor, so changes that send data anywhere get extra scrutiny:

- Tokens are only read and only sent to the provider they belong to. Never log or persist them.
- Usage data stays on the Mac.
- A new host Burn talks to needs a clear reason in the PR description.
- No new dependencies without discussing it in an issue first.

## Code style

Match the code around you: SwiftUI + AppKit, no third-party packages, small focused files.
Comments explain why, not what.

## Releases

Maintainers release from GitHub: **Actions → Release → Run workflow** with a version like `v1.2.3`.
