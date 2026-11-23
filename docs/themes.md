# Burn themes

A theme changes Burn's colors, block backgrounds, corners, spacing and fonts. Themes are plain JSON files in
your themes folder. Burn updates never touch that folder, so your themes stay as you left them.
A theme file works on macOS and Windows unchanged.

| | Themes folder |
|---|---|
| macOS | `~/Library/Application Support/Burn/themes/` |
| Windows | `%LOCALAPPDATA%\Burn\themes\` |

The same three files live in it on both systems:

| File | What it is |
|---|---|
| `<name>.json` | A theme. One file per theme. |
| `active.txt` | The name of the theme in use, without `.json`. Empty is the built-in look. |
| `README.md` | This guide. Burn rewrites it on launch, so don't keep notes in it. |

Burn watches the folder: save a file and the open panel changes within a second, no restart.

## Built-in themes

Burn ships with a few ready-made themes, listed in Settings → Theme above your own: `aurora`,
`circuit`, `ember`, `frost`, `glow-dots`, `neon`, `nyx`, `obsidian`, `pastel`, `prism`, `rain`, `raster`, `tide` and `titanium`. Their names work in `active.txt` too.

Their files sit next to the app and an update replaces them:

| | Built-in theme files |
|---|---|
| macOS | `/Applications/Burn.app/Contents/Resources/Themes/` |
| Windows | `%LOCALAPPDATA%\Burn\built-in-themes\` |

To change one, copy it into your themes folder and edit the copy: a file
of yours with the same name wins over the built-in one. They are also good examples to start from.

## Make a theme

1. Write `midnight.json` in your themes folder:

   ```json
   {
     "name": "Midnight",
     "colors": { "accent": "#7C5CFF" },
     "light": { "base": "#F4F1FF" },
     "dark": { "base": "#0B0B10", "neutral": "#16161F" },
     "shape": { "radius": 18, "gap": 8 },
     "fonts": { "text": ["Avenir Next", "Segoe UI"] },
     "backgrounds": {
       "accent": { "pattern": { "type": "dots", "spacing": 5, "fade": "top" } }
     }
   }
   ```

2. Turn it on: write `midnight` into `active.txt`, or pick it in Burn → Settings → Theme.

   ```sh
   echo midnight > ~/Library/Application\ Support/Burn/themes/active.txt          # macOS
   ```

   ```powershell
   Set-Content "$env:LOCALAPPDATA\Burn\themes\active.txt" midnight               # Windows
   ```

3. Check it. This prints every value Burn skipped and why (exit code 0 means no problems):

   ```sh
   /Applications/Burn.app/Contents/MacOS/Burn --check-theme midnight             # macOS
   ```

   ```powershell
   & "$env:LOCALAPPDATA\Burn\burn.exe" --check-theme midnight | Out-Host        # Windows
   ```

   The `| Out-Host` makes PowerShell wait for the result.

Problems also show in red under Settings → Theme. A broken theme never breaks Burn: whatever
can't be read falls back to the built-in value.

## How a theme is applied

A theme is laid over the built-in look. **Only write the values you want to change.** Everything
you leave out keeps its built-in value, which is also why old themes keep working when a new
Burn version adds tokens.

- `colors` applies to both light and dark appearance.
- `light` and `dark` apply to one appearance and win over `colors`.
- Burn follows the system appearance on both systems. Set a token in both `light` and `dark` (or once in
  `colors`) if it should look the same in both.

## Colors

Write colors as `#RRGGBB`, or `#RRGGBBAA` when they need transparency (`AA` is the alpha, `00`
transparent to `FF` solid). Named colors and `rgb()` are not supported.

| Token | Light | Dark | Where it shows |
|---|---|---|---|
| `base` | `#F7F5F2` | `#161514` | Text on a prominent button, background of the share image |
| `neutral` | `#ECE9E4` | `#252321` | Neutral blocks: settings groups, buttons, shelf tiles, the app list on the System tab |
| `neutral-hover` | `#E3DFD9` | `#302D2B` | A neutral button under the pointer |
| `raised` | `#FFFFFF` | `#3D3936` | The selected pill in a segmented control |
| `text` | `#1C1A17` | `#F2EFEA` | Main text, prominent buttons |
| `secondary` | `#7A746C` | `#9C958C` | Muted text and icons |
| `surface` | `#FBFAF8` | `#1F1D1B` | Floating chrome: the settings panel, footer, tooltips |
| `switcher` | `#1C1A17` | `#2E2B28` | The Usage / System / Shelf tab capsule |
| `switcher-ink` | `#FFFFFF` | `#FFFFFF` | Icons on the tab capsule |
| `hairline` | `#0000000A` | `#FFFFFF14` | Thin edge around every block |
| `shadow` | `#00000029` | `#00000066` | Shadow under every block |
| `accent` | `#DFF26B` | `#DFF26B` | The spend block, the import progress, the empty shelf, the CPU block on the System tab |
| `accent-ink` | `#1A1D06` | `#1A1D06` | Text and bars on `accent` |
| `coral` | `#D97757` | `#D97757` | Provider card color "Coral" (Claude by default), the network block on the System tab |
| `coral-ink` | `#FFFFFF` | `#FFFFFF` | Text on `coral` |
| `mono` | `#141414` | `#F2F1EE` | Provider card color "Mono" (Codex by default), the disk block on the System tab |
| `mono-ink` | `#FFFFFF` | `#141414` | Text on `mono` |
| `lavender` | `#C9C5FF` | `#C9C5FF` | Provider card color "Lavender" (Cursor by default), the memory block on the System tab |
| `lavender-ink` | `#1B1840` | `#1B1840` | Text on `lavender` |
| `sky` | `#B4DDF7` | `#B4DDF7` | Provider card color "Sky", the battery block on the System tab |
| `sky-ink` | `#0C2C42` | `#0C2C42` | Text on `sky` |
| `warn-on-light` | `#C25E00` | `#C25E00` | "Almost out" text on a card whose ink is light |
| `full-on-light` | `#D92D20` | `#D92D20` | "Limit reached" text on a card whose ink is light |
| `warn-on-dark` | `#FFB340` | `#FFB340` | "Almost out" text on a card whose ink is dark |
| `full-on-dark` | `#FF6B5E` | `#FF6B5E` | "Limit reached" text on a card whose ink is dark |
| `danger` | `#FF3B30` | `#FF453A` | Destructive buttons, theme problems |
| `menubar-warn` | `system` | `system` | Menu bar (Windows: taskbar) percentage at 20% left. Default: system orange (Windows: Burn's orange) |
| `menubar-full` | `system` | `system` | Menu bar (Windows: taskbar) percentage at 0% left. Default: system red (Windows: Burn's red) |
| `selection` | `system` | `system` | Ring and checkmark on selected shelf screenshots. Default: the system accent color (Windows: the text color) |

Good to know:

- **Ink follows the fill.** Change `accent`, `switcher`, `coral`, `mono`, `lavender` or `sky`
  without its `-ink` and Burn picks near-black or white, whichever reads better. Set the `-ink`
  yourself for anything else.
- **Card colors are slots.** Each provider's card uses one of `coral`, `mono`, `lavender`, `sky`
  (chosen per provider in Settings). A theme recolors the slots; it can't add new ones.
- **Menu bar tokens** follow the menu bar's own light or dark look, which depends on the
  wallpaper, not on the system appearance. On Windows they color the percentage in the taskbar
  widget and follow the taskbar's light or dark mode. The normal percentage always uses the system text color.
- The blocks float over the desktop, so there is no window background to set.

## Shape

| Key | Default | Range | What it changes |
|---|---|---|---|
| `shape.radius` | `14` | 0–24 | Corner radius of every block |
| `shape.gap` | `6` | 2–12 | Space between blocks |
| `shape.pill` | `999` | 0–999 | Corner radius of buttons, pills and the tab switcher. `999` is fully round |

Values outside the range are clamped. For a square look set `"radius": 0, "pill": 0`; for soft
squares try `"radius": 6, "pill": 6`.

## Block backgrounds

A block is filled with its color token. `backgrounds` draws more on top of that fill: a gradient,
then an image, then a pattern. Use any one or combine them.

```json
"backgrounds": {
  "accent": {
    "gradient": { "colors": ["#7C5CFF", "#FF5C8A"], "angle": 135 },
    "pattern": { "type": "dots", "color": "#FFFFFF", "opacity": 0.3, "spacing": 5, "size": 1.2, "fade": "top" }
  },
  "surface": { "image": { "file": "paper.png", "opacity": 0.4 } }
}
```

Blocks you can set: `accent` (the spend block), `coral`, `mono`, `lavender`, `sky` (provider
cards), `neutral` (notices, empty states and the app list on the System tab) and `surface` (the
settings panel). The System tab's blocks reuse these: disk `mono`, CPU `accent`, memory
`lavender`, battery `sky`, network `coral`.

| Key | Default | Range | What it does |
|---|---|---|---|
| `gradient.colors` | | 2 or more | Colors of a linear gradient |
| `gradient.angle` | `180` | -360–360 | Direction in degrees, as in CSS: `0` bottom to top, `90` left to right, `180` top to bottom |
| `image.file` | | | A picture in the themes folder (PNG or JPEG on both systems), scaled to fill the block |
| `image.opacity` | `1` | 0–1 | |
| `pattern.type` | | `dots`, `grid`, `lines`, `wave`, `level`, `halftone`, `rain` | The last four move, see below |
| `pattern.color` | the block's ink | | |
| `pattern.highlight` | `pattern.color` | | Wave crests, the `level` surface, the heads of `rain` drops |
| `pattern.opacity` | `0.25` | 0–1 | |
| `pattern.spacing` | `8` | 3–64 | Distance between marks, in points |
| `pattern.size` | `1.5` | 0.5–16 | Dot diameter or line width, in points |
| `pattern.fade` | none | `top`, `bottom` | Edge the pattern fades out toward |

### Animated patterns

| Type | What moves |
|---|---|
| `wave` | Rows of dots in perspective roll like a sea in the lower part of the block. Crests light up in `highlight`. |
| `level` | The block fills with dots up to what's left of its limit (the big number), under a gently moving surface drawn in `highlight`. Blocks without a percentage fill halfway. |
| `halftone` | A grid of dots that swell and shrink in slowly drifting patches. `size` is the largest dot. |
| `rain` | Drops of dots fall down columns and leave a fading trail. The drop's head is drawn in `highlight`. |

`spacing` is the distance between dots (for `wave`, in the middle row: rows further back are
tighter) and `size` the dot diameter. They move only while the panel is open, stand still when
Reduce Motion is on (Windows: when animations are off), and the share image shows a still frame.
To give every block its own color, set a different `color` or `highlight` per block.

Any color here is `#RRGGBB`, `#RRGGBBAA`, or the name of a token (`"accent-ink"`), which then
follows light and dark (not the `system` ones). The share image uses the same backgrounds. Text sits on top of the background, so keep it calm enough to read: the
block's `-ink` color must stay readable across the whole gradient or image.

## Fonts

| Key | Default | What it changes |
|---|---|---|
| `fonts.text` | Bricolage Grotesque | All text |
| `fonts.display` | same as `fonts.text` | The big numbers |

Use the family name of a font installed on this computer, as shown in Font Book (macOS) or
Settings → Personalization → Fonts (Windows), for example `"Avenir Next"` or `"JetBrains Mono"`.
A font that isn't installed is skipped.

Give a list to name one font per system. The first installed one wins:
`"text": ["Menlo", "Cascadia Mono", "Consolas"]`. A single name still works.

Burn uses the medium, bold and heavy weights, so pick a family that has them.

## For coding agents

When someone asks you to make or change a Burn theme:

1. Read the token table above. Use only these keys; unknown keys are reported and ignored.
2. Write or edit one `<name>.json` in the themes folder (macOS
   `~/Library/Application Support/Burn/themes/`, Windows `%LOCALAPPDATA%\Burn\themes\`). Lowercase file name, no spaces.
   Background pictures go in the same folder and are named in `image.file`.
   Change only what the request needs and leave the rest out.
3. Cover both appearances: put a color in `colors` if it works on light and dark, otherwise set
   it in `light` and `dark` separately. Keep text readable on its fill (aim for 4.5:1 contrast).
4. Write the theme name into `active.txt`.
5. Check it and fix what it reports. The files work on both systems, so name a font per system
   if the theme sets one.
   - macOS: `/Applications/Burn.app/Contents/MacOS/Burn --check-theme <name>`
   - Windows: `& "$env:LOCALAPPDATA\Burn\burn.exe" --check-theme <name> | Out-Host`
6. Never edit files inside `Burn.app` or `built-in-themes`: an update replaces them. Never edit this `README.md`.
   To adjust a built-in theme, copy it into the themes folder first.

To go back to the built-in look, empty `active.txt`.
