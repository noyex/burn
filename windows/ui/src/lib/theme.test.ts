import { describe, expect, it } from "vitest";
import { demoTheme } from "./demo";
import { gradientCss, isLight, patternCss } from "./theme.svelte";

describe("theme", () => {
  it("tells light ink from dark ink like the Mac app", () => {
    expect(isLight("#ffffff")).toBe(true);
    expect(isLight(" #FFF ")).toBe(true);
    expect(isLight("#141414")).toBe(false);
    expect(isLight("#1b1840")).toBe(false);
    expect(isLight("#4DFF88")).toBe(true);
    expect(isLight("#00000080")).toBe(false);
  });

  it("keeps the angle of a gradient as written", () => {
    expect(gradientCss({ colors: ["#7C5CFF", "var(--coral)"], angle: 135 })).toBe("linear-gradient(135deg, #7C5CFF, var(--coral))");
  });

  it("spaces pattern marks by the theme's spacing", () => {
    const base = { color: "#FFFFFF", opacity: 0.25, spacing: 8, size: 2, fade: null };
    expect(patternCss({ ...base, type: "dots" }).size).toBe("8px 8px");
    expect(patternCss({ ...base, type: "grid" }).image).toContain("calc(50% - 1px)");
    // Diagonals are `spacing` apart along the horizontal, so closer together across.
    expect(patternCss({ ...base, type: "lines" }).image).toContain(`${8 / Math.SQRT2}px`);
  });

  it("has every built-in theme in the demo", () => {
    const all = demoTheme(null);
    expect(all.selected).toBeNull();
    expect(all.available.map((t) => t.id)).toEqual(["aurora", "circuit", "ember", "frost", "glow-dots", "obsidian", "prism", "titanium"]);
    for (const t of all.available) {
      const picked = demoTheme(t.id);
      expect(picked.selected).toBe(t.id);
      expect(picked.title).toBe(t.title);
    }
    expect(demoTheme("circuit").look.pill).toBe(6);
    expect(demoTheme("no-such-theme").selected).toBeNull();
  });
});
