<!-- Settings (SettingsView.swift, ProviderSettingsView.swift): the panel's options, one page per provider, and the theme page. -->
<script lang="ts">
  import { cardProviders, customSizeOf, orderedProviders, sizes } from "../layout";
  import {
    cardWindowId,
    setCardColor,
    setCardSize,
    setCardWindow,
    setPanelLayout,
    setPanelOrder,
    setShelfRetentionDays,
    setShowsInPanel,
    setShowsInWidget,
    setShowsSpending,
    setTrayOnly,
    setWidgetWindow,
    showsInPanel,
    showsInWidget,
    widgetWindow,
  } from "../settings";
  import { tip } from "../tip.svelte";
  import {
    LOGIN_COMMAND,
    PROVIDER_NAME,
    limitsOf,
    type CardColor,
    type CardSize,
    type PanelLayout,
    type PanelOrder,
    type ProviderId,
    type Settings,
    type Snapshot,
  } from "../types";
  import CommandChip from "./CommandChip.svelte";
  import Glyph from "./Glyph.svelte";
  import { BRAND } from "../level";
  import Icons from "./Icons.svelte";
  import RoundButton from "./RoundButton.svelte";
  import Segmented from "./Segmented.svelte";
  import Select from "./Select.svelte";
  import Switch from "./Switch.svelte";
  import ThemeView from "./ThemeView.svelte";
  import ToggleRow from "./ToggleRow.svelte";

  let {
    snap,
    provider = $bindable(null),
    pickingTheme = $bindable(false),
    selectedTheme,
    commit,
    onTheme,
    onLaunch,
    onBack,
    onArrange,
    onQuit,
  }: {
    snap: Snapshot;
    /** The provider page that is open, if any. */
    provider: ProviderId | null;
    /** The theme page is open. */
    pickingTheme: boolean;
    /** The theme marked as on; ahead of `snap.theme` right after a pick. */
    selectedTheme: string | null;
    commit: (next: Settings) => void;
    /** A theme was picked; null is the built-in look. */
    onTheme: (id: string | null) => void;
    onLaunch: (on: boolean) => void;
    onBack: () => void;
    onArrange: () => void;
    onQuit: () => void;
  } = $props();

  const s = $derived(snap.settings);
  const LAYOUTS: PanelLayout[] = ["auto", "grid", "list", "custom"];
  const ORDERS: { id: PanelOrder; label: string }[] = [
    { id: "manual", label: "Manual" },
    { id: "closestToLimit", label: "Closest to limit" },
  ];
  const KEEP = [
    { id: "1", label: "1 day" },
    { id: "7", label: "7 days" },
    { id: "30", label: "30 days" },
    { id: "0", label: "Forever" },
  ];
  const COLORS: CardColor[] = ["coral", "mono", "lavender", "sky"];
  const cap = (v: string) => v[0].toUpperCase() + v.slice(1);

  function plan(p: ProviderId): string {
    if (!snap.connected.includes(p)) return "Not signed in";
    const st = snap.limits[p];
    if (st?.state === "signedOut") return "Signed out";
    return limitsOf(st)?.plan ?? "";
  }

  const signedIn = (p: ProviderId) => snap.connected.includes(p) && snap.limits[p]?.state !== "signedOut";

  /** `highest` plus every window the provider reports; null when there is nothing to choose. */
  function windowOptions(p: ProviderId, current: string) {
    const windows = limitsOf(snap.limits[p])?.windows ?? [];
    if (windows.length < 2) return null;
    return {
      value: windows.some((w) => w.id === current) ? current : "highest",
      options: [{ id: "highest", label: "Most used" }, ...windows.map((w) => ({ id: w.id, label: w.label }))],
    };
  }

  /** The size the card has under the current layout. */
  function sizeOf(p: ProviderId): CardSize {
    const cards = cardProviders(snap);
    return cards.includes(p) ? (sizes(s.panelLayout, cards, (x) => customSizeOf(s, x)).get(p) ?? "m") : customSizeOf(s, p);
  }
</script>

{#snippet header(title: string, back: () => void, p?: ProviderId)}
  <div class="header">
    <RoundButton icon="chevron-left" label="Back" onclick={back} />
    {#if p}<Glyph provider={p} size={13} />{/if}
    <h1>{title}</h1>
  </div>
{/snippet}

{#snippet title(text: string)}
  <h2>{text}</h2>
{/snippet}

<div class="settings">
  {#if pickingTheme}
    <ThemeView theme={snap.theme} selected={selectedTheme} onPick={onTheme} onBack={() => (pickingTheme = false)} />
  {:else if provider}
    {@const p = provider}
    {@const main = windowOptions(p, cardWindowId(s, p))}
    {@render header(PROVIDER_NAME[p], () => (provider = null), p)}

    <div class="group">
      <div class="item"><ToggleRow label="Show in panel" checked={showsInPanel(s, p)} onChange={(on) => commit(setShowsInPanel(s, p, on))} /></div>
      <div class="item row">
        <span class="label">Size</span>
        <Segmented
          tone="neutral"
          options={["s", "m", "l"] as CardSize[]}
          selected={sizeOf(p)}
          label={(v) => v.toUpperCase()}
          ariaLabel="Size"
          onSelect={(v) => commit(setCardSize(s, p, v, cardProviders(snap)))}
        />
      </div>
      <div class="item row">
        <span class="label">Color</span>
        <div class="swatches" role="radiogroup" aria-label="Color">
          {#each COLORS as c (c)}
            {@const on = (s.cardColors[p] ?? BRAND[p]) === c}
            <button class="swatch" class:on role="radio" aria-checked={on} aria-label={cap(c)} use:tip={cap(c)} onclick={() => commit(setCardColor(s, p, c))}>
              <span class="dot" style:background="var(--{c})" style:color="var(--{c}-ink)">{#if on}<Icons name="check" size={8} />{/if}</span>
            </button>
          {/each}
        </div>
      </div>
      {#if main}
        <div class="item row">
          <span class="label">Main number</span>
          <Select label="Main number" value={main.value} options={main.options} onChange={(id) => commit(setCardWindow(s, p, id))} />
        </div>
      {/if}
    </div>
    {#if s.panelLayout !== "custom"}
      <p class="note">Changing a size switches the panel to the Custom layout.</p>
    {/if}

    {@render title("Account")}
    <div class="group">
      <div class="item row">
        {#if signedIn(p)}
          <span class="label">Status</span>
          <span class="secondary">Signed in</span>
        {:else}
          <span class="label">Sign in</span>
          <CommandChip command={LOGIN_COMMAND[p]} />
        {/if}
      </div>
    </div>
  {:else}
    {@render header("Settings", onBack)}

    {@render title("Panel")}
    <div class="group">
      <div class="item row">
        <span class="label">Layout</span>
        <Segmented tone="neutral" options={LAYOUTS} selected={s.panelLayout} label={cap} ariaLabel="Layout" onSelect={(v) => commit(setPanelLayout(s, v))} />
      </div>
      <div class="item row">
        <span class="label">Order</span>
        <Select label="Order" value={s.panelOrder} options={ORDERS} onChange={(id) => commit(setPanelOrder(s, id as PanelOrder))} />
      </div>
      <div class="item"><ToggleRow label="Show spending" checked={s.showsSpending} onChange={(on) => commit(setShowsSpending(s, on))} /></div>
      <div class="item">
        <button class="row link" onclick={onArrange}>
          <span class="label">Arrange panel</span>
          <span class="secondary"><Icons name="chevron-right" size={10} /></span>
        </button>
      </div>
    </div>

    {@render title("Providers")}
    <div class="group">
      {#each orderedProviders(snap) as p (p)}
        <div class="item row tight">
          <button class="row link open" onclick={() => (provider = p)} aria-label="{PROVIDER_NAME[p]} settings">
            <Glyph provider={p} size={12} />
            <span>{PROVIDER_NAME[p]}</span>
            <span class="plan secondary">{plan(p)}</span>
            <span class="grow"></span>
          </button>
          <button class="sw" role="switch" aria-checked={showsInPanel(s, p)} aria-label="Show {PROVIDER_NAME[p]} in panel" use:tip={"Show in panel"} onclick={() => commit(setShowsInPanel(s, p, !showsInPanel(s, p)))}>
            <Switch on={showsInPanel(s, p)} />
          </button>
          <button class="chev secondary" aria-label="{PROVIDER_NAME[p]} settings" onclick={() => (provider = p)}><Icons name="chevron-right" size={10} /></button>
        </div>
      {/each}
    </div>

    {@render title("Taskbar")}
    <div class="group">
      <div class="item"><ToggleRow label="Tray icon instead of widget" checked={s.trayOnly} onChange={(on) => commit(setTrayOnly(s, on))} /></div>
      <!-- The tray icon shows no numbers, so what the widget shows only matters without it. -->
      {#each s.trayOnly ? [] : snap.connected as p (p)}
        {@const win = windowOptions(p, widgetWindow(s, p))}
        <div class="item row tight">
          <button class="row link open" tabindex="-1" aria-hidden="true" onclick={() => commit(setShowsInWidget(s, p, !showsInWidget(s, p)))}>
            <Glyph provider={p} size={12} />
            <span>{PROVIDER_NAME[p]}</span>
            <span class="grow"></span>
          </button>
          {#if win}
            <Select label="{PROVIDER_NAME[p]} taskbar limit" value={win.value} options={win.options} onChange={(id) => commit(setWidgetWindow(s, p, id))} />
          {/if}
          <button class="sw" role="switch" aria-checked={showsInWidget(s, p)} aria-label="Show {PROVIDER_NAME[p]} in taskbar" onclick={() => commit(setShowsInWidget(s, p, !showsInWidget(s, p)))}>
            <Switch on={showsInWidget(s, p)} />
          </button>
        </div>
      {/each}
    </div>

    <div class="group">
      <div class="item">
        <button class="row link" onclick={() => (pickingTheme = true)}>
          <span class="label">Theme</span>
          <span class="secondary">{snap.theme.title}</span>
          <span class="secondary"><Icons name="chevron-right" size={10} /></span>
        </button>
      </div>
    </div>

    {@render title("Shelf")}
    <div class="group">
      <div class="item row">
        <span class="label">Keep screenshots</span>
        <Select label="Keep screenshots" value={String(s.shelfRetentionDays)} options={KEEP} onChange={(id) => commit(setShelfRetentionDays(s, Number(id)))} />
      </div>
    </div>

    <div class="group">
      <div class="item"><ToggleRow label="Launch at login" checked={snap.launchAtLogin} onChange={onLaunch} /></div>
    </div>

    <div class="bottom">
      <button class="quit" onclick={onQuit}>Quit Burn</button>
      {#if snap.version !== "0.0.0"}<span class="secondary">Burn {snap.version}</span>{/if}
    </div>
  {/if}
</div>

<style>
  .settings {
    display: flex;
    flex-direction: column;
    gap: var(--gap);
    font-size: 12px;
  }
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
  h2 {
    margin-top: 6px;
    padding-left: 4px;
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--secondary);
  }
  .group {
    padding: 0 12px;
    border-radius: var(--radius);
    background: var(--neutral);
  }
  .item + .item {
    border-top: 0.5px solid color-mix(in srgb, var(--text) 10%, transparent);
  }
  .row {
    display: flex;
    align-items: center;
    gap: 8px;
    min-height: 40px;
  }
  .row.tight {
    gap: 4px;
  }
  .label {
    flex: 1;
    min-width: 0;
  }
  .secondary {
    color: var(--secondary);
  }
  .link {
    width: 100%;
    text-align: left;
  }
  .open {
    flex: 1;
    min-width: 0;
    width: auto;
  }
  .plan {
    font-size: 11px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .grow {
    flex: 1;
  }
  .sw,
  .chev {
    display: grid;
    place-items: center;
    flex: none;
    height: 40px;
  }
  .sw {
    width: 42px;
  }
  .chev {
    width: 24px;
  }
  .swatches {
    display: flex;
  }
  .swatch {
    display: grid;
    place-items: center;
    width: 28px;
    height: 40px;
  }
  .dot {
    display: grid;
    place-items: center;
    width: 18px;
    height: 18px;
    border-radius: 50%;
    box-shadow: inset 0 0 0 0.5px var(--hairline);
    transition: box-shadow 150ms ease-out;
  }
  .swatch.on .dot {
    box-shadow:
      0 0 0 2px var(--neutral),
      0 0 0 3.5px color-mix(in srgb, var(--text) 50%, transparent);
  }
  .note {
    padding: 0 4px;
    font-size: 11px;
    color: var(--secondary);
  }
  .bottom {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 4px;
    font-size: 11px;
  }
  .quit {
    min-height: 40px;
    padding-right: 12px;
    color: var(--secondary);
    transition: color 150ms ease-out;
  }
  .quit:hover {
    color: var(--text);
  }
</style>
