// Mirrors the Rust types the app sends (`burn-app/src/model.rs`, `burn-core/src/model.rs`).

export type ProviderId = "claude" | "codex" | "cursor" | "antigravity";
export const PROVIDERS: ProviderId[] = ["claude", "codex", "cursor", "antigravity"];
export const PROVIDER_NAME: Record<ProviderId, string> = {
  claude: "Claude",
  codex: "Codex",
  cursor: "Cursor",
  antigravity: "Antigravity",
};
export const LOGIN_COMMAND: Record<ProviderId, string> = {
  claude: "claude auth login",
  codex: "codex login",
  cursor: "cursor-agent login",
  antigravity: "agy",
};

export interface LimitWindow {
  id: string;
  label: string;
  /** Used, 0...100 (may exceed 100). */
  percent: number;
  /** Epoch ms. */
  resetsAt: number | null;
  minor: boolean;
}

export interface ProviderLimits {
  provider: ProviderId;
  plan: string | null;
  windows: LimitWindow[];
  fetchedAt: number;
}

export type LimitState =
  | { state: "loading" }
  | { state: "loaded"; limits: ProviderLimits }
  | { state: "signedOut" }
  | { state: "failed"; message: string; last: ProviderLimits | null };

export type Period = "today" | "week" | "month" | "all";
export const PERIODS: Period[] = ["today", "week", "month", "all"];
export const PERIOD_TITLE: Record<Period, string> = { today: "Today", week: "7D", month: "30D", all: "All" };

export type BucketUnit = "hour" | "day" | "week";

export interface UsageBucket {
  start: number;
  cost: Partial<Record<ProviderId, number>>;
}

export interface UsageSummary {
  period: Period;
  cost: number;
  tokens: number;
  byProvider: Partial<Record<ProviderId, number>>;
  buckets: UsageBucket[];
  unit: BucketUnit;
}

export type PanelLayout = "auto" | "grid" | "list" | "custom";
export type PanelOrder = "manual" | "closestToLimit";
export type CardSize = "s" | "m" | "l";
export type CardColor = "coral" | "mono" | "lavender" | "sky";
export type Tab = "usage" | "shelf";

export interface Settings {
  widgetHidden: ProviderId[];
  widgetWindows: Partial<Record<ProviderId, string>>;
  panelHidden: ProviderId[];
  cardSizes: Partial<Record<ProviderId, CardSize>>;
  cardColors: Partial<Record<ProviderId, CardColor>>;
  cardWindows: Partial<Record<ProviderId, string>>;
  providerOrder: ProviderId[];
  panelLayout: PanelLayout;
  panelOrder: PanelOrder;
  showsSpending: boolean;
  tab: Tab;
  shelfExpanded: boolean;
  shelfRetentionDays: number;
  trayOnly: boolean;
}

/** A copied screenshot in the shelf folder; `thumb` is a downscaled PNG that may not exist yet. */
export interface ShelfItem {
  path: string;
  thumb: string;
  /** Epoch ms. */
  date: number;
  width: number;
  height: number;
}

/** A color as CSS: `#RRGGBB`, `#RRGGBBAA`, or `var(--token)` when it follows another token. */
export type ThemePaint = string;

/** What a theme draws on a block over its fill (`docs/themes.md`, "Block backgrounds"). */
export interface ThemeBackground {
  gradient?: { colors: ThemePaint[]; angle: number };
  /** `version` changes when the file does, so the picture reloads. */
  image?: { path: string; opacity: number; version: number };
  pattern?: {
    type: "dots" | "grid" | "lines" | "wave" | "level" | "halftone" | "rain";
    color: ThemePaint;
    /** Wave crests, the level surface, rain heads; absent means `color`. */
    highlight?: ThemePaint;
    opacity: number;
    spacing: number;
    size: number;
    fade: "top" | "bottom" | null;
  };
}

/** The active theme: only what it changes, laid over the defaults in `theme.css`. */
export interface ThemeLook {
  /** Token key to color, for each appearance. */
  light: Record<string, string>;
  dark: Record<string, string>;
  radius: number;
  gap: number;
  pill: number;
  textFont: string | null;
  displayFont: string | null;
  /** By the token of the block's fill. */
  backgrounds: Record<string, ThemeBackground>;
}

/** Up to three colors that tell a theme apart, per appearance. */
export interface ThemeSwatch {
  light: string[];
  dark: string[];
}

export interface ThemeEntry {
  /** File name without `.json`. */
  id: string;
  title: string;
  builtIn: boolean;
  swatch: ThemeSwatch;
}

/** Mirrors `burn-core/src/theme.rs` `ThemeState`. */
export interface ThemeState {
  /** Null is the built-in look. */
  selected: string | null;
  title: string;
  available: ThemeEntry[];
  defaultSwatch: ThemeSwatch;
  /** What's wrong with the selected theme. */
  issues: string[];
  folder: string;
  /** Prompts the user pastes to a coding agent. */
  agentPrompt: string;
  ideasPrompt: string;
  look: ThemeLook;
}

export interface Snapshot {
  connected: ProviderId[];
  limits: Partial<Record<ProviderId, LimitState>>;
  usage: UsageSummary | null;
  usageError: string | null;
  period: Period;
  lastSync: number | null;
  syncing: boolean;
  importPercent: number | null;
  hasUsage: boolean;
  /** Newest first. */
  shelf: ShelfItem[];
  settings: Settings;
  theme: ThemeState;
  /** Whether Windows starts Burn at login. */
  launchAtLogin: boolean;
  version: string;
  /** Version of a newer release, when there is one. */
  update: string | null;
  /** The update is downloading and installing. */
  updating: boolean;
}

export function limitsOf(s: LimitState | undefined): ProviderLimits | null {
  if (!s) return null;
  if (s.state === "loaded") return s.limits;
  if (s.state === "failed") return s.last;
  return null;
}
