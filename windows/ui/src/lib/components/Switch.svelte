<!-- The look of a switch; the button around it does the toggling. -->
<script lang="ts">
  let { on }: { on: boolean } = $props();
</script>

<span class="switch" class:on><span class="knob"></span></span>

<style>
  .switch {
    position: relative;
    display: block;
    flex: none;
    width: 30px;
    height: 18px;
    border-radius: var(--pill);
    background: color-mix(in srgb, var(--text) 18%, transparent);
    transition: background 150ms ease-out;
  }
  .switch.on {
    background: var(--text);
  }
  .knob {
    position: absolute;
    top: 2px;
    left: 2px;
    width: 14px;
    height: 14px;
    border-radius: var(--pill);
    background: var(--raised);
    box-shadow: 0 1px 2px var(--shadow);
    transition:
      transform 180ms var(--ease-out),
      background 150ms ease-out;
  }
  @media (prefers-color-scheme: dark) {
    /* The raised fill would vanish into the dark track. */
    .knob {
      background: var(--secondary);
    }
  }
  .on .knob {
    transform: translateX(12px);
    background: var(--base);
  }
</style>
