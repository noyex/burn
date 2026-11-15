<!-- Round icon button (Bento.swift `RoundIconButton`). -->
<script lang="ts">
  import { tip } from "../tip.svelte";
  import Icons from "./Icons.svelte";

  let {
    icon,
    label,
    onclick,
    size = 28,
    floating = false,
  }: {
    icon: "gear" | "chevron-left" | "expand" | "collapse";
    label: string;
    onclick: () => void;
    size?: number;
    /** Sits on its own over the desktop instead of on a surface. */
    floating?: boolean;
  } = $props();
</script>

<button class="round" class:floating style:width="{size}px" style:height="{size}px" aria-label={label} use:tip={label} {onclick}>
  <Icons name={icon} size={Math.round(size * 0.46)} />
</button>

<style>
  .round {
    position: relative;
    display: grid;
    place-items: center;
    flex: none;
    border-radius: var(--pill);
    background: var(--neutral);
    color: var(--secondary);
    transition:
      background 150ms ease-out,
      color 150ms ease-out,
      transform 120ms ease-out;
  }
  /* Hit area of 40 px. */
  .round::after {
    content: "";
    position: absolute;
    inset: -6px;
  }
  .round.floating {
    background: var(--surface);
    box-shadow:
      0 4px 20px var(--shadow),
      inset 0 0 0 0.5px var(--hairline);
  }
  .round.floating:hover {
    background: var(--raised);
  }
  .round:hover {
    background: var(--neutral-hover);
    color: var(--text);
  }
  .round:active {
    transform: scale(0.96);
  }
</style>
