<!-- While arranging: the card wiggles and gets a hide button and, for provider cards, S/M/L chips
     (PanelEditing.swift `EditChrome` and `Wiggle`). -->
<script lang="ts">
  import type { Snippet } from "svelte";
  import { tip } from "../tip.svelte";
  import type { CardSize } from "../types";
  import Icons from "./Icons.svelte";
  import Segmented from "./Segmented.svelte";

  let {
    editing,
    title,
    seed = 0,
    amplitude = 0.35,
    size,
    onSize,
    onHide,
    children,
  }: {
    editing: boolean;
    title: string;
    /** Different phases, so the cards don't rock in lockstep. */
    seed?: number;
    amplitude?: number;
    size?: CardSize;
    onSize?: (s: CardSize) => void;
    onHide: () => void;
    children: Snippet;
  } = $props();
</script>

<div class="chrome" class:editing style:--delay="{-seed * 0.17}s" style:--amp="{amplitude}deg">
  <div class="content">{@render children()}</div>
  {#if editing}
    <button class="hide" data-nodrag aria-label="Hide {title}" use:tip={`Hide ${title}`} onclick={onHide}>
      <Icons name="close" size={9} />
    </button>
    {#if size && onSize}
      <div class="size" data-nodrag>
        <Segmented tone="floating" options={["s", "m", "l"] as CardSize[]} selected={size} label={(v) => v.toUpperCase()} onSelect={onSize} ariaLabel="{title} size" />
      </div>
    {/if}
  {/if}
</div>

<style>
  .chrome {
    position: relative;
    height: 100%;
  }
  .editing {
    animation: wiggle 0.35s ease-in-out infinite alternate;
    animation-delay: var(--delay);
  }
  @keyframes wiggle {
    from {
      transform: rotate(calc(var(--amp) * -1));
    }
    to {
      transform: rotate(var(--amp));
    }
  }
  .content {
    height: 100%;
  }
  /* The content is only there to look at; the card itself is what gets dragged. */
  .editing .content {
    pointer-events: none;
  }
  .hide,
  .size {
    animation: pop 180ms var(--ease-out);
  }
  @keyframes pop {
    from {
      opacity: 0;
      transform: scale(0.7);
    }
  }
  .hide {
    position: absolute;
    top: -6px;
    left: -6px;
    display: grid;
    place-items: center;
    width: 22px;
    height: 22px;
    border-radius: var(--pill);
    background: var(--surface);
    box-shadow:
      0 2px 8px var(--shadow),
      inset 0 0 0 0.5px var(--hairline);
  }
  .hide::after {
    content: "";
    position: absolute;
    inset: -9px;
  }
  .size {
    position: absolute;
    right: 6px;
    bottom: 6px;
    transform-origin: bottom right;
  }
  @media (prefers-reduced-motion: reduce) {
    .editing,
    .hide,
    .size {
      animation: none;
    }
  }
</style>
