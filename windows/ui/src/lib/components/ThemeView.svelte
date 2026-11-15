<!-- Picks a theme by its colors (ThemeSettingsView.swift). The panel shows next to this page, so a pick is seen at once. -->
<script lang="ts">
  import { openThemesFolder } from "../api";
  import { appearance } from "../appearance.svelte";
  import { BRAND } from "../level";
  import { tip } from "../tip.svelte";
  import { PROVIDERS, type ThemeState, type ThemeSwatch } from "../types";
  import Glyph from "./Glyph.svelte";
  import Icons from "./Icons.svelte";
  import RoundButton from "./RoundButton.svelte";

  let { theme, onPick, onBack }: { theme: ThemeState; onPick: (id: string | null) => void; onBack: () => void } = $props();

  /** The prompt just copied, to confirm it on its button. */
  let copied = $state<string | null>(null);
  let copiedTimer: ReturnType<typeof setTimeout> | undefined;

  const tiles = $derived([
    { id: null as string | null, title: "Default", swatch: theme.defaultSwatch },
    ...theme.available.map((t) => ({ id: t.id as string | null, title: t.title, swatch: t.swatch })),
  ]);

  /** A theme at a glance: its main fill with two of its other colors glowing through. */
  function orb(swatch: ThemeSwatch): string {
    const colors = appearance.dark ? swatch.dark : swatch.light;
    const c = (i: number) => colors[Math.min(i, colors.length - 1)];
    return `radial-gradient(circle 19px at 30% 28%, ${c(1)}, transparent), radial-gradient(circle 18px at 74% 80%, ${c(2)}, transparent), ${c(0)}`;
  }

  async function copy(prompt: string) {
    try {
      await navigator.clipboard.writeText(prompt);
    } catch {
      // Clipboard denied: nothing to confirm.
      return;
    }
    copied = prompt;
    clearTimeout(copiedTimer);
    copiedTimer = setTimeout(() => (copied = null), 1800);
  }
</script>

<div class="header">
  <RoundButton icon="chevron-left" label="Back" onclick={onBack} />
  <h1>Theme</h1>
</div>

<div class="grid" role="radiogroup" aria-label="Theme">
  {#each tiles as t (t.id)}
    {@const on = theme.selected === t.id}
    <button class="tile" class:on role="radio" aria-checked={on} aria-label={t.title} onclick={() => onPick(t.id)}>
      <span class="ring"><span class="orb" style:background={orb(t.swatch)}></span></span>
      <span class="name">{t.title}</span>
    </button>
  {/each}
</div>
{#if theme.issues.length > 0}
  <p class="issue">{theme.issues[0]}</p>
{/if}

<button
  class="ask"
  onclick={() => copy(theme.agentPrompt)}
  use:tip={"Copies a prompt. Paste it to Claude Code, Codex or Cursor and say what you want"}
  aria-label="Copy a prompt that asks your agent for a theme"
>
  <span class="agents">
    {#each PROVIDERS as p (p)}
      <span class="agent" style:background="var(--{BRAND[p]})" style:color="var(--{BRAND[p]}-ink)"><Glyph provider={p} size={13} /></span>
    {/each}
  </span>
  <span class="grow">{copied === theme.agentPrompt ? "Copied. Paste it to your agent" : "Ask your agent"}</span>
  <Icons name={copied === theme.agentPrompt ? "check" : "copy"} size={11} />
</button>
<button class="ideas" onclick={() => copy(theme.ideasPrompt)} use:tip={"Copies a prompt: your agent designs four themes to pick from"}>
  {copied === theme.ideasPrompt ? "Copied. Paste it to your agent" : "No idea? Ask for a few designs"}
</button>

<div class="group">
  <button class="row" onclick={openThemesFolder}>
    <span class="grow">Open themes folder</span>
    <span class="secondary"><Icons name="chevron-right" size={10} /></span>
  </button>
</div>

<style>
  .header {
    display: flex;
    align-items: center;
    gap: 10px;
    padding-bottom: 4px;
  }
  h1 {
    font-size: 14px;
    font-weight: 700;
  }
  .grid {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: var(--gap);
  }
  .tile {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 7px;
    min-height: 68px;
    padding: 0 2px;
    border-radius: var(--radius-small);
    background: var(--neutral);
    transition:
      background 150ms ease-out,
      transform 120ms ease-out;
  }
  .tile:hover {
    background: var(--neutral-hover);
  }
  .tile:active {
    transform: scale(0.97);
  }
  /* The selection ring, a hair away from the orb. */
  .ring {
    display: grid;
    place-items: center;
    width: 38px;
    height: 38px;
    border-radius: 50%;
    box-shadow: inset 0 0 0 1.5px transparent;
    transition: box-shadow 150ms ease-out;
  }
  .on .ring {
    box-shadow: inset 0 0 0 1.5px var(--text);
  }
  .orb {
    width: 32px;
    height: 32px;
    border-radius: 50%;
    box-shadow: inset 0 0 0 0.5px var(--hairline);
  }
  .name {
    max-width: 100%;
    font-size: 10px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .on .name {
    font-weight: 700;
  }
  .issue {
    padding: 0 4px;
    font-size: 11px;
    color: var(--danger);
  }
  /* The main action: one big pill with the agents it works with. */
  .ask {
    display: flex;
    align-items: center;
    gap: 10px;
    height: 42px;
    margin-top: 6px;
    padding: 0 14px 0 9px;
    border-radius: var(--pill);
    background: var(--text);
    color: var(--base);
    font-size: 13px;
    font-weight: 700;
    text-align: left;
    transition: transform 120ms ease-out;
  }
  .ask:active {
    transform: scale(0.97);
  }
  .agents {
    display: flex;
  }
  .agent {
    display: grid;
    place-items: center;
    width: 24px;
    height: 24px;
    border-radius: 50%;
    /* Cuts each badge out of the one under it. */
    box-shadow: inset 0 0 0 1.5px var(--text);
  }
  .agent + .agent {
    margin-left: -7px;
  }
  .grow {
    flex: 1;
    min-width: 0;
  }
  .ideas {
    min-height: 32px;
    font-size: 11px;
    color: var(--secondary);
    transition: color 150ms ease-out;
  }
  .ideas:hover {
    color: var(--text);
  }
  .group {
    padding: 0 12px;
    border-radius: var(--radius);
    background: var(--neutral);
  }
  .row {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    min-height: 40px;
    text-align: left;
  }
  .secondary {
    color: var(--secondary);
  }
</style>
