import { remaining } from "./format";
import type { CardColor, ProviderId } from "./types";

export type Level = "normal" | "warn" | "full";

/** Same thresholds as the Mac menu bar: orange at 20% left, red at 0%, from the rounded share left. */
export function level(used: number): Level {
  const left = remaining(used);
  return left <= 0 ? "full" : left <= 20 ? "warn" : "normal";
}

export const BRAND: Record<ProviderId, CardColor> = { claude: "coral", codex: "mono", cursor: "lavender" };

/** Alert text inside a pill filled with the block's ink, readable on light and dark ink alike. */
export function alertColor(l: Level, color: CardColor, dark: boolean): string {
  const lightInk = color === "coral" || (color === "mono" && !dark);
  if (l === "normal") return `var(--${color}-ink)`;
  if (l === "warn") return lightInk ? "var(--warn-on-light)" : "var(--warn-on-dark)";
  return lightInk ? "var(--full-on-light)" : "var(--full-on-dark)";
}
