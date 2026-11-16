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
}

interface Scene {
  /** Resolved CSS colors. */
  dot: string;
  accent: string;
  spacing: number;
  size: number;
  level: number;
  phase: number;
}

const TAU = Math.PI * 2;
const FRAME_MS = 1000 / 30;
/** Time used for the still frame under reduced motion. */
const STILL_T = 2;
const fract = (v: number) => v - Math.floor(v);
const hash = (n: number) => fract(Math.sin(n * 127.1) * 43758.5453);
const smooth = (a: number, b: number, v: number) => {
  const u = Math.max(0, Math.min(1, (v - a) / (b - a)));
  return u * u * (3 - 2 * u);
};

function dots(x: CanvasRenderingContext2D, points: number[], r: number) {
  x.beginPath();
  for (let i = 0; i < points.length; i += 2) {
    x.moveTo(points[i] + r, points[i + 1]);
    x.arc(points[i], points[i + 1], r, 0, TAU);
  }
  x.fill();
}

type Painter = (x: CanvasRenderingContext2D, W: number, H: number, t: number, s: Scene) => void;

const drawWave: Painter = (x, W, H, t, s) => {
  const rows = 14;
  const top = 0.42;
  const scale = s.spacing / 9.5;
  for (let r = 0; r < rows; r++) {
    const p = r / (rows - 1);
    const y0 = H * top + p * p * H * (1 - top) * 1.02;
    const sp = s.spacing * (0.6 + p);
    const rad = (s.size / 2) * (0.4 + p * 1.2);
    const amp = (2 + p * 10) * scale;
    const n = Math.ceil(W / sp / 2) + 1;
    const ink: number[] = [];
    const crests: number[] = [];
    for (let c = -n; c <= n; c++) {
      const h = Math.sin(c * 0.33 + t * 1.05 + r * 0.42 + s.phase) * Math.cos(r * 0.28 - t * 0.55 + c * 0.05);
      const px = W / 2 + c * sp;
      const py = y0 - h * amp;
      ink.push(px, py);
      if (p > 0.2 && p < 0.85 && h > 0.7) crests.push(px, py, smooth(0.7, 0.95, h));
    }
    x.globalAlpha = 0.08 + p * 0.92;
    x.fillStyle = s.dot;
    dots(x, ink, rad);
    x.fillStyle = s.accent;
    for (let j = 0; j < crests.length; j += 3) {
      x.globalAlpha = crests[j + 2];
      dots(x, [crests[j], crests[j + 1]], rad + (s.size / 2) * crests[j + 2]);
    }
  }
};

const drawLevel: Painter = (x, W, H, t, s) => {
  const lvl = H * (1 - Math.max(0, Math.min(1, s.level)) * 0.92);
  const sp = s.spacing;
  const surface = (px: number) => lvl + Math.sin(px * 0.045 + t * 1.6 + s.phase) * 2.2 + Math.sin(px * 0.02 - t * 0.9) * 1.6;
  x.fillStyle = s.accent;
  x.globalAlpha = 0.1;
  x.beginPath();
  x.moveTo(0, H);
  for (let px = 0; px <= W; px += 4) x.lineTo(px, surface(px));
  x.lineTo(W, H);
  x.fill();
  for (let px = sp / 2; px < W; px += sp) {
    const sy = surface(px);
    x.fillStyle = s.accent;
    x.globalAlpha = 0.95;
    dots(x, [px, sy], s.size / 2);
    x.fillStyle = s.dot;
    for (let py = sy + sp; py < H; py += sp) {
      x.globalAlpha = 0.22 * (1 - (py - sy) / (H - lvl + 20));
      dots(x, [px, py], (s.size / 2) * 0.75);
    }
  }
};

const drawHalftone: Painter = (x, W, H, t, s) => {
  const sp = s.spacing;
  const max = s.size / 2;
  x.fillStyle = s.dot;
  for (let px = sp / 2; px < W; px += sp) {
    for (let py = sp / 2; py < H; py += sp) {
      const n = (Math.sin(px * 0.04 + t * 0.7 + s.phase) + Math.sin(py * 0.06 - t * 0.5) + Math.sin((px + py) * 0.025 + t * 0.35)) / 3;
      const v = Math.max(0, n * 0.5 + 0.5);
      x.globalAlpha = (0.15 + v * 0.6) * (py / H);
      dots(x, [px, py], max * (0.12 + v * v * 0.88));
    }
  }
};

const drawRain: Painter = (x, W, H, t, s) => {
  const sp = s.spacing;
  const r = s.size / 2;
  for (let c = 0, px = sp / 2; px < W; px += sp, c++) {
    const seed = s.phase * 4 + c;
    const speed = 0.18 + hash(seed) * 0.3;
    const head = fract(t * speed + hash(seed + 1)) * (H + 60) - 20;
    const len = 6 + Math.floor(hash(seed + 2) * 8);
    for (let py = sp / 2; py < H; py += sp) {
      const d = (head - py) / sp;
      let a = 0.05;
      if (d >= 0 && d < len) a = Math.max(a, (1 - d / len) * 0.85);
      const isHead = d >= 0 && d < 1;
      x.fillStyle = isHead ? s.accent : s.dot;
      x.globalAlpha = isHead ? Math.max(a, 0.9) : a;
      dots(x, [px, py], isHead ? r * 1.75 : r);
    }
  }
};

const PAINTERS: Record<string, Painter> = { wave: drawWave, level: drawLevel, halftone: drawHalftone, rain: drawRain };

interface Entry {
  canvas: HTMLCanvasElement;
  params: PatternParams;
  phase: number;
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
let nextPhase = 0;
let listening = false;
/** False while the panel is hidden: the webview may stay "visible" for minutes after it closes. */
let active = true;

const reducedMotion = () => typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

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
    phase: e.phase,
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
    matchMedia("(prefers-reduced-motion: reduce)").addEventListener("change", sync);
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
  // Every block gets its own phase so they don't move in lockstep.
  const entry: Entry = { canvas, params, phase: nextPhase, width: 0, height: 0, dot: "", accent: "", resolvedAt: 0 };
  nextPhase += 1.7;
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
