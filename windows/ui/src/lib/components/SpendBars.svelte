<!-- Stacked cost bars per bucket, one shade of the ink per provider; grows in from the baseline. -->
<script lang="ts">
  import { bucketLabel, bucketTitle, money } from "../format";
  import { showTip } from "../tip.svelte";
  import { PROVIDERS, PROVIDER_NAME, type ProviderId, type UsageBucket, type UsageSummary } from "../types";

  let { usage, animated = true }: { usage: UsageSummary; animated?: boolean } = $props();

  const SHADES: Record<ProviderId, number> = { claude: 1, antigravity: 0.7, codex: 0.45, cursor: 0.25 };
  const STACK = [...PROVIDERS].reverse();
  const HEIGHT = 38;

  const total = (b: UsageBucket) => PROVIDERS.reduce((s, p) => s + (b.cost[p] ?? 0), 0);
  const peak = $derived(Math.max(...usage.buckets.map(total), Number.MIN_VALUE));

  let width = $state(272);
  const slot = $derived(width / Math.max(usage.buckets.length, 1));
  const spacing = $derived(slot > 6 ? 2 : slot > 3 ? 1 : 0);
  let hovered = $state<number | null>(null);

  function tipText(b: UsageBucket): string {
    const split = PROVIDERS.filter((p) => (b.cost[p] ?? 0) > 0).map((p) => `${PROVIDER_NAME[p]} ${money(b.cost[p]!)}`);
    const cost = split.length > 1 ? [money(total(b)), ...split].join(" · ") : money(total(b));
    return `${bucketTitle(b.start, usage.unit)}\n${cost}`;
  }

  function onMove(e: PointerEvent, el: HTMLElement) {
    const r = el.getBoundingClientRect();
    const i = Math.min(Math.max(Math.floor((e.clientX - r.left) / slot), 0), usage.buckets.length - 1);
    if (i === hovered) return;
    hovered = i;
    const col = el.children[i] as HTMLElement | undefined;
    showTip(tipText(usage.buckets[i]), col?.getBoundingClientRect() ?? null);
  }

  function onLeave() {
    hovered = null;
    showTip(null, null);
  }

  const peakBucket = $derived(usage.buckets.reduce<UsageBucket | null>((m, b) => (m == null || total(b) > total(m) ? b : m), null));
  const description = $derived(
    peakBucket && total(peakBucket) > 0 ? `Peak ${money(total(peakBucket))} on ${bucketLabel(peakBucket.start, usage.unit)}` : "No usage",
  );
</script>

<div
  class="bars"
  class:animated
  style:gap="{spacing}px"
  bind:clientWidth={width}
  role="img"
  aria-label="Cost per {usage.unit}. {description}"
  onpointermove={(e) => onMove(e, e.currentTarget)}
  onpointerleave={onLeave}
>
  {#each usage.buckets as b, i (b.start)}
    <div class="col" class:dim={hovered != null && hovered !== i}>
      <div class="stack">
        {#each STACK as p (p)}
          {#if (b.cost[p] ?? 0) > 0}
            <div class="seg" style:height="{Math.max(1, (HEIGHT * (b.cost[p] ?? 0)) / peak)}px" style:opacity={SHADES[p]}></div>
          {/if}
        {/each}
        {#if total(b) === 0}
          <div class="seg" style:height="1px" style:opacity="0.15"></div>
        {/if}
      </div>
    </div>
  {/each}
</div>

<style>
  .bars {
    display: flex;
    align-items: flex-end;
    height: 38px;
    transform-origin: bottom;
  }
  .bars.animated {
    animation: grow 400ms var(--ease-out) both;
  }
  @keyframes grow {
    from {
      transform: scaleY(0.02);
    }
  }
  .col {
    flex: 1;
    height: 100%;
    display: flex;
    align-items: flex-end;
    transition: opacity 150ms ease-out;
  }
  .col.dim {
    opacity: 0.45;
  }
  .stack {
    width: 100%;
    display: flex;
    flex-direction: column;
    border-radius: 1.5px 1.5px 0 0;
    overflow: hidden;
  }
  .seg {
    background: currentColor;
  }
</style>
