<!-- The icon capsule above the content (Bento.swift `IconSwitcher`); the highlight slides between tabs. -->
<script lang="ts">
  import { tip } from "../tip.svelte";
  import type { Tab } from "../types";
  import Icons from "./Icons.svelte";

  let { selected, onSelect }: { selected: Tab; onSelect: (t: Tab) => void } = $props();

  const TABS: { id: Tab; title: string }[] = [
    { id: "usage", title: "Usage" },
    { id: "shelf", title: "Shelf" },
  ];
  const index = $derived(TABS.findIndex((t) => t.id === selected));

  function key(e: KeyboardEvent) {
    if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
    e.preventDefault();
    const next = TABS[(index + (e.key === "ArrowRight" ? 1 : TABS.length - 1)) % TABS.length];
    onSelect(next.id);
    (e.currentTarget as HTMLElement).querySelector<HTMLElement>(`[data-tab="${next.id}"]`)?.focus();
  }
</script>

<div class="switcher" role="tablist" aria-label="View" tabindex="-1" onkeydown={key}>
  <span class="thumb" style:transform="translateX({index * 40}px)"></span>
  {#each TABS as t (t.id)}
    <button
      class:selected={t.id === selected}
      data-tab={t.id}
      role="tab"
      aria-selected={t.id === selected}
      aria-label={t.title}
      tabindex={t.id === selected ? 0 : -1}
      use:tip={t.title}
      onclick={() => onSelect(t.id)}
    >
      <Icons name={t.id} size={14} />
    </button>
  {/each}
</div>

<style>
  .switcher {
    position: relative;
    display: flex;
    padding: 3px;
    border-radius: var(--pill);
    background: var(--switcher);
    color: var(--switcher-ink);
    box-shadow:
      0 4px 20px var(--shadow),
      inset 0 0 0 0.5px var(--hairline);
  }
  .thumb {
    position: absolute;
    top: 3px;
    left: 3px;
    width: 40px;
    height: 30px;
    border-radius: var(--pill);
    background: color-mix(in srgb, var(--switcher-ink) 16%, transparent);
    transition: transform var(--snappy);
  }
  button {
    position: relative;
    display: grid;
    place-items: center;
    width: 40px;
    height: 30px;
    border-radius: var(--pill);
    opacity: 0.5;
    transition:
      opacity 150ms ease-out,
      transform 120ms ease-out;
  }
  /* Taller to hit than to look at. */
  button::after {
    content: "";
    position: absolute;
    inset: -5px 0;
  }
  button:hover {
    opacity: 0.8;
  }
  button.selected {
    opacity: 1;
  }
  button:active {
    transform: scale(0.94);
  }
  button:focus-visible {
    outline-color: var(--switcher-ink);
    outline-offset: -2px;
  }
</style>
