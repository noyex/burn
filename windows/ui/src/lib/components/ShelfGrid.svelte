<!-- Grid of copied screenshots (ShelfView.swift). Scrolls inside its maximum height. -->
<script lang="ts">
  import type { ShelfItem } from "../types";
  import ShelfTile from "./ShelfTile.svelte";

  let {
    items,
    width,
    columns,
    maxHeight,
    selection,
    onToggle,
    onCopy,
  }: {
    items: ShelfItem[];
    width: number;
    columns: number;
    maxHeight: number;
    selection: string[];
    onToggle: (path: string) => void;
    onCopy: (item: ShelfItem) => Promise<boolean>;
  } = $props();

  const SPACING = 8;
  /** Scroll content reaches past the grid so tile shadows aren't clipped. */
  const INSET = 10;
  const tileWidth = $derived((width - SPACING * (columns - 1)) / columns);
  const tileHeight = $derived(Math.round(tileWidth * 0.625));
</script>

{#if items.length === 0}
  <div class="block empty">
    <p class="title">Screenshots you copy show up here</p>
    <p class="how">Win+Shift+S or copy any image</p>
  </div>
{:else}
  <div class="scroll" style:width="{width + INSET * 2}px" style:max-height="{maxHeight + INSET * 2}px" style:--inset="{INSET}px">
    <div class="grid" style:grid-template-columns="repeat({columns}, {tileWidth}px)" style:gap="{SPACING}px">
      {#each items as item (item.path)}
        <ShelfTile
          {item}
          width={tileWidth}
          height={tileHeight}
          selected={selection.includes(item.path)}
          selecting={selection.length > 0}
          onToggle={() => onToggle(item.path)}
          onCopy={() => onCopy(item)}
        />
      {/each}
    </div>
  </div>
{/if}

<style>
  .scroll {
    margin: calc(var(--inset) * -1);
    padding: var(--inset);
    overflow-y: auto;
    scrollbar-width: none;
  }
  .scroll::-webkit-scrollbar {
    display: none;
  }
  .grid {
    display: grid;
  }
  .empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 4px;
    padding: 36px 12px;
    background: var(--accent);
    color: var(--accent-ink);
    text-align: center;
  }
  .title {
    font-size: 13px;
    font-weight: 700;
  }
  .how {
    opacity: 0.6;
  }
</style>
