<!-- What the period's usage would have cost at API prices, on the accent block. -->
<script lang="ts">
  import { bucketLabel, money, tokens } from "../format";
  import { tip } from "../tip.svelte";
  import { PERIODS, PERIOD_TITLE, PROVIDERS, PROVIDER_NAME, type Period, type UsageSummary } from "../types";
  import BlockArt from "./BlockArt.svelte";
  import Pulse from "./Pulse.svelte";
  import Segmented from "./Segmented.svelte";
  import SpendBars from "./SpendBars.svelte";

  let {
    usage,
    error,
    period,
    onPeriod,
  }: { usage: UsageSummary | null; error: string | null; period: Period; onPeriod: (p: Period) => void } = $props();

  const split = $derived(
    usage ? PROVIDERS.filter((p) => (usage.byProvider[p] ?? 0) > 0).map((p) => `${PROVIDER_NAME[p]} ${money(usage.byProvider[p]!)}`) : [],
  );
</script>

<div class="block spend">
  <BlockArt fill="accent" />
  <div class="top">
    <span class="title" use:tip={"Estimated at API list prices"}>Spent</span>
    <Segmented options={PERIODS} selected={period} label={(p) => PERIOD_TITLE[p]} onSelect={onPeriod} ariaLabel="Period" />
  </div>
  {#if usage}
    <div class="sum">
      <span class="money tabular">{money(usage.cost)}</span>
      <span class="tokens">{tokens(usage.tokens)} tokens</span>
    </div>
    {#if split.length > 1}
      <div class="split tabular">{split.join(" · ")}</div>
    {/if}
    {#key usage.period}
      <div class="chart"><SpendBars {usage} /></div>
    {/key}
    <div class="axis">
      <span>{bucketLabel(usage.buckets[0]?.start, usage.unit)}</span>
      <span>{usage.period === "today" ? "now" : bucketLabel(usage.buckets.at(-1)?.start, usage.unit)}</span>
    </div>
  {:else if error}
    <div class="error">{error}</div>
  {:else}
    <Pulse>
      <span class="skel" style:width="120px" style:height="34px" style:margin-top="10px" style:opacity="0.14"></span>
      <span class="skel" style:width="100%" style:height="38px" style:margin-top="10px"></span>
    </Pulse>
  {/if}
</div>

<style>
  .spend {
    background: var(--accent);
    color: var(--accent-ink);
  }
  .top {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .title {
    font-weight: 700;
    font-size: 12px;
  }
  .sum {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    margin-top: 8px;
  }
  .money {
    font-family: var(--font-display);
    font-weight: 800;
    font-size: 40px;
    letter-spacing: -1.2px;
    line-height: 1;
  }
  .tokens,
  .split {
    font-size: 11px;
    opacity: 0.7;
  }
  .split {
    margin-top: 2px;
  }
  .chart {
    margin-top: 10px;
  }
  .axis {
    display: flex;
    justify-content: space-between;
    font-size: 10px;
    opacity: 0.55;
    margin-top: 4px;
  }
  .error {
    font-size: 11px;
    opacity: 0.7;
    margin-top: 10px;
  }
  .skel {
    display: block;
    border-radius: var(--pill);
    background: currentColor;
    opacity: 0.1;
  }
</style>
