// Port of `PanelLayout.swift` and the panel parts of `AppModel.swift`.

import { remaining } from "./format";
import { limitsOf, PROVIDERS, type CardSize, type LimitWindow, type PanelLayout, type ProviderId, type ProviderLimits, type Settings, type Snapshot } from "./types";

export const HIGHEST = "highest";

/** Size of each card under `layout`; `custom` gives the size saved per provider. */
export function sizes(layout: PanelLayout, cards: ProviderId[], custom: (p: ProviderId) => CardSize): Map<ProviderId, CardSize> {
  return new Map(
    cards.map((p, i) => {
      let size: CardSize;
      switch (layout) {
        case "custom":
          size = custom(p);
          break;
        case "grid":
          size = "m";
          break;
        case "list":
          size = "s";
          break;
        case "auto":
          size = cards.length === 1 ? "l" : cards.length === 2 ? "m" : i === 0 ? "l" : "s";
          break;
      }
      return [p, size];
    }),
  );
}

/** Rows of cards: two M cards in a row share it, everything else gets a row of its own. */
export function rows(cards: ProviderId[], sizeOf: Map<ProviderId, CardSize>): ProviderId[][] {
  const out: ProviderId[][] = [];
  for (const p of cards) {
    const last = out[out.length - 1];
    if (sizeOf.get(p) === "m" && last && last.length === 1 && sizeOf.get(last[0]) === "m") last.push(p);
    else out.push([p]);
  }
  return out;
}

/** Least left first; providers without a number keep their manual order after the rest. */
export function closestToLimit(providers: ProviderId[], remaining: (p: ProviderId) => number | null): ProviderId[] {
  const known = providers
    .map((p, i) => ({ p, i, r: remaining(p) }))
    .filter((x): x is { p: ProviderId; i: number; r: number } => x.r != null)
    .sort((a, b) => (a.r !== b.r ? a.r - b.r : a.i - b.i))
    .map((x) => x.p);
  return [...known, ...providers.filter((p) => !known.includes(p))];
}

/** Puts `visible` into the slots the visible providers held in `order`, so hidden ones keep their place. */
export function merge(visible: ProviderId[], order: ProviderId[]): ProviderId[] {
  let i = 0;
  const merged = order.map((p) => (visible.includes(p) ? (visible[i++] ?? p) : p));
  return [...merged, ...visible.filter((p) => !merged.includes(p))];
}

/** Saved order, dropping unknown ids and adding providers it doesn't know yet. */
export function order(saved: string[]): ProviderId[] {
  const out: ProviderId[] = [];
  for (const s of saved) {
    const p = PROVIDERS.find((x) => x === s);
    if (p && !out.includes(p)) out.push(p);
  }
  return [...out, ...PROVIDERS.filter((p) => !out.includes(p))];
}

export function defaultWindow(p: ProviderId): string {
  // The 5-hour window is the one that actually blocks work; Cursor's API bucket is often full while the plan is fine.
  return p === "claude" || p === "antigravity" ? "5h" : p === "cursor" ? "total" : HIGHEST;
}

/** The chosen window, or the most used one. */
export function pickWindow(choice: string, limits: ProviderLimits): LimitWindow | null {
  if (choice !== HIGHEST) {
    const w = limits.windows.find((w) => w.id === choice);
    if (w) return w;
  }
  return limits.windows.reduce<LimitWindow | null>((best, w) => (best == null || w.percent > best.percent ? w : best), null);
}

/** The small windows a card lists next to `primary`. A hidden one still shows once it is used up, so the card explains why work stopped. */
export function cardSecondaries(windows: LimitWindow[], primary: LimitWindow, hidden: string[]): LimitWindow[] {
  return windows.filter((w) => w.id !== primary.id && (!hidden.includes(w.id) || remaining(w.percent) <= 0));
}

export function cardWindow(snap: Snapshot, limits: ProviderLimits): LimitWindow | null {
  return pickWindow(snap.settings.cardWindows[limits.provider] ?? defaultWindow(limits.provider), limits);
}

export function customSizeOf(settings: Settings, p: ProviderId): CardSize {
  return settings.cardSizes[p] ?? (p === "claude" ? "l" : "m");
}

export function customSize(snap: Snapshot, p: ProviderId): CardSize {
  return customSizeOf(snap.settings, p);
}

/** The providers that get a full card, in the panel's order. */
export function cardProviders(snap: Snapshot): ProviderId[] {
  return panelProviders(snap).filter((p) => hasCard(snap, p));
}

/** Every provider in the panel's order, hidden and signed out ones included. */
export function orderedProviders(snap: Snapshot): ProviderId[] {
  const manual = order(snap.settings.providerOrder);
  if (snap.settings.panelOrder !== "closestToLimit") return manual;
  return closestToLimit(manual, (p) => {
    const l = limitsOf(snap.limits[p]);
    const w = l && cardWindow(snap, l);
    return w ? 100 - w.percent : null;
  });
}

/** Connected providers shown in the panel, in order. */
export function panelProviders(snap: Snapshot): ProviderId[] {
  return orderedProviders(snap).filter((p) => snap.connected.includes(p) && !snap.settings.panelHidden.includes(p));
}

/** Loading, loaded, or failing with a cached value: those get a card; the rest a compact row. */
export function hasCard(snap: Snapshot, p: ProviderId): boolean {
  const s = snap.limits[p];
  if (!s) return true;
  switch (s.state) {
    case "loading":
    case "loaded":
      return true;
    case "failed":
      return s.last != null;
    case "signedOut":
      return false;
  }
}
