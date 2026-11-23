// Demo data for working on the UI outside the app (same values as docs/screenshot.png).

import type { Period, ProviderId, Settings, ShelfItem, Snapshot, ThemeState, UsageBucket, UsageSummary } from "./types";
import fixture from "./demo-themes.json";

const h = 3_600_000;
const d = 24 * h;

const settings: Settings = {
  widgetHidden: [],
  widgetWindows: {},
  panelHidden: [],
  cardSizes: {},
  cardColors: {},
  cardWindows: {},
  hiddenCardWindows: {},
  providerOrder: ["claude", "codex", "cursor", "antigravity"],
  panelLayout: "custom",
  panelOrder: "manual",
  showsSpending: true,
  tab: "usage",
  shelfExpanded: false,
  shelfRetentionDays: 7,
  trayOnly: false,
};

/** The themes that ship with Burn as the app would report them (kept current by `burn-core/tests/demo_themes.rs`). */
const themes = fixture as unknown as { state: ThemeState; looks: Record<string, ThemeState["look"]> };

/** The demo state with `id` turned on; null or an unknown name is the built-in look. */
export function demoTheme(id: string | null): ThemeState {
  const entry = themes.state.available.find((t) => t.id === id);
  if (!entry) return themes.state;
  return { ...themes.state, selected: entry.id, title: entry.title, look: themes.looks[entry.id] };
}

const SHAPES: [number, number][] = [[1920, 1080], [1280, 720], [2560, 1440], [800, 600], [1920, 1080], [1600, 900], [1366, 768], [1920, 1200], [1024, 768]];
const shelf: ShelfItem[] = SHAPES.map(([width, height], i) => ({
  path: `C:\\Users\\you\\Pictures\\Burn\\Screenshot ${i + 1}.png`,
  thumb: `C:\\Users\\you\\Pictures\\Burn\\.thumbs\\${i + 1}.png`,
  date: Date.now() - i * 37 * 60_000,
  width,
  height,
}));

function usage(period: Period): UsageSummary {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const daily = [210, 48, 96, 41, 52, 312, 196];
  let buckets: UsageBucket[];
  let unit: UsageSummary["unit"] = "day";
  if (period === "today") {
    unit = "hour";
    buckets = Array.from({ length: 24 }, (_, i) => ({
      start: today + i * h,
      cost: i <= now.getHours() && i > 8 ? { claude: 2 + ((i * 7) % 5) * 1.6, codex: i % 4 === 0 ? 0.4 : 0 } : {},
    }));
  } else if (period === "all") {
    unit = "week";
    buckets = Array.from({ length: 8 }, (_, i) => ({ start: today - (7 - i) * 7 * d, cost: { claude: 180 + i * 90, codex: i * 2 } }));
  } else {
    const n = period === "week" ? 7 : 30;
    buckets = Array.from({ length: n }, (_, i) => ({ start: today - (n - 1 - i) * d, cost: { claude: daily[i % 7] * 0.5, codex: i % 5 === 0 ? 0.04 : 0 } }));
  }
  const byProvider: Partial<Record<ProviderId, number>> = {};
  for (const b of buckets) for (const [p, c] of Object.entries(b.cost)) byProvider[p as ProviderId] = (byProvider[p as ProviderId] ?? 0) + (c ?? 0);
  const cost = Object.values(byProvider).reduce((a, b) => a + (b ?? 0), 0);
  return { period, cost, tokens: Math.round(cost * 2_200_000), byProvider, buckets, unit };
}

export function demoSnapshot(kind: string | null, period: Period = "week", theme: string | null = null): Snapshot {
  const now = Date.now();
  const base: Snapshot = {
    connected: ["claude", "codex", "cursor"],
    limits: {
      claude: {
        state: "loaded",
        limits: {
          provider: "claude",
          plan: "Max 5x",
          fetchedAt: now,
          windows: [
            { id: "5h", label: "5h", percent: 49, resetsAt: now + 4 * h + 15 * 60_000, minor: false },
            { id: "week", label: "Week", percent: 81, resetsAt: now + 5 * h + 15 * 60_000, minor: false },
            { id: "week_fable", label: "Fable", percent: 34, resetsAt: now + 3 * d, minor: true },
          ],
        },
      },
      codex: {
        state: "loaded",
        limits: { provider: "codex", plan: "Free", fetchedAt: now, windows: [{ id: "month", label: "Month", percent: 12, resetsAt: now + 3 * d + 2 * h, minor: false }] },
      },
      cursor: {
        state: "loaded",
        limits: {
          provider: "cursor",
          plan: "Pro",
          fetchedAt: now,
          windows: [
            { id: "total", label: "Month", percent: 0, resetsAt: now + 11 * d, minor: false },
            { id: "api", label: "API", percent: 0, resetsAt: now + 11 * d, minor: false },
          ],
        },
      },
    },
    usage: usage(period),
    usageError: null,
    period,
    lastSync: now - 20_000,
    syncing: false,
    importPercent: null,
    hasUsage: true,
    shelf,
    settings,
    theme: demoTheme(theme),
    launchAtLogin: true,
    update: null,
    updating: false,
    version: "0.1.0",
  };
  switch (kind) {
    case "loading":
      return { ...base, limits: { claude: { state: "loading" }, codex: { state: "loading" }, cursor: { state: "loading" } }, usage: null };
    case "signedOut":
      return { ...base, limits: { ...base.limits, codex: { state: "signedOut" }, cursor: { state: "failed", message: "No connection", last: null } } };
    case "empty":
      return { ...base, connected: [], limits: {}, usage: null, hasUsage: false };
    case "emptyShelf":
      return { ...base, shelf: [] };
    case "importing":
      return { ...base, usage: null, hasUsage: false, syncing: true, importPercent: 42 };
    default:
      return base;
  }
}

export { usage as demoUsage };
