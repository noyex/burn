<!-- The provider cards. While editing they can be dragged: a lifted copy follows the pointer, the card
     leaves a gap that moves to whichever card the pointer enters (PopoverView.swift `reorderGesture`). -->
<script lang="ts">
  import { flip } from "svelte/animate";
  import { cubicOut } from "svelte/easing";
  import { cardWindow } from "../layout";
  import { reducedMotion } from "../motion";
  import { holdToEdit } from "../press";
  import { BRAND } from "../level";
  import { PROVIDERS, PROVIDER_NAME, limitsOf, type CardSize, type ProviderId, type Snapshot } from "../types";
  import EditChrome from "./EditChrome.svelte";
  import ProviderBlock from "./ProviderBlock.svelte";

  let {
    snap,
    cards,
    rows,
    sizeOf,
    editing,
    onEdit,
    onHide,
    onSize,
    onReorder,
  }: {
    snap: Snapshot;
    cards: ProviderId[];
    rows: ProviderId[][];
    sizeOf: Map<ProviderId, CardSize>;
    editing: boolean;
    onEdit: () => void;
    onHide: (p: ProviderId) => void;
    onSize: (p: ProviderId, s: CardSize) => void;
    onReorder: (next: ProviderId[]) => void;
  } = $props();

  let grid: HTMLDivElement | undefined = $state();
  const cells: Partial<Record<ProviderId, HTMLElement>> = {};
  let dragging = $state<ProviderId | null>(null);
  let lifted = $state({ x: 0, y: 0, w: 0, h: 0 });
  let press: { id: ProviderId; x: number; y: number } | null = null;
  let grab = { x: 0, y: 0 };
  let lastSwap: ProviderId | null = null;

  const rowOf = (p: ProviderId) => rows.findIndex((r) => r.includes(p));
  const paired = (p: ProviderId) => (rows[rowOf(p)]?.length ?? 1) > 1;
  const seed = (p: ProviderId) => PROVIDERS.indexOf(p) * 1.9;

  $effect(() => {
    if (!editing) endDrag();
  });

  function rect(p: ProviderId) {
    const c = cells[p]?.getBoundingClientRect();
    const g = grid?.getBoundingClientRect();
    return c && g ? { x: c.left - g.left, y: c.top - g.top, w: c.width, h: c.height } : null;
  }

  function down(e: PointerEvent) {
    if (!editing || e.button !== 0 || (e.target as Element).closest("[data-nodrag]")) return;
    const id = (e.target as Element).closest<HTMLElement>("[data-card]")?.dataset.card as ProviderId | undefined;
    if (id) press = { id, x: e.clientX, y: e.clientY };
  }

  function move(e: PointerEvent) {
    if (!press || !grid) return;
    const g = grid.getBoundingClientRect();
    const x = e.clientX - g.left;
    const y = e.clientY - g.top;
    if (!dragging) {
      if (Math.hypot(e.clientX - press.x, e.clientY - press.y) < 3) return;
      const r = rect(press.id);
      if (!r) return;
      grid.setPointerCapture(e.pointerId);
      grab = { x: press.x - g.left - r.x, y: press.y - g.top - r.y };
      lifted = { ...lifted, w: r.w, h: r.h };
      lastSwap = null;
      dragging = press.id;
    }
    lifted = { ...lifted, x: x - grab.x, y: y - grab.y };
    const target = cards.find((c) => {
      const r = c !== dragging && rect(c);
      return r && x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h;
    });
    if (!target) {
      lastSwap = null;
      return;
    }
    // Once per card entered, so a card that changes size on the move can't flip back and forth.
    if (target === lastSwap || !dragging) return;
    lastSwap = target;
    const next = cards.filter((c) => c !== dragging);
    next.splice(cards.indexOf(target), 0, dragging);
    onReorder(next);
  }

  function endDrag() {
    press = null;
    dragging = null;
  }

  /** Arrow keys move the focused card, for keyboard use. */
  function key(e: KeyboardEvent, p: ProviderId) {
    if (!editing || e.target !== e.currentTarget) return;
    const step = e.key === "ArrowUp" || e.key === "ArrowLeft" ? -1 : e.key === "ArrowDown" || e.key === "ArrowRight" ? 1 : 0;
    const i = cards.indexOf(p);
    if (!step || i + step < 0 || i + step >= cards.length) return;
    e.preventDefault();
    const next = [...cards];
    next.splice(i + step, 0, next.splice(i, 1)[0]);
    onReorder(next);
  }
</script>

{#snippet block(p: ProviderId)}
  {@const state = snap.limits[p] ?? { state: "loading" as const }}
  {@const limits = limitsOf(state)}
  <ProviderBlock
    provider={p}
    {state}
    primary={limits ? cardWindow(snap, limits) : null}
    size={sizeOf.get(p) ?? "m"}
    color={snap.settings.cardColors[p] ?? BRAND[p]}
  />
{/snippet}

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="grid"
  class:editing
  bind:this={grid}
  onpointerdown={down}
  onpointermove={move}
  onpointerup={endDrag}
  onpointercancel={endDrag}
  onlostpointercapture={endDrag}
>
  {#each cards as p (p)}
    <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
    <div
      class="cell"
      class:paired={paired(p)}
      class:lifted={dragging === p}
      data-card={p}
      bind:this={cells[p]}
      tabindex={editing ? 0 : -1}
      role={editing ? "group" : undefined}
      aria-label={editing ? `${PROVIDER_NAME[p]}, arrow keys move it` : undefined}
      onkeydown={(e) => key(e, p)}
      animate:flip={{ duration: reducedMotion() ? 0 : 220, easing: cubicOut }}
      use:holdToEdit={editing ? null : onEdit}
    >
      <div class="inner reveal" style:--i={rowOf(p)}>
        <EditChrome
          editing={editing && dragging !== p}
          title={PROVIDER_NAME[p]}
          seed={seed(p)}
          amplitude={sizeOf.get(p) === "m" ? 0.6 : 0.35}
          size={sizeOf.get(p) ?? "m"}
          onSize={(s) => onSize(p, s)}
          onHide={() => onHide(p)}
        >
          {@render block(p)}
        </EditChrome>
      </div>
    </div>
  {/each}
  {#if dragging}
    <div class="lift" style:width="{lifted.w}px" style:height="{lifted.h}px" style:transform="translate({lifted.x}px, {lifted.y}px) scale(1.03)">
      {@render block(dragging)}
    </div>
  {/if}
</div>

<style>
  .grid {
    position: relative;
    display: flex;
    flex-wrap: wrap;
    gap: var(--gap);
  }
  .cell {
    flex: 0 0 100%;
    min-width: 0;
    border-radius: var(--radius);
    outline: none;
  }
  .cell.paired {
    flex-basis: calc((100% - var(--gap)) / 2);
  }
  .editing .cell {
    touch-action: none;
    cursor: grab;
  }
  .editing .cell:focus-visible {
    box-shadow: 0 0 0 2px var(--text);
  }
  /* The gap the card leaves while its copy is in the air. */
  .cell.lifted {
    background: color-mix(in srgb, var(--text) 6%, transparent);
  }
  .cell.lifted .inner {
    opacity: 0;
  }
  .inner {
    height: 100%;
  }
  .lift {
    position: absolute;
    top: 0;
    left: 0;
    z-index: 2;
    pointer-events: none;
    cursor: grabbing;
    animation: lift 150ms var(--ease-out);
  }
  @keyframes lift {
    from {
      opacity: 0.6;
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .lift {
      animation: none;
    }
  }
</style>
