# Instructions for coding agents

Burn shows AI coding subscription limits in the macOS menu bar (`Sources/Burn`, SwiftUI + AppKit)
and the Windows taskbar (`windows/`, Rust + Svelte). Setup, PR rules and code style are in
[CONTRIBUTING.md](CONTRIBUTING.md). This file holds the one rule that is easy to break by accident.
It covers the Mac app and the Windows panel (`windows/ui`) alike.

## Everything users see must stay themeable

Users restyle Burn with theme files in their own themes folder ([docs/themes.md](docs/themes.md)).
Those files outlive every update, and many are written by the user's own agent from that guide.
So the look is a public contract, and every new feature has to keep it:

1. **No color literals in views.** No `Color(red:…)`, `.white`, `.red`, `NSColor.systemRed`, hex
   strings. Read colors through `Theme(scheme)` (`theme.text`, `theme.accent`, `theme.fill(card)`).
   A tint derived from a token is fine: `theme.text.opacity(0.06)`.
   `scripts/check-theme-literals.sh` fails CI otherwise. In `windows/ui` the same goes for
   color literals outside `src/lib/theme.css`: use the CSS variables. `windows/scripts/check-theme-literals.sh`
   enforces it.
2. **Need a color no token covers? Add a token**, don't inline it:
   - a case in `ThemeToken` (`Sources/Burn/UI/ThemeSpec.swift`) with light and dark defaults,
   - an accessor in `Theme` (`Sources/Burn/UI/Theme.swift`),
   - a row in the table in `docs/themes.md` (a test fails until the row matches the defaults),
   - the same token on Windows, in the same PR: `windows/ui/src/lib/theme.css` (CSS variable
     `--` + token key) and `windows/crates/burn-core/src/theme.rs` (defaults and parser, a port
     of `ThemeSpec.swift`).
   Name it after its role (`danger`, `surface`), not its color.
3. **Never rename or remove a token, and never change what an existing one paints.** Users'
   theme files reference tokens by name. If a token must go, keep reading the old name as an alias.
4. **Defaults reproduce the built-in look.** A theme file only overrides; anything it leaves out
   falls back to `ThemeToken.standard`. New tokens must look right with no theme file at all, and
   in both light and dark.
5. **Shape and type come from the theme too.** Block corners use `Bento.blockShape` /
   `Bento.smallShape`, buttons and pills use `Bento.pill` (never `Capsule()`), spacing between
   blocks uses `Bento.gap`, text uses `Font.brand(size, weight)`. No hardcoded `cornerRadius` on
   blocks, no `.custom("…")` fonts, no `.system(size:)` for text (it is for SF Symbols and
   monospaced code only). In `windows/ui`: pills use `var(--pill)`, blocks `var(--radius)`, small
   blocks `var(--radius-small)`, text `var(--font)` / `var(--font-display)`.
6. **A new block takes a token, not a color.** Fill it with `.block(.accent)` /
   `.floating(.neutral, in:)` so it picks up the gradient, image or pattern a theme gives that
   token. A new kind of block that should be styled on its own gets its own token and an entry
   in `BlockBackground.slots`.
7. **The only exceptions** are the marks drawn over screenshots (`Theme.photoEdge` and friends):
   they must read on any image, so they are fixed. They still live in `Theme.swift`.
8. **Nothing the user customizes goes in the app bundle or gets overwritten.** User files live in
   `~/Library/Application Support/Burn/` (Windows: `%LOCALAPPDATA%\Burn\themes\`). Burn may create files there, but only ever rewrites its
   own (`themes/README.md`). Never migrate, reformat or "fix" a user's theme file.
9. **Built-in themes are ordinary theme files** in `assets/Themes/`, bundled with the app and
   listed in Settings. They use only what `docs/themes.md` documents, so users can copy them.
   A test parses each one on both platforms. They ship on macOS and Windows: name a font per
   system (`"text": ["Menlo", "Consolas"]`). After changing one, refresh the Windows demo data:
   `BURN_UPDATE_DEMO_THEMES=1 cargo test -p burn-core --test demo_themes` in `windows/`.
10. **Changed the theme format or a token? Update `docs/themes.md` in the same PR.** It ships
   inside the app and is copied to the user's themes folder as `README.md`: it is what their
   agent reads before writing a theme.

Before you finish a UI change, run it with a loud theme (set `accent`, `neutral`, `text`,
`surface` to obviously wrong colors, `shape.radius` and `shape.pill` to 0, a `dots` pattern on
every block) in light and dark. Anything that didn't
change is hardcoded.

## Checks

```sh
swift build && swift test          # includes the theme parser and the docs/themes.md contract
scripts/check-theme-literals.sh    # no hardcoded colors outside Theme.swift
scripts/build-app.sh --install     # run the real app

(cd windows && cargo test)                  # includes the Rust theme parser
(cd windows/ui && npm test && npm run check)
windows/scripts/check-theme-literals.sh     # no hardcoded colors outside theme.css
```
