<!-- Copies an image of the period's spend; morphs into "Copied" for a moment (PopoverView.swift `shareButton`). -->
<script lang="ts">
  import { onDestroy } from "svelte";
  import { shareCopy } from "../api";
  import { tip } from "../tip.svelte";
  import type { Period } from "../types";
  import Icons from "./Icons.svelte";

  let { period }: { period: Period } = $props();

  let done = $state(false);
  let timer: ReturnType<typeof setTimeout> | undefined;

  async function copy() {
    if (!(await shareCopy(period))) return;
    done = true;
    clearTimeout(timer);
    timer = setTimeout(() => (done = false), 1400);
  }

  onDestroy(() => clearTimeout(timer));
</script>

<button class="share" class:done aria-label={done ? "Copied" : "Copy an image of your spend"} use:tip={done ? null : "Copy an image of your spend"} onclick={copy}>
  <span class="icon">
    <span class="glyph" class:off={done}><Icons name="share" size={12} /></span>
    <span class="glyph" class:off={!done}><Icons name="check" size={12} /></span>
  </span>
  <span class="label"><span>Copied</span></span>
</button>

<style>
  .share {
    position: relative;
    display: flex;
    align-items: center;
    flex: none;
    height: 28px;
    min-width: 28px;
    padding: 0 8px;
    border-radius: var(--pill);
    background: var(--neutral);
    color: var(--secondary);
    transition:
      background 150ms ease-out,
      color 150ms ease-out,
      transform 120ms ease-out;
  }
  /* Hit area of 40 px. */
  .share::after {
    content: "";
    position: absolute;
    inset: -6px -2px;
  }
  .share:hover {
    background: var(--neutral-hover);
  }
  .share:active {
    transform: scale(0.96);
  }
  .share.done {
    color: var(--text);
  }
  .icon {
    display: grid;
    width: 12px;
    height: 12px;
  }
  .glyph {
    grid-area: 1 / 1;
    transition:
      opacity 150ms ease-out,
      transform 200ms var(--ease-out);
  }
  .glyph.off {
    opacity: 0;
    transform: scale(0.6);
  }
  /* The label grows out of nothing, so the button widens smoothly. */
  .label {
    display: grid;
    grid-template-columns: 0fr;
    opacity: 0;
    font-size: 11px;
    font-weight: 700;
    transition:
      grid-template-columns 220ms var(--ease-out),
      opacity 150ms ease-out;
  }
  .label span {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    padding-left: 0;
  }
  .done .label {
    grid-template-columns: 1fr;
    opacity: 1;
  }
  .done .label span {
    padding-left: 5px;
  }
</style>
