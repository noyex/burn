// Lays the active theme over the defaults in `theme.css` (Theme.swift on the Mac): colors, shape
// and fonts become CSS variables on the root, backgrounds are read by `BlockArt.svelte`.

import { fileUrl, isTauri } from "./api";
import type { CardColor, ThemeBackground, ThemeLook, ThemePaint } from "./types";

const CARD_COLORS: CardColor[] = ["coral", "mono", "lavender", "sky"];

export const theme = $state<{
  backgrounds: Record<string, ThemeBackground>;
  /** Whether a card color's ink is light, which picks the alert colors that read on it. */
  lightInk: Record<CardColor, boolean>;
}>({
  backgrounds: {},
  lightInk: { coral: true, mono: true, lavender: false, sky: false },
});

/** Variables set by the last theme, removed when the next one doesn't set them. */
let applied: string[] = [];

/** A family name as a CSS string. */
const family = (name: string) => `"${name.replace(/["\\]/g, "")}"`;

export function applyTheme(look: ThemeLook, dark: boolean) {
  if (typeof document === "undefined") return;
  const style = document.documentElement.style;
  const next: Record<string, string> = {};
  for (const [token, color] of Object.entries(dark ? look.dark : look.light)) next[`--${token}`] = color;
  next["--radius"] = `${look.radius}px`;
  next["--gap"] = `${look.gap}px`;
  next["--pill"] = `${look.pill}px`;
  if (look.textFont) next["--theme-font"] = family(look.textFont);
  if (look.displayFont) next["--theme-font-display"] = family(look.displayFont);

  for (const name of applied) if (!(name in next)) style.removeProperty(name);
  for (const [name, value] of Object.entries(next)) style.setProperty(name, value);
  applied = Object.keys(next);

  theme.backgrounds = look.backgrounds;
  const computed = getComputedStyle(document.documentElement);
  document.documentElement.dataset.blocks = isLight(computed.getPropertyValue("--neutral")) ? "light" : "dark";
  for (const c of CARD_COLORS) theme.lightInk[c] = isLight(computed.getPropertyValue(`--${c}-ink`));
}

/** WCAG relative luminance above one half, as `RGBA.isLight` on the Mac. Unreadable colors count as light. */
export function isLight(color: string): boolean {
  let hex = color.trim().replace(/^#/, "");
  if (hex.length === 3) hex = [...hex].map((c) => c + c).join("");
  if (!/^[0-9a-f]{6}([0-9a-f]{2})?$/i.test(hex)) return true;
  const linear = (i: number) => {
    const c = parseInt(hex.slice(i, i + 2), 16) / 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * linear(0) + 0.7152 * linear(2) + 0.0722 * linear(4) > 0.5;
}

/** `linear-gradient(...)` for a theme gradient; the angle means what it means in CSS. */
export function gradientCss(g: { colors: ThemePaint[]; angle: number }): string {
  return `linear-gradient(${g.angle}deg, ${g.colors.join(", ")})`;
}

/** URL of a background picture, or null outside the app, where the file can't be read. */
export function imageCss(image: { path: string; version: number }): string | null {
  if (!isTauri) return null;
  return `url("${fileUrl(image.path)}?v=${image.version}")`;
}

/**
 * Background layers that draw a pattern the way `PatternCanvas` does on the Mac: marks start half
 * a step in, `size` is the dot diameter or the line width.
 */
export function patternCss(p: NonNullable<ThemeBackground["pattern"]>): { image: string; size: string } {
  const c = p.color;
  const half = p.size / 2;
  // A quarter pixel of blend on each side stands in for antialiasing.
  const edge = (at: number) => `${c} ${Math.max(at - 0.25, 0)}px, transparent ${at + 0.25}px`;
  if (p.type === "dots") {
    return { image: `radial-gradient(circle at center, ${edge(half)})`, size: `${p.spacing}px ${p.spacing}px` };
  }
  if (p.type === "grid") {
    const line = (to: string) =>
      `linear-gradient(${to}, transparent calc(50% - ${half}px), ${c} calc(50% - ${half}px), ${c} calc(50% + ${half}px), transparent calc(50% + ${half}px))`;
    return { image: `${line("to right")}, ${line("to bottom")}`, size: `${p.spacing}px ${p.spacing}px` };
  }
  // Diagonals rising to the right, `spacing` apart along the horizontal; the first one runs
  // through the top left corner.
  const period = p.spacing / Math.SQRT2;
  return {
    image: `repeating-linear-gradient(135deg, ${c} 0, ${c} ${half}px, transparent ${half}px, transparent ${period - half}px, ${c} ${period - half}px, ${c} ${period}px)`,
    size: "auto",
  };
}
