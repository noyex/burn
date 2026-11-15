<!-- The panel (PopoverView.swift): provider cards, spend, and a footer, floating over the desktop. -->
<script lang="ts">
  import { onMount } from "svelte";
  import { contentResized, getState, hidePanel, onPanel, onState, setPeriod, shelfCopy, shelfDelete } from "./lib/api";
  import { clock } from "./lib/clock.svelte";
  import { demoUsage } from "./lib/demo";
  import { synced } from "./lib/format";
  import { customSize, hasCard, order, panelProviders, rows as arrange, sizes } from "./lib/layout";
  import { pageIn, pageOut, reducedMotion } from "./lib/motion";
  import { cubicOut } from "svelte/easing";
  import { scale } from "svelte/transition";
  import { holdToEdit } from "./lib/press";
  import { reorder, setCardSize, setShelfExpanded, setShowsInPanel, setShowsSpending, setTab } from "./lib/settings";
  import { LOGIN_COMMAND, PROVIDERS, PROVIDER_NAME, type CardSize, type Period, type ProviderId, type Settings, type ShelfItem, type Snapshot, type Tab } from "./lib/types";
  import CardGrid from "./lib/components/CardGrid.svelte";
  import CommandChip from "./lib/components/CommandChip.svelte";
  import EditChrome from "./lib/components/EditChrome.svelte";
  import Glyph from "./lib/components/Glyph.svelte";
  import Icons from "./lib/components/Icons.svelte";
  import IssueRow from "./lib/components/IssueRow.svelte";
  import RoundButton from "./lib/components/RoundButton.svelte";
  import ShareButton from "./lib/components/ShareButton.svelte";
  import ShelfGrid from "./lib/components/ShelfGrid.svelte";
  import SettingsView from "./lib/components/SettingsView.svelte";
  import SpendBlock from "./lib/components/SpendBlock.svelte";
  import TabSwitcher from "./lib/components/TabSwitcher.svelte";
  import Tip from "./lib/components/Tip.svelte";
  import { tip } from "./lib/tip.svelte";
  import { installUpdate, isTauri, quit, setLaunchAtLogin, setSettings } from "./lib/api";

  let snap = $state<Snapshot | null>(null);
  /** False while the panel is closed, so the content animates in on every open. */
  let visible = $state(false);
  let root: HTMLDivElement | undefined = $state();
  let view = $state<"usage" | "settings">("usage");
  /** The provider page open in settings. */
  let settingsProvider = $state<ProviderId | null>(null);
  let editing = $state(false);
  /** Paths of the selected screenshots. */
  let selection = $state<string[]>([]);
  let confirmingClear = $state(false);
  let copiedSelection = $state(false);
  let clearTimer: ReturnType<typeof setTimeout> | undefined;
  let copiedTimer: ReturnType<typeof setTimeout> | undefined;

  const USAGE_WIDTH = 304;
  const EXPANDED_WIDTH = 644;
  const tab = $derived(snap?.settings.tab ?? "usage");
  const expanded = $derived(snap?.settings.shelfExpanded ?? false);
  /** Doesn't depend on the tab, so the shelf keeps its grid while it fades out. */
  const shelfWidth = $derived(expanded ? EXPANDED_WIDTH : USAGE_WIDTH);
  const contentWidth = $derived(view === "usage" && tab === "shelf" ? shelfWidth : USAGE_WIDTH);
  const usageRow = $derived(tab === "usage" && !editing);
  const shelfRow = $derived(tab === "shelf");
  const editRow = $derived(tab === "usage" && editing);
  const selectedItems = $derived<ShelfItem[]>(snap ? snap.shelf.filter((i) => selection.includes(i.path)) : []);

  const shown = $derived(snap ? panelProviders(snap) : []);
  const cards = $derived(snap ? shown.filter((p) => hasCard(snap!, p)) : []);
  const issues = $derived(shown.filter((p) => !cards.includes(p)));
  const sizeOf = $derived(snap ? sizes(snap.settings.panelLayout, cards, (p) => customSize(snap!, p)) : new Map());
  const cardRows = $derived(arrange(cards, sizeOf));
  const spendShown = $derived(snap != null && snap.settings.showsSpending && (snap.hasUsage || snap.importPercent != null));

  /** Hidden providers that are signed in, and whether the Spent block is hidden: what "+" brings back. */
  const hiddenProviders = $derived(snap ? order(snap.settings.providerOrder).filter((p) => snap!.connected.includes(p) && snap!.settings.panelHidden.includes(p)) : []);
  const panelEmpty = $derived(snap != null && snap.connected.length > 0 && shown.length === 0 && !spendShown);

  /** Shows the change right away, then hands the whole settings object to the app. */
  function commit(next: Settings) {
    if (!snap) return;
    snap.settings = next;
    setSettings(next);
  }

  function launchAtLogin(on: boolean) {
    if (!snap) return;
    snap.launchAtLogin = on;
    setLaunchAtLogin(on);
  }

  const startEditing = () => {
    if (snap && snap.settings.tab !== "usage") commit(setTab(snap.settings, "usage"));
    view = "usage";
    editing = true;
  };

  function chooseTab(t: Tab) {
    if (!snap || snap.settings.tab === t) return;
    // Editing only exists on the usage page.
    editing = false;
    commit(setTab(snap.settings, t));
  }

  // Pruned or cleared screenshots must not stay selected.
  $effect(() => {
    if (!snap) return;
    const paths = new Set(snap.shelf.map((i) => i.path));
    if (selection.some((p) => !paths.has(p))) selection = selection.filter((p) => paths.has(p));
  });

  const toggle = (path: string) => (selection = selection.includes(path) ? selection.filter((p) => p !== path) : [...selection, path]);

  function removeShelf(paths?: string[]) {
    if (!snap) return;
    snap.shelf = paths ? snap.shelf.filter((i) => !paths.includes(i.path)) : [];
    shelfDelete(paths);
  }

  function clearAll() {
    if (!confirmingClear) {
      confirmingClear = true;
      clearTimeout(clearTimer);
      clearTimer = setTimeout(() => (confirmingClear = false), 3000);
      return;
    }
    clearTimeout(clearTimer);
    confirmingClear = false;
    removeShelf();
  }

  async function copySelection() {
    if (!(await shelfCopy(selectedItems.map((i) => i.path)))) return;
    copiedSelection = true;
    clearTimeout(copiedTimer);
    copiedTimer = setTimeout(() => (copiedSelection = false), 1200);
  }

  const copyOne = (item: ShelfItem) => shelfCopy([item.path]);

  const pop = (node: Element) => {
    const reduced = reducedMotion();
    return scale(node, { start: 0.8, duration: reduced ? 0 : 180, easing: cubicOut });
  };
  const stopEditing = () => (editing = false);

  function choosePeriod(p: Period) {
    if (!snap) return;
    snap.period = p;
    if (isTauri) setPeriod(p);
    else snap.usage = demoUsage(p);
  }

  onMount(() => {
    let cancelled = false;
    (async () => {
      // Labels are measured (segmented control, panel size): wait for the brand font first.
      await document.fonts.ready;
      const first = await getState();
      if (cancelled) return;
      snap = first;
      await onState((s) => (snap = s));
      await onPanel(
        () => {
          clock.now = Date.now();
          visible = false;
          requestAnimationFrame(() => requestAnimationFrame(() => (visible = true)));
        },
        () => {
          visible = false;
          // The panel opens on the usage page again, never in the middle of editing.
          editing = false;
          view = "usage";
          settingsProvider = null;
          selection = [];
          confirmingClear = false;
        },
      );
      // Development aid for screenshots: `#settings`, `#settings/claude` or `#edit` opens there.
      const [start, provider] = location.hash.slice(1).split("/");
      if (start === "settings") {
        view = "settings";
        settingsProvider = (provider as ProviderId) || null;
      } else if (start === "edit") editing = true;
      else if (start === "shelf") snap.settings = setTab(snap.settings, "shelf");
    })();

    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        if (editing) editing = false;
        else hidePanel();
      } else if (e.key === "Enter" && editing && !(e.target as Element).closest("button, select, [data-card]")) {
        editing = false;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => {
      cancelled = true;
      clearTimeout(clearTimer);
      clearTimeout(copiedTimer);
      window.removeEventListener("keydown", onKey);
    };
  });

  // The window is sized to the content, so it never covers more of the desktop than it shows.
  $effect(() => {
    if (!root) return;
    const el = root;
    const observer = new ResizeObserver(() => contentResized(el.offsetWidth, el.offsetHeight));
    observer.observe(el);
    return () => observer.disconnect();
  });
</script>

<div class="root" bind:this={root}>
  {#if snap}
    <div class="content" class:visible style:width="{contentWidth}px">
      <div class="stage">
        {#if view === "settings"}
          <div class="page" in:pageIn out:pageOut>
            <div class="block settings">
              <SettingsView
                {snap}
                bind:provider={settingsProvider}
                {commit}
                onLaunch={launchAtLogin}
                onBack={() => (view = "usage")}
                onArrange={startEditing}
                onQuit={quit}
              />
            </div>
          </div>
        {:else}
          <div class="page" in:pageIn out:pageOut>
            <div class="top">
              <TabSwitcher selected={tab} onSelect={chooseTab} />
              {#if tab === "shelf"}
                <div class="expand" transition:pop>
                  <RoundButton
                    floating
                    size={36}
                    icon={expanded ? "collapse" : "expand"}
                    label={expanded ? "Make shelf smaller" : "Make shelf bigger"}
                    onclick={() => commit(setShelfExpanded(snap!.settings, !expanded))}
                  />
                </div>
              {/if}
            </div>

            <div class="stage">
              {#if tab === "usage"}
                <div class="page" in:pageIn out:pageOut>
                {#if snap.connected.length === 0}
                  <div class="block neutral reveal" style:--i={0}>
                    <p class="hint">Sign in to a provider in a terminal:</p>
                    {#each PROVIDERS as p (p)}
                      <div class="signin-row"><Glyph provider={p} size={12} /><CommandChip command={LOGIN_COMMAND[p]} /></div>
                    {/each}
                  </div>
                {:else}
                  <CardGrid
                    {snap}
                    {cards}
                    rows={cardRows}
                    {sizeOf}
                    {editing}
                    onEdit={startEditing}
                    onHide={(p) => commit(setShowsInPanel(snap!.settings, p, false))}
                    onSize={(p, size: CardSize) => commit(setCardSize(snap!.settings, p, size, cards))}
                    onReorder={(next) => commit(reorder(snap!.settings, next))}
                  />
                  {#each issues as p (p)}
                    <div class="reveal" style:--i={cardRows.length} use:holdToEdit={editing ? null : startEditing}>
                      <EditChrome {editing} title={PROVIDER_NAME[p]} seed={PROVIDERS.indexOf(p) * 1.9} onHide={() => commit(setShowsInPanel(snap!.settings, p, false))}>
                        <IssueRow provider={p} state={snap.limits[p] ?? { state: "loading" }} />
                      </EditChrome>
                    </div>
                  {/each}
                {/if}

                {#if spendShown}
                  <div class="reveal" style:--i={cardRows.length + 1} use:holdToEdit={editing ? null : startEditing}>
                    <EditChrome {editing} title="Spent" seed={5.3} onHide={() => commit(setShowsSpending(snap!.settings, false))}>
                      {#if snap.hasUsage}
                        <SpendBlock usage={snap.usage} error={snap.usageError} period={snap.period} onPeriod={choosePeriod} />
                      {:else}
                        <div class="block importing">
                          <span>Importing usage from Claude Code and Codex logs…</span>
                          <div class="progress"><div style:width="{snap.importPercent ?? 0}%"></div></div>
                        </div>
                      {/if}
                    </EditChrome>
                  </div>
                {/if}

                {#if editing && (hiddenProviders.length > 0 || !snap.settings.showsSpending)}
                  <div class="hidden-list">
                    {#each hiddenProviders as p (p)}
                      <button class="add" aria-label="Show {PROVIDER_NAME[p]}" onclick={() => commit(setShowsInPanel(snap!.settings, p, true))}>
                        <Icons name="plus" size={9} />{PROVIDER_NAME[p]}
                      </button>
                    {/each}
                    {#if !snap.settings.showsSpending}
                      <button class="add" aria-label="Show Spent" onclick={() => commit(setShowsSpending(snap!.settings, true))}>
                        <Icons name="plus" size={9} />Spent
                      </button>
                    {/if}
                  </div>
                {:else if !editing && panelEmpty}
                  <div class="block neutral empty reveal" style:--i={0}>
                    <p class="hint">Everything is hidden from the panel</p>
                    <button class="pill-button prominent" onclick={startEditing}>Edit panel</button>
                  </div>
                {/if}
                </div>
              {:else}
                <div class="page" in:pageIn out:pageOut>
                  <ShelfGrid
                    items={snap.shelf}
                    width={shelfWidth}
                    columns={expanded ? 4 : 2}
                    maxHeight={expanded ? 560 : 380}
                    {selection}
                    onToggle={toggle}
                    onCopy={copyOne}
                  />
                </div>
              {/if}
            </div>

          {#snippet trailing(updateShown: boolean)}
            {#if snap!.update && updateShown}
              <button class="pill-button prominent" disabled={snap!.updating} onclick={installUpdate} use:tip={`Update to Burn ${snap!.update}`}>
                {snap!.updating ? "Updating…" : "Update"}
              </button>
            {/if}
            <RoundButton icon="gear" label="Settings" onclick={() => (view = "settings")} />
          {/snippet}

            <footer class="footer reveal" style:--i={cardRows.length + 2}>
              <div class="row-in" class:off={!usageRow} inert={!usageRow}>
                <span class="status grow" class:hidden={!snap.hasUsage}>{snap.syncing ? "Syncing…" : synced(snap.lastSync, clock.now)}</span>
                {#if snap.usage && snap.usage.cost > 0}<ShareButton period={snap.period} />{/if}
                {@render trailing(true)}
              </div>
              <div class="row-in" class:off={!shelfRow} inert={!shelfRow}>
                <span class="status grow">{selection.length > 0 ? `${selection.length} selected` : ""}</span>
                {#if selection.length > 0}
                  <button class="pill-button" onclick={() => (selection = [])}>Deselect</button>
                  <button class="pill-button prominent copy" onclick={copySelection}>{copiedSelection ? "Copied" : `Copy ${selection.length}`}</button>
                {:else if snap.shelf.length > 0}
                  <button class="pill-button" class:destructive={confirmingClear} onclick={clearAll}>{confirmingClear ? "Clear all?" : "Clear"}</button>
                {/if}
                <!-- Kept out of the way while screenshots are selected; the footer is full then. -->
                {@render trailing(selection.length === 0)}
              </div>
              <div class="row-in" class:off={!editRow} inert={!editRow}>
                <span class="status grow">Drag to reorder</span>
                <button class="pill-button prominent" onclick={stopEditing}>Done</button>
              </div>
            </footer>
          </div>
        {/if}
      </div>
    </div>
  {/if}
  <Tip />
</div>

<style>
  /* Room around the blocks for their shadows (Bento.shadowInset), and on top for the edit chrome's hide buttons. */
  .root {
    width: fit-content;
    min-width: 332px;
    padding: 12px 14px 18px;
  }
  .content {
    display: flex;
    flex-direction: column;
    gap: var(--gap);
    transform-origin: bottom center;
    transform: scale(0.96);
    opacity: 0;
  }
  .content.visible {
    transform: none;
    opacity: 1;
    transition:
      transform 200ms var(--ease-out),
      opacity 200ms var(--ease-out);
  }
  /* Blocks fade and lift in, staggered (Bento.swift `Reveal`). Only on the way in. */
  .stage {
    position: relative;
  }
  .page {
    display: flex;
    flex-direction: column;
    gap: var(--gap);
  }
  .settings {
    background: var(--surface);
  }
  /* Above the shelf's scroll area, which reaches a little past the grid for shadows. */
  .top {
    position: relative;
    z-index: 1;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding-bottom: 2px;
  }
  :global(.reveal) {
    opacity: 0;
    transform: translateY(6px);
  }
  .visible :global(.reveal) {
    opacity: 1;
    transform: none;
    transition:
      opacity 220ms var(--ease-out),
      transform 220ms var(--ease-out);
    transition-delay: calc(var(--i, 0) * 30ms);
  }
  .empty {
    align-items: center;
    padding: 18px 12px;
  }
  .hidden-list {
    display: flex;
    flex-wrap: wrap;
    gap: var(--gap);
    animation: fade-in 180ms var(--ease-out);
  }
  .add {
    position: relative;
    display: inline-flex;
    align-items: center;
    gap: 5px;
    height: 32px;
    padding: 0 12px;
    border-radius: var(--pill);
    background: var(--surface);
    font-size: 12px;
    font-weight: 700;
    box-shadow:
      0 4px 20px var(--shadow),
      inset 0 0 0 0.5px var(--hairline);
    transition: transform 120ms ease-out;
  }
  .add::after {
    content: "";
    position: absolute;
    inset: -4px -2px;
  }
  .add:active {
    transform: scale(0.97);
  }
  @keyframes fade-in {
    from {
      opacity: 0;
    }
  }
  .neutral {
    background: var(--neutral);
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .hint {
    color: var(--secondary);
  }
  .signin-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .importing {
    background: var(--accent);
    color: var(--accent-ink);
    font-size: 11px;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .progress {
    height: 4px;
    border-radius: 2px;
    background: color-mix(in srgb, var(--accent-ink) 15%, transparent);
    overflow: hidden;
  }
  .progress div {
    height: 100%;
    background: var(--accent-ink);
    transition: width 300ms var(--ease-out);
  }
  .footer {
    display: grid;
    min-height: 36px;
    margin-top: 2px;
    padding: 4px 4px 4px 12px;
    border-radius: var(--pill);
    background: var(--surface);
    box-shadow:
      0 4px 20px var(--shadow),
      inset 0 0 0 0.5px var(--hairline);
    font-size: 11px;
  }
  /* Both rows sit in the same cell and crossfade, so the footer never changes size. */
  .row-in {
    grid-area: 1 / 1;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--gap);
    transition: opacity 150ms ease-out;
  }
  .row-in.off {
    opacity: 0;
    pointer-events: none;
  }
  .status {
    color: var(--secondary);
  }
  .grow {
    flex: 1;
    min-width: 0;
  }
  .copy {
    min-width: 64px;
  }
  .status.hidden {
    opacity: 0;
  }
</style>
