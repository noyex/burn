// Talks to the Rust side. In a plain browser (`npm run dev` without Tauri) it serves demo data
// instead, so the UI can be built and screenshotted anywhere: `?demo=loading|signedOut|empty|emptyShelf`,
// `?theme=terminal` for a built-in theme.

import { convertFileSrc, invoke } from "@tauri-apps/api/core";
import type { Period, Settings, Snapshot } from "./types";
import { demoSnapshot } from "./demo";

const inTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

type Listener = (s: Snapshot) => void;

export async function getState(): Promise<Snapshot> {
  if (!inTauri) {
    const params = new URLSearchParams(location.search);
    return demoSnapshot(params.get("demo"), undefined, params.get("theme"));
  }
  return invoke<Snapshot>("get_state");
}

export async function onState(f: Listener): Promise<void> {
  if (!inTauri) return;
  const { listen } = await import("@tauri-apps/api/event");
  await listen<Snapshot>("state", (e) => f(e.payload));
}

/** `shown` runs every time the panel opens, `hidden` when it closes. */
export async function onPanel(shown: () => void, hidden: () => void): Promise<void> {
  if (!inTauri) {
    shown();
    return;
  }
  const { listen } = await import("@tauri-apps/api/event");
  await listen("panel-shown", shown);
  await listen("panel-hidden", hidden);
  // The panel may have opened before the page was listening.
  if (await invoke<boolean>("panel_visible")) shown();
}

async function call(cmd: string, args?: Record<string, unknown>): Promise<void> {
  if (!inTauri) return;
  await invoke(cmd, args);
}

async function ask<T>(cmd: string, args: Record<string, unknown> | undefined, fallback: T): Promise<T> {
  if (!inTauri) return fallback;
  return invoke<T>(cmd, args);
}

export const setPeriod = (period: Period) => call("set_period", { period });
export const hidePanel = () => call("hide_panel");
export const contentResized = (width: number, height: number) => call("content_resized", { width, height });
export const setSettings = (settings: Settings) => call("set_settings", { settings });
export const setLaunchAtLogin = (on: boolean) => call("set_launch_at_login", { on });
/** Turns a theme on by its file name; null is the built-in look. */
export const setTheme = (name: string | null) => call("set_theme", { name });
export const openThemesFolder = () => call("open_themes_folder");
export const quit = () => call("quit");
export const installUpdate = () => call("install_update");
export const isTauri = inTauri;
/** One path goes on the clipboard as image and file, several as files. Resolves whether it worked. */
export const shelfCopy = (paths: string[]) => ask<boolean>("shelf_copy", { paths }, true);
/** Deletes the given screenshots, or all of them without `paths`. */
export const shelfDelete = (paths?: string[]) => call("shelf_delete", paths ? { paths } : undefined);
/** Copies an image of the current period's spend. Resolves whether it worked. */
/** Copies an image of `period`'s spend (the one on screen, even before its numbers arrive). */
export const shareCopy = (period: Period) => ask<boolean>("share_copy", { period }, true);
/** URL the webview can load a local file from (the shelf folder is allowed by the asset protocol). */
export const fileUrl = (path: string) => convertFileSrc(path);
