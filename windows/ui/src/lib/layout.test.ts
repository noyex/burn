import { describe, expect, it } from "vitest";
import { cardSecondaries, closestToLimit, merge, order, rows, sizes } from "./layout";
import type { CardSize, ProviderId } from "./types";

const all: ProviderId[] = ["claude", "codex", "cursor"];
const custom = (p: ProviderId): CardSize => (p === "claude" ? "l" : "m");
const obj = (m: Map<ProviderId, CardSize>) => Object.fromEntries(m);

// Same cases as Tests/BurnTests/PanelLayoutTests.swift.
describe("panel layout", () => {
  it("auto sizes by count", () => {
    expect(obj(sizes("auto", ["codex"], custom))).toEqual({ codex: "l" });
    expect(obj(sizes("auto", ["codex", "cursor"], custom))).toEqual({ codex: "m", cursor: "m" });
    expect(obj(sizes("auto", all, custom))).toEqual({ claude: "l", codex: "s", cursor: "s" });
  });

  it("fixed layouts", () => {
    expect([...sizes("grid", all, custom).values()].every((s) => s === "m")).toBe(true);
    expect([...sizes("list", all, custom).values()].every((s) => s === "s")).toBe(true);
    expect(obj(sizes("custom", all, custom))).toEqual({ claude: "l", codex: "m", cursor: "m" });
  });

  it("medium cards pair up", () => {
    expect(rows(all, new Map([["claude", "l"], ["codex", "m"], ["cursor", "m"]]))).toEqual([["claude"], ["codex", "cursor"]]);
    expect(rows(all, new Map([["claude", "m"], ["codex", "s"], ["cursor", "m"]]))).toEqual([["claude"], ["codex"], ["cursor"]]);
  });

  it("closest to limit sorts by remaining", () => {
    const remaining: Partial<Record<ProviderId, number>> = { claude: 40, codex: 80, cursor: 40 };
    expect(closestToLimit(all, (p) => remaining[p] ?? null)).toEqual(["claude", "cursor", "codex"]);
    expect(closestToLimit(all, (p) => (p === "cursor" ? 10 : null))).toEqual(["cursor", "claude", "codex"]);
  });

  it("merge keeps hidden in place", () => {
    expect(merge(["cursor", "claude"], all)).toEqual(["cursor", "codex", "claude"]);
    expect(merge(["codex", "claude", "cursor"], all)).toEqual(["codex", "claude", "cursor"]);
  });

  it("saved order is repaired", () => {
    expect(order(["cursor", "nope", "cursor"])).toEqual(["cursor", "claude", "codex", "antigravity"]);
  });
});

describe("cardSecondaries", () => {
  const w = (id: string, percent: number) => ({ id, label: id, percent, resetsAt: null, minor: false });
  const primary = w("5h", 20);
  const windows = [primary, w("week", 99.6), w("3p-5h", 0), w("argon", 0)];

  it("leaves out hidden windows unless they are used up", () => {
    expect(cardSecondaries(windows, primary, ["week", "3p-5h"]).map((x) => x.id)).toEqual(["week", "argon"]);
    expect(cardSecondaries(windows, primary, [])).toHaveLength(3);
  });
});
