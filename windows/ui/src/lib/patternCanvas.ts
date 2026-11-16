/**
 * The animated theme patterns (`wave`, `level`, `halftone`, `rain`), drawn on a canvas. One shared
 * requestAnimationFrame loop serves every canvas at about 30 fps; it stops when the document is
 * hidden or no canvas is mounted, and under `prefers-reduced-motion` each canvas is drawn once.
 */
import type { ThemeBackground } from "./types";

type Pattern = NonNullable<ThemeBackground["pattern"]>;

const ANIMATED_KINDS = ["wave", "level", "halftone", "rain"];

export function isAnimatedPattern(p: Pattern | undefined): boolean {
  return !!p && ANIMATED_KINDS.includes(p.type);
}

export interface PatternParams {
  pattern: Pattern;
  /** Fraction 0..1 the `level` pattern fills up to. */
  level: number;
  /** The block's token (`accent`, `coral`, ...): blocks sharing one move in lockstep, like on the Mac. */
  slot: string;
}

interface Scene {
  /** Resolved CSS colors. */
  dot: string;
  accent: string;
  spacing: number;
  size: number;
  level: number;
  /** Offsets the animation per block token, like `PatternSeed.of` on the Mac. */
  seed: number;
}

const TAU = Math.PI * 2;
const FRAME_MS = 1000 / 30;
/** Time used for the still frame (Reduce Motion), the same as on the Mac. */
const STILL_T = 6;
const fract = (v: number) => v - Math.floor(v);
const hash = (n: number) => fract(Math.sin(n * 127.1) * 43758.5453);
const smooth = (a: number, b: number, v: number) => {
  const u = Math.max(0, Math.min(1, (v - a) / (b - a)));
  return u * u * (3 - 2 * u);
};

/** A stable, distinct offset per block token (`PatternSeed.of` on the Mac). */
export function patternSeed(slot: string): number {
  let h = 0;
  for (const ch of slot) h = (h * 31 + (ch.codePointAt(0) ?? 0)) % 997;
  return h * 0.37;
}

/** `start`, `start + step`, ... below `limit`; computed by multiplication like Swift's `stride`. */
function* span(start: number, limit: number, step: number) {
  for (let i = 0, v = start; v < limit; v = start + ++i * step) yield v;
}

function circles(x: CanvasRenderingContext2D, points: number[], r: number) {
  for (let i = 0; i < points.length; i += 2) {
    x.moveTo(points[i] + r, points[i + 1]);
    x.arc(points[i], points[i + 1], r, 0, TAU);
  }
}

function dots(x: CanvasRenderingContext2D, points: number[], r: number) {
  x.beginPath();
  circles(x, points, r);
  x.fill();
}

/** Dots collected into one path per alpha step, so a frame costs a handful of fills. */
class DotBuckets {
  private readonly points: number[][];
  private readonly radii: number[][];
  constructor(private readonly steps = 16) {
    this.points = Array.from({ length: steps }, () => []);
    this.radii = Array.from({ length: steps }, () => []);
  }
  /** `alpha` in 0..1 is rounded up to the nearest step. */
  dot(px: number, py: number, radius: number, alpha: number) {
    if (!(alpha > 0.01) || !(radius > 0)) return;
    const step = Math.min(this.steps - 1, Math.max(0, Math.ceil(alpha * this.steps) - 1));
    this.points[step].push(px, py);
    this.radii[step].push(radius);
  }
  fill(x: CanvasRenderingContext2D, color: string) {
    x.fillStyle = color;
    for (let i = 0; i < this.steps; i++) {
      const pts = this.points[i];
      if (pts.length === 0) continue;
      x.globalAlpha = (i + 1) / this.steps;
      x.beginPath();
      for (let j = 0; j < pts.length; j += 2) {
        const r = this.radii[i][j / 2];
        x.moveTo(pts[j] + r, pts[j + 1]);
        x.arc(pts[j], pts[j + 1], r, 0, TAU);
      }
      x.fill();
    }
  }
}

type Painter = (x: CanvasRenderingContext2D, W: number, H: number, t: number, s: Scene) => void;

/** Rows of dots in perspective over the lower part, rolling like a sea; crests in the highlight. */
const drawWave: Painter = (x, W, H, t, s) => {
  const rows = 14;
  const top = 0.42;
  const crests = new DotBuckets(4);
  for (let r = 0; r < rows; r++) {
    const p = r / (rows - 1);
    const y0 = H * top + p * p * H * (1 - top) * 1.02;
    // 0.6x at the back, 1x in the middle, 1.6x at the front.
    const spread = p < 0.5 ? 0.6 + 0.8 * p : 1 + 1.2 * (p - 0.5);
    const sp = s.spacing * spread;
    const rad = (s.size / 2) * (0.4 + 1.2 * p);
    const amp = 2 + p * 10;
    const n = Math.ceil(W / sp / 2) + 1;
    const ink: number[] = [];
    for (let c = -n; c <= n; c++) {
      const h = Math.sin(c * 0.33 + t * 1.05 + r * 0.42 + s.seed) * Math.cos(r * 0.28 - t * 0.55 + c * 0.05);
      const px = W / 2 + c * sp;
      const py = y0 - h * amp;
      ink.push(px, py);
      if (p > 0.2 && p < 0.85 && h > 0.7) {
        const glow = smooth(0.7, 0.95, h);
        crests.dot(px, py, rad + glow * s.size * 0.33, glow);
      }
    }
    x.globalAlpha = 0.06 + p * 0.75;
    x.fillStyle = s.dot;
    dots(x, ink, rad);
  }
  crests.fill(x, s.accent);
};

/** Dots filling the block up to `level`, under a surface that gently moves. */
const drawLevel: Painter = (x, W, H, t, s) => {
  const lvl = H * (1 - Math.max(0, Math.min(1, s.level)) * 0.92);
  const sp = s.spacing;
  const surface = (px: number) => lvl + Math.sin(px * 0.045 + t * 1.6 + s.seed) * 2.2 + Math.sin(px * 0.02 - t * 0.9) * 1.6;
  x.fillStyle = s.dot;
  x.globalAlpha = 0.1;
  x.beginPath();
  x.moveTo(0, H);
  for (let px = 0; px <= W; px += 4) x.lineTo(px, surface(px));
  x.lineTo(W, H);
  x.fill();
  const below = new DotBuckets();
  const top: number[] = [];
  for (const px of span(sp / 2, W, sp)) {
    const sy = surface(px);
    top.push(px, sy);
    for (const py of span(sy + sp, H, sp)) {
      below.dot(px, py, s.size / 2, (0.22 * (1 - (py - sy) / (H - lvl + 20))) / 0.95);
    }
  }
  below.fill(x, s.dot);
  x.fillStyle = s.accent;
  x.globalAlpha = 0.95;
  dots(x, top, s.size * 0.7);
};

/** A dot grid whose dots swell and shrink in slowly drifting patches. */
const drawHalftone: Painter = (x, W, H, t, s) => {
  const sp = s.spacing;
  const dotsAt = new DotBuckets();
  for (const px of span(sp / 2, W, sp)) {
    for (const py of span(sp / 2, H, sp)) {
      const n = (Math.sin(px * 0.04 + t * 0.7 + s.seed) + Math.sin(py * 0.06 - t * 0.5) + Math.sin((px + py) * 0.025 + t * 0.35)) / 3;
      const v = Math.max(0, n * 0.5 + 0.5);
      dotsAt.dot(px, py, (s.size / 2) * (0.115 + 0.885 * v * v), ((0.15 + v * 0.6) * py) / H / 0.75);
    }
  }
  dotsAt.fill(x, s.dot);
};

/** Drops of dots falling down columns with a fading trail; the head in the highlight. */
const drawRain: Painter = (x, W, H, t, s) => {
  const sp = s.spacing;
  const r = s.size / 2;
  const trail = new DotBuckets();
  const heads: number[] = [];
  let col = 0;
  for (const px of span(sp / 2, W, sp)) {
    const seed = s.seed + col;
    col += 1;
    const speed = 0.18 + hash(seed) * 0.3;
    const head = fract(t * speed + hash(seed + 1)) * (H + 60) - 20;
    const len = 6 + Math.floor(hash(seed + 2) * 8);
    for (const py of span(sp / 2, H, sp)) {
      const d = (head - py) / sp;
      if (d >= 0 && d < 1) heads.push(px, py);
      else trail.dot(px, py, r, d > 0 && d < len ? Math.max(0.05, (1 - d / len) * 0.85) : 0.05);
    }
  }
  trail.fill(x, s.dot);
  x.fillStyle = s.accent;
  x.globalAlpha = 0.9;
  dots(x, heads, r * 1.75);
};

const PAINTERS: Record<string, Painter> = { wave: drawWave, level: drawLevel, halftone: drawHalftone, rain: drawRain };

interface Entry {
  canvas: HTMLCanvasElement;
  params: PatternParams;
  seed: number;
  width: number;
  height: number;
  dot: string;
  accent: string;
  resolvedAt: number;
}

const entries = new Set<Entry>();
let frame = 0;
let t = STILL_T;
let lastTick = 0;
let lastDraw = 0;
let listening = false;
/**
 * False while the panel is hidden: the webview may stay "visible" for minutes after it closes.
 * In the app the panel starts hidden; a plain browser (demo, screenshots) has no panel events.
 */
let active = !(typeof window !== "undefined" && "__TAURI_INTERNALS__" in window);

const motionQuery = typeof matchMedia === "function" ? matchMedia("(prefers-reduced-motion: reduce)") : null;
const reducedMotion = () => !!motionQuery?.matches;

/** A CSS color (maybe `var(--token)`) as the browser computes it for this canvas. */
function resolve(canvas: HTMLCanvasElement, paint: string): string {
  canvas.style.color = paint;
  return getComputedStyle(canvas).color;
}

function draw(e: Entry, now: number) {
  const { pattern } = e.params;
  const x = e.canvas.getContext("2d");
  const paint = PAINTERS[pattern.type];
  if (!x || !paint || e.width === 0 || e.height === 0) return;
  // Tokens follow light/dark, so colors are looked up again about twice a second.
  if (!e.dot || now - e.resolvedAt > 500) {
    e.dot = resolve(e.canvas, pattern.color);
    e.accent = resolve(e.canvas, pattern.highlight ?? pattern.color);
    e.resolvedAt = now;
  }
  x.setTransform(e.canvas.width / e.width, 0, 0, e.canvas.height / e.height, 0, 0);
  x.clearRect(0, 0, e.width, e.height);
  paint(x, e.width, e.height, t, {
    dot: e.dot,
    accent: e.accent,
    spacing: pattern.spacing,
    size: pattern.size,
    level: e.params.level,
    seed: e.seed,
  });
  x.globalAlpha = 1;
}

function drawAll(now: number) {
  for (const e of entries) draw(e, now);
}

const running = () => active && !document.hidden;

function loop(now: number) {
  frame = 0;
  if (entries.size === 0 || !running() || reducedMotion()) return;
  frame = requestAnimationFrame(loop);
  if (now - lastDraw < FRAME_MS - 1) return;
  t += Math.min(now - (lastTick || now), 100) / 1000;
  lastTick = now;
  lastDraw = now;
  drawAll(now);
}

function sync() {
  if (reducedMotion()) {
    t = STILL_T;
    drawAll(performance.now());
    return;
  }
  if (!frame && entries.size > 0 && running()) {
    lastTick = 0;
    frame = requestAnimationFrame(loop);
  }
}

function listen() {
  if (listening) return;
  listening = true;
  document.addEventListener("visibilitychange", () => {
    if (!running() && frame) {
      cancelAnimationFrame(frame);
      frame = 0;
    } else sync();
  });
  if (typeof matchMedia === "function") {
    motionQuery?.addEventListener("change", sync);
    // Token colors follow light/dark: look them up again and, when still, redraw right away.
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
      for (const e of entries) e.resolvedAt = 0;
      if (reducedMotion()) drawAll(performance.now());
    });
  }
}

/** Pauses every pattern while the panel is hidden and resumes it when it is shown again. */
export function setPatternsActive(on: boolean) {
  active = on;
  if (!on && frame) {
    cancelAnimationFrame(frame);
    frame = 0;
  } else if (on) sync();
}

/** Svelte action: draws the animated pattern on `canvas` and keeps it up to date. */
export function animatedPattern(canvas: HTMLCanvasElement, params: PatternParams) {
  listen();
  const entry: Entry = { canvas, params, seed: patternSeed(params.slot), width: 0, height: 0, dot: "", accent: "", resolvedAt: 0 };
  const resize = () => {
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    entry.width = canvas.clientWidth;
    entry.height = canvas.clientHeight;
    canvas.width = Math.round(entry.width * dpr);
    canvas.height = Math.round(entry.height * dpr);
    draw(entry, performance.now());
  };
  const observer = typeof ResizeObserver === "function" ? new ResizeObserver(resize) : null;
  observer?.observe(canvas);
  entries.add(entry);
  resize();
  sync();
  return {
    update(next: PatternParams) {
      entry.params = next;
      entry.seed = patternSeed(next.slot);
      entry.resolvedAt = 0;
      if (reducedMotion()) draw(entry, performance.now());
    },
    destroy() {
      observer?.disconnect();
      entries.delete(entry);
      if (entries.size === 0 && frame) {
        cancelAnimationFrame(frame);
        frame = 0;
      }
    },
  };
}
