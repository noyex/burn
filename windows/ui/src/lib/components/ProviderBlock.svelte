<!--
  One provider as a solid block in its card color (UsageBlocks.swift `ProviderBlock`).
  L spans the width with the other windows on the right; M lists them below; S is one row with a
  bar of what's left.
-->
<script lang="ts">
  import { clock } from "../clock.svelte";
  import { remaining, reset, resetsSoon } from "../format";
  import { alertColor, level } from "../level";
  import { theme } from "../theme.svelte";
  import { tip } from "../tip.svelte";
  import { PROVIDER_NAME, limitsOf, type CardColor, type CardSize, type LimitState, type LimitWindow, type ProviderId } from "../types";
  import BigPercent from "./BigPercent.svelte";
  import BlockArt from "./BlockArt.svelte";
  import Glyph from "./Glyph.svelte";
  import Icons from "./Icons.svelte";
  import Pulse from "./Pulse.svelte";

  let {
    provider,
    state,
    primary,
    size,
    color,
  }: { provider: ProviderId; state: LimitState; primary: LimitWindow | null; size: CardSize; color: CardColor } = $props();

  const limits = $derived(limitsOf(state));
  const others = $derived(limits && primary ? limits.windows.filter((w) => w.id !== primary.id) : []);
  const hero = $derived(size === "l");
  const name = $derived(PROVIDER_NAME[provider]);
  const primaryLevel = $derived(primary ? level(primary.percent) : "normal");

  function caption(w: LimitWindow): string {
    const r = reset(w.resetsAt, clock.now);
    if (!r) return w.label;
    if (!hero) return `${w.label} · ${r}`;
    return resetsSoon(w.resetsAt, clock.now) ? `${w.label} · resets in ${r}` : `${w.label} · resets ${r}`;
  }

  /** Why a window is flagged, and when it comes back. */
  function alertTip(w: LimitWindow): string {
    const r = reset(w.resetsAt, clock.now);
    const what = level(w.percent) === "full" ? `${w.label} limit used up` : `${w.label} limit almost used up, ${remaining(w.percent)}% left`;
    if (!r) return what;
    return resetsSoon(w.resetsAt, clock.now) ? `${what}. Resets in ${r}` : `${what}. Resets ${r}`;
  }

  function a11y(w: LimitWindow): string {
    return `${name} ${w.label}: ${remaining(w.percent)}% left, resets ${reset(w.resetsAt, clock.now)}`;
  }
</script>

{#snippet header(plan: string | null, showAlert: boolean, trailing?: () => any)}
  <div class="header">
    <Glyph {provider} size={12} />
    <span class="name">{name}</span>
    {#if plan}<span class="plan">{plan}</span>{/if}
    <span class="spacer"></span>
    {#if state.state === "failed"}
      <span class="failed" use:tip={state.message} aria-label={state.message}><Icons name="alert-triangle" size={10} /></span>
    {/if}
    {#if showAlert && primary && primaryLevel !== "normal"}
      <span
        class="pill"
        style:background="var(--{color}-ink)"
        style:color={alertColor(primaryLevel, color, theme.lightInk[color])}
        use:tip={alertTip(primary)}
      >
        {primaryLevel === "full" ? "Empty" : "Low"}
      </span>
    {/if}
    {@render trailing?.()}
  </div>
{/snippet}

{#snippet windowLabel(w: LimitWindow)}
  <span class="label">
    {#if level(w.percent) !== "normal"}
      <span use:tip={alertTip(w)}><Icons name="alert-circle" size={10} /></span>
    {/if}
    {w.label}
  </span>
{/snippet}

{#snippet small(w: LimitWindow)}
  <div class="small" aria-label={a11y(w)}>
    <span class="dim">{@render windowLabel(w)}</span>
    <span class="bold tabular">{remaining(w.percent)}%</span>
    {#if reset(w.resetsAt, clock.now)}<span class="dim">· {reset(w.resetsAt, clock.now)}</span>{/if}
  </div>
{/snippet}

<div
  class="block card {size}"
  style:background="var(--{color})"
  style:color="var(--{color}-ink)"
  role="group"
  aria-label={name}
>
  <BlockArt fill={color} />
  {#if limits && primary}
    {#if size === "s"}
      {#snippet value()}
        <span class="value-s tabular">{remaining(primary!.percent)}%</span>
      {/snippet}
      {@render header(limits.plan, true, value)}
      <div class="bar" aria-hidden="true"><div class="fill" style:width="{remaining(primary.percent)}%"></div></div>
      <div class="caption" aria-label={a11y(primary)}>{caption(primary)}</div>
    {:else if size === "m"}
      {@render header(limits.plan, true)}
      <div class="grow"></div>
      <div aria-label={a11y(primary)}>
        <BigPercent value={remaining(primary.percent)} size={38} />
        <div class="caption">{caption(primary)}</div>
      </div>
      {#each others as w (w.id)}
        <div class="after-3">{@render small(w)}</div>
      {/each}
    {:else}
      {@render header(limits.plan, true)}
      <div class="grow"></div>
      <div class="hero-row">
        <div class="hero-main">
          <div aria-label={a11y(primary)}>
            <BigPercent value={remaining(primary.percent)} size={52} />
            <div class="caption">{caption(primary)}</div>
          </div>
          {#each others.filter((w) => w.minor) as w (w.id)}
            <div class="after-4">{@render small(w)}</div>
          {/each}
        </div>
        <div class="hero-side">
          {#each others.filter((w) => !w.minor) as w (w.id)}
            <div class="hero-secondary" aria-label={a11y(w)}>
              <span class="dim">{@render windowLabel(w)}</span>
              <span class="value-l tabular">{remaining(w.percent)}%</span>
              <span class="dim">{reset(w.resetsAt, clock.now)}</span>
            </div>
          {/each}
        </div>
      </div>
    {/if}
  {:else if limits}
    <!-- Loaded but no windows reported: nothing to pulse for. -->
    {@render header(limits.plan, false)}
  {:else if size === "s"}
    {#snippet loadingValue()}
      <Pulse><span class="skel" style:width="36px" style:height="16px" style:opacity="0.22"></span></Pulse>
    {/snippet}
    {@render header(null, false, loadingValue)}
    <Pulse>
      <span class="skel" style:width="100%" style:height="4px" style:margin-top="5px"></span>
      <span class="skel" style:width="84px" style:height="9px" style:margin-top="6px"></span>
    </Pulse>
  {:else}
    {@render header(null, false)}
    <div class="grow"></div>
    <Pulse>
      <span class="skel" style:width={hero ? "92px" : "64px"} style:height={hero ? "40px" : "30px"} style:opacity="0.22"></span>
      <span class="skel" style:width="84px" style:height="9px" style:margin-top="6px"></span>
    </Pulse>
  {/if}
</div>

<style>
  .card {
    display: flex;
    flex-direction: column;
    min-height: 92px;
    height: 100%;
  }
  .card.l {
    min-height: 96px;
  }
  .card.s {
    min-height: 0;
    padding: 10px;
    gap: 5px;
  }
  .header {
    display: flex;
    align-items: center;
    gap: 5px;
    white-space: nowrap;
    min-width: 0;
  }
  .name {
    font-weight: 700;
    font-size: 12px;
  }
  .plan {
    font-size: 11px;
    opacity: 0.65;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .spacer {
    flex: 1;
    min-width: 4px;
  }
  .failed {
    opacity: 0.7;
    display: inline-flex;
  }
  .pill {
    font-size: 10px;
    font-weight: 700;
    padding: 1px 6px;
    border-radius: var(--pill);
  }
  .grow {
    flex: 1;
    min-height: 10px;
  }
  .caption {
    font-size: 11px;
    opacity: 0.75;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    margin-top: 1px;
  }
  .after-3 {
    margin-top: 3px;
  }
  .after-4 {
    margin-top: 4px;
  }
  .small {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 11px;
    white-space: nowrap;
  }
  .dim {
    opacity: 0.75;
  }
  .bold {
    font-weight: 700;
  }
  .label {
    display: inline-flex;
    align-items: center;
    gap: 3px;
  }
  .hero-row {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: 8px;
  }
  .hero-main {
    min-width: 0;
  }
  .hero-side {
    display: flex;
    align-items: flex-end;
    gap: 14px;
  }
  .hero-secondary {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 1px;
    font-size: 11px;
    white-space: nowrap;
  }
  .value-l {
    font-family: var(--font-display);
    font-weight: 800;
    font-size: 22px;
    line-height: 1.05;
  }
  .value-s {
    font-family: var(--font-display);
    font-weight: 800;
    font-size: 20px;
    line-height: 1;
  }
  .bar {
    height: 4px;
    border-radius: 2px;
    background: color-mix(in srgb, currentColor 20%, transparent);
    overflow: hidden;
  }
  .fill {
    height: 100%;
    border-radius: 2px;
    background: currentColor;
    transition: width 300ms var(--ease-out);
  }
  .skel {
    display: block;
    border-radius: var(--pill);
    background: currentColor;
    opacity: 0.16;
  }
</style>
