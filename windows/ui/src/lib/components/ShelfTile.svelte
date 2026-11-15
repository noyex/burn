<!-- One screenshot (ShelfView.swift `ShelfTile`). Click copies it, the corner circle or Ctrl+click selects. -->
<script lang="ts">
  import { fileUrl, isTauri } from "../api";
  import type { ShelfItem } from "../types";
  import Icons from "./Icons.svelte";

  let {
    item,
    width,
    height,
    selected,
    selecting,
    onToggle,
    onCopy,
  }: {
    item: ShelfItem;
    width: number;
    height: number;
    selected: boolean;
    /** Anything is selected, so every tile shows its check. */
    selecting: boolean;
    onToggle: () => void;
    /** Resolves whether the copy worked. */
    onCopy: () => Promise<boolean>;
  } = $props();

  // The thumbnail may not exist yet: fall back to the full image, then to the placeholder.
  let source = $state<"thumb" | "full" | "none">("thumb");
  let loaded = $state(false);
  let copied = $state(false);
  let timer: ReturnType<typeof setTimeout> | undefined;

  const src = $derived(!isTauri || source === "none" ? null : fileUrl(source === "thumb" ? item.thumb : item.path));
  const label = $derived(`Screenshot from ${new Date(item.date).toLocaleString([], { dateStyle: "medium", timeStyle: "short" })}, ${item.width} by ${item.height}`);

  function failed() {
    loaded = false;
    source = source === "thumb" ? "full" : "none";
  }

  async function copy() {
    if (!(await onCopy())) return;
    copied = true;
    clearTimeout(timer);
    timer = setTimeout(() => (copied = false), 1100);
  }

  /** Corner circle, with a hit area bigger than the circle. */
  const CHECK_HIT = 30;

  function click(e: MouseEvent) {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const inCorner = e.detail > 0 && e.clientX >= r.right - CHECK_HIT && e.clientY <= r.top + CHECK_HIT;
    // As on the Mac: a plain click always copies; the corner circle or Ctrl+click selects.
    if (inCorner || e.ctrlKey || e.metaKey) onToggle();
    else copy();
  }

  function key(e: KeyboardEvent) {
    if (e.key === " ") {
      e.preventDefault();
      onToggle();
    } else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "c") {
      e.preventDefault();
      copy();
    }
  }
</script>

<button
  class="tile"
  class:selected
  style:width="{width}px"
  style:height="{height}px"
  aria-label={label}
  aria-pressed={selected}
  onclick={click}
  onkeydown={key}
>
  {#if src}
    {#key src}
      <img class:loaded {src} alt="" draggable="false" onload={() => (loaded = true)} onerror={failed} />
    {/key}
  {/if}
  <span class="check" class:shown={selected || selecting} class:on={selected}><Icons name="check" size={9} /></span>
  <span class="copied" class:shown={copied}><Icons name="check" size={10} />Copied</span>
</button>

<style>
  .tile {
    position: relative;
    display: block;
    overflow: hidden;
    border-radius: var(--radius);
    background: var(--neutral);
    box-shadow:
      0 4px 20px var(--shadow),
      inset 0 0 0 0.5px var(--hairline);
    transition: transform 180ms var(--ease-out);
  }
  .tile:hover:not(.selected) {
    transform: scale(1.02);
  }
  .tile:active {
    transform: scale(0.98);
  }
  img {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
    opacity: 0;
    transition: opacity 200ms ease-out;
    pointer-events: none;
  }
  img.loaded {
    opacity: 1;
  }
  /* Selection ring drawn over the image. */
  .tile::after {
    content: "";
    position: absolute;
    inset: 0;
    border-radius: inherit;
    box-shadow: inset 0 0 0 0.5px var(--photo-edge);
    transition: box-shadow 150ms ease-out;
    pointer-events: none;
  }
  .tile.selected::after {
    box-shadow: inset 0 0 0 3px var(--selection);
  }
  .check {
    position: absolute;
    top: 6px;
    right: 6px;
    display: grid;
    place-items: center;
    width: 18px;
    height: 18px;
    border-radius: 50%;
    background: var(--photo-scrim);
    box-shadow:
      inset 0 0 0 1.5px color-mix(in srgb, var(--on-photo) 90%, transparent),
      0 1px 3px var(--photo-shadow);
    color: transparent;
    opacity: 0;
    transform: scale(0.8);
    transition:
      opacity 150ms ease-out,
      transform 180ms var(--ease-out);
    pointer-events: none;
    z-index: 1;
  }
  .tile:hover .check,
  .tile:focus-visible .check,
  .check.shown {
    opacity: 1;
    transform: none;
  }
  .check.on {
    background: var(--text);
    box-shadow: 0 1px 3px var(--photo-shadow);
    color: var(--base);
  }
  .copied {
    position: absolute;
    left: 50%;
    top: 50%;
    display: flex;
    align-items: center;
    gap: 5px;
    height: 24px;
    padding: 0 10px;
    margin: -12px 0 0;
    border-radius: var(--pill);
    background: var(--surface);
    color: var(--text);
    font-size: 11px;
    font-weight: 700;
    box-shadow: 0 2px 8px var(--shadow);
    opacity: 0;
    transform: translateX(-50%) scale(0.8);
    transition:
      opacity 200ms ease-out,
      transform 200ms var(--ease-out);
    pointer-events: none;
    z-index: 1;
  }
  .copied.shown {
    opacity: 1;
    transform: translateX(-50%);
  }
</style>
