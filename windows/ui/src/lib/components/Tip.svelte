<!-- The one hover bubble of the panel, above the hovered element (below it near the top edge). -->
<script lang="ts">
  import { tipState } from "../tip.svelte";

  let bubble: HTMLDivElement | undefined = $state();
  let pos = $state<{ x: number; y: number } | null>(null);

  $effect(() => {
    const r = tipState.rect;
    if (!r || !tipState.text || !bubble) {
      pos = null;
      return;
    }
    const w = bubble.offsetWidth;
    const h = bubble.offsetHeight;
    const x = Math.min(Math.max(r.left + r.width / 2 - w / 2, 4), window.innerWidth - w - 4);
    const above = r.top - h - 6;
    pos = { x, y: above >= 2 ? above : r.bottom + 6 };
  });
</script>

<div
  class="tip"
  class:shown={pos != null}
  bind:this={bubble}
  style:transform="translate({pos?.x ?? 0}px, {pos?.y ?? 0}px)"
  role="tooltip"
>
  {tipState.text ?? ""}
</div>

<style>
  .tip {
    position: fixed;
    left: 0;
    top: 0;
    max-width: 240px;
    padding: 5px 8px;
    border-radius: var(--radius-small);
    background: var(--surface);
    color: var(--text);
    font-size: 11px;
    line-height: 1.35;
    white-space: pre-line;
    box-shadow:
      0 4px 20px var(--shadow),
      inset 0 0 0 0.5px var(--hairline);
    pointer-events: none;
    opacity: 0;
    transition: opacity 120ms ease-out;
    z-index: 10;
  }
  .tip.shown {
    opacity: 1;
  }
</style>
