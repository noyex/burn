<!-- A provider that can't show limits: signed out, or failing with nothing cached. -->
<script lang="ts">
  import { LOGIN_COMMAND, PROVIDER_NAME, type LimitState, type ProviderId } from "../types";
  import { tip } from "../tip.svelte";
  import BlockArt from "./BlockArt.svelte";
  import CommandChip from "./CommandChip.svelte";
  import Glyph from "./Glyph.svelte";

  let { provider, state }: { provider: ProviderId; state: LimitState } = $props();
</script>

<div class="block row">
  <BlockArt fill="neutral" />
  <Glyph {provider} size={12} />
  <span class="name">{PROVIDER_NAME[provider]}</span>
  <span class="spacer"></span>
  {#if state.state === "signedOut"}
    <span use:tip={"Signed out. Sign in again in a terminal"}><CommandChip command={LOGIN_COMMAND[provider]} /></span>
  {:else if state.state === "failed"}
    <span class="message">{state.message}</span>
  {/if}
</div>

<style>
  .row {
    display: flex;
    align-items: center;
    gap: 6px;
    min-height: 46px;
    padding: 10px;
    background: var(--neutral);
  }
  .name {
    font-weight: 700;
  }
  .spacer {
    flex: 1;
    min-width: 6px;
  }
  .message {
    font-size: 11px;
    color: var(--secondary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
</style>
