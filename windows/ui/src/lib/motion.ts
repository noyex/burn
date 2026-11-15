// Page and card motion helpers shared by the panel.

import { fade } from "svelte/transition";
import { cubicOut } from "svelte/easing";

export const reducedMotion = () => typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

/** The new page settles in (Mac `tabTransition` insertion). */
export function pageIn(node: HTMLElement) {
  const reduced = reducedMotion();
  return {
    duration: reduced ? 0 : 220,
    easing: cubicOut,
    css: (t: number) => `opacity: ${t}; transform: ${reduced ? "none" : `scale(${0.98 + 0.02 * t})`}; transform-origin: top center`,
  };
}

/** The old page fades out quickly and drops out of the layout, so the window only sizes to the new one. */
export function pageOut(node: HTMLElement) {
  node.style.position = "absolute";
  node.style.top = "0";
  node.style.left = "0";
  node.style.right = "0";
  node.style.pointerEvents = "none";
  return fade(node, { duration: reducedMotion() ? 0 : 120 });
}

/** The panel preview slides in from under the theme page. */
export function previewIn(node: HTMLElement) {
  const reduced = reducedMotion();
  return {
    duration: reduced ? 0 : 220,
    easing: cubicOut,
    css: (t: number) => `opacity: ${t}; transform: ${reduced ? "none" : `translateX(${(t - 1) * 12}px)`}`,
  };
}
