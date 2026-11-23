<script lang="ts">
  import type { ProviderId } from "../types";
  import claude from "./claude.svg?raw";
  import openai from "./openai.svg?raw";
  import cursor from "./cursor.svg?raw";
  import antigravity from "./antigravity.svg?raw";

  let { provider, size = 12 }: { provider: ProviderId; size?: number } = $props();

  const svgs: Record<ProviderId, string> = { claude, codex: openai, cursor, antigravity };
  // Simple Icons logos (CC0); recolored with the text color.
  const markup = $derived(svgs[provider].replace("<svg", `<svg fill="currentColor" width="${size}" height="${size}" aria-hidden="true"`));
</script>

<span class="glyph" style:width="{size}px" style:height="{size}px">{@html markup}</span>

<style>
  .glyph {
    display: inline-flex;
    flex: none;
  }
  .glyph :global(svg) {
    display: block;
  }
</style>
