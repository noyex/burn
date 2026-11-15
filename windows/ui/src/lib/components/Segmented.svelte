<!-- Compact segmented pills whose selection slides between options (Bento.swift `PillSegmented`). -->
<script lang="ts" generics="T extends string">
  let {
    options,
    selected,
    label,
    onSelect,
    ariaLabel,
    tone = "lime",
  }: {
    options: T[];
    selected: T;
    label: (v: T) => string;
    onSelect: (v: T) => void;
    ariaLabel: string;
    /** lime: on the spend block; neutral: on a settings row; floating: over a card while editing. */
    tone?: "lime" | "neutral" | "floating";
  } = $props();

  let buttons: HTMLButtonElement[] = $state([]);
  let thumb = $state<{ left: number; width: number } | null>(null);
  // Slides only after the first placement, so it doesn't fly in when the panel opens.
  let ready = $state(false);

  // Measured after the DOM update: the selected label is bold, so its width changes with it.
  $effect(() => {
    const el = buttons[options.indexOf(selected)];
    if (!el) return;
    thumb = { left: el.offsetLeft, width: el.offsetWidth };
    requestAnimationFrame(() => (ready = true));
  });
</script>

<div class="track {tone}" role="radiogroup" aria-label={ariaLabel}>
  {#if thumb}
    <span class="thumb" class:ready style:transform="translateX({thumb.left}px)" style:width="{thumb.width}px"></span>
  {/if}
  {#each options as o, i (o)}
    <button
      bind:this={buttons[i]}
      class:selected={o === selected}
      role="radio"
      aria-checked={o === selected}
      onclick={() => onSelect(o)}>{label(o)}</button
    >
  {/each}
</div>

<style>
  .track {
    position: relative;
    display: flex;
    padding: 2px;
    border-radius: var(--pill);
    --track: color-mix(in srgb, var(--accent-ink) 8%, transparent);
    --thumb: var(--accent-ink);
    --on: var(--accent);
    --off: color-mix(in srgb, var(--accent-ink) 70%, transparent);
    background: var(--track);
  }
  .neutral {
    --track: color-mix(in srgb, var(--text) 6%, transparent);
    --thumb: var(--raised);
    --on: var(--text);
    --off: var(--secondary);
  }
  .floating {
    --track: var(--surface);
    --thumb: var(--text);
    --on: var(--base);
    --off: var(--secondary);
    box-shadow: 0 2px 6px var(--shadow);
  }
  .thumb {
    position: absolute;
    top: 2px;
    left: 0;
    height: 22px;
    border-radius: var(--pill);
    background: var(--thumb);
  }
  .thumb.ready {
    transition:
      transform var(--snappy),
      width var(--snappy);
  }
  button {
    position: relative;
    height: 22px;
    padding: 0 8px;
    border-radius: var(--pill);
    font-size: 11px;
    color: var(--off);
    transition: color 150ms ease-out;
  }
  /* Taller to hit than to look at. */
  button::after {
    content: "";
    position: absolute;
    inset: -9px 0;
  }
  button.selected {
    color: var(--on);
    font-weight: 700;
  }
</style>
