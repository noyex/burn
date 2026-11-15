<!-- A native dropdown dressed as a pill: closes on outside click and Escape, works with the keyboard. -->
<script lang="ts">
  let {
    value,
    options,
    label,
    onChange,
  }: { value: string; options: { id: string; label: string }[]; label: string; onChange: (id: string) => void } = $props();
</script>

<span class="select">
  <select aria-label={label} {value} onchange={(e) => onChange(e.currentTarget.value)}>
    {#each options as o (o.id)}
      <option value={o.id} selected={o.id === value}>{o.label}</option>
    {/each}
  </select>
  <svg width="8" height="8" viewBox="0 0 8 8" aria-hidden="true"><path d="m1 2.8 3 3 3-3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
</span>

<style>
  .select {
    position: relative;
    display: inline-flex;
    align-items: center;
    flex: none;
    color: var(--secondary);
  }
  select {
    appearance: none;
    height: 30px;
    padding: 0 26px 0 12px;
    border: 0;
    border-radius: 999px;
    background: color-mix(in srgb, var(--text) 6%, transparent);
    color: var(--text);
    font: inherit;
    font-size: 11px;
    cursor: pointer;
    transition: background 150ms ease-out;
  }
  /* The open list is drawn natively: give it the theme's colours, or dark mode puts light text
     on the default white popup. */
  option {
    background: var(--raised);
    color: var(--text);
  }
  select:hover {
    background: color-mix(in srgb, var(--text) 10%, transparent);
  }
  select:focus-visible {
    outline: 2px solid var(--text);
    outline-offset: 2px;
  }
  svg {
    position: absolute;
    right: 11px;
    pointer-events: none;
  }
</style>
