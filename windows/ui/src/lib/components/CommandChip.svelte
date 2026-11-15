<!-- A shell command in monospace that copies itself. -->
<script lang="ts">
  import { tip } from "../tip.svelte";
  import Icons from "./Icons.svelte";

  let { command }: { command: string } = $props();
  let copied = $state(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(command);
      copied = true;
      setTimeout(() => (copied = false), 1500);
    } catch {
      // Clipboard denied: nothing to confirm.
    }
  }
</script>

<button class="chip" onclick={copy} use:tip={copied ? "Copied" : "Copy"} aria-label="Copy {command}">
  <code>{command}</code>
  <span class="icon">
    {#if copied}<Icons name="check" size={10} />{:else}<svg width="10" height="10" viewBox="0 0 16 16" aria-hidden="true"
        ><rect x="5" y="5" width="9" height="9" rx="2" fill="none" stroke="currentColor" stroke-width="1.6" /><path
          d="M3.5 11H3a1 1 0 0 1-1-1V3a1 1 0 0 1 1-1h7a1 1 0 0 1 1 1v.5"
          fill="none"
          stroke="currentColor"
          stroke-width="1.6"
        /></svg
      >{/if}
  </span>
</button>

<style>
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    height: 22px;
    padding: 0 7px;
    border-radius: var(--pill);
    background: color-mix(in srgb, var(--text) 7%, transparent);
    transition: background 150ms ease-out;
  }
  .chip:hover {
    background: color-mix(in srgb, var(--text) 12%, transparent);
  }
  code {
    font-family: "Cascadia Mono", Consolas, ui-monospace, monospace;
    font-size: 11px;
  }
  .icon {
    display: inline-flex;
    width: 12px;
    color: var(--secondary);
  }
</style>
