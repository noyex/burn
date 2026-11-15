<!--
  What the theme draws on a block over its fill (BlockDecoration.swift): a gradient, then an
  image, then a pattern. First child of a `.block`; renders nothing in the built-in look.
-->
<script lang="ts">
  import { gradientCss, imageCss, patternCss, theme } from "../theme.svelte";

  /** Token of the block's fill: `accent`, `neutral`, `surface` or a card color. */
  let { fill }: { fill: string } = $props();

  const art = $derived(theme.backgrounds[fill]);
  const image = $derived(art?.image ? imageCss(art.image) : null);
  const pattern = $derived(art?.pattern ? patternCss(art.pattern) : null);
</script>

{#if art}
  <div class="art" aria-hidden="true">
    {#if art.gradient}<div class="layer" style:background-image={gradientCss(art.gradient)}></div>{/if}
    {#if art.image && image}<div class="layer picture" style:background-image={image} style:opacity={art.image.opacity}></div>{/if}
    {#if art.pattern && pattern}
      <div
        class="layer"
        class:fade-top={art.pattern.fade === "top"}
        class:fade-bottom={art.pattern.fade === "bottom"}
        style:background-image={pattern.image}
        style:background-size={pattern.size}
        style:opacity={art.pattern.opacity}
      ></div>
    {/if}
  </div>
{/if}

<style>
  /* Under the block's content, over its fill; `.block` isolates the stacking. */
  .art {
    position: absolute;
    inset: 0;
    z-index: -1;
    border-radius: inherit;
    overflow: hidden;
    pointer-events: none;
  }
  /* The block's own hairline sits under the art, so it is drawn again on top. */
  .art::after {
    content: "";
    position: absolute;
    inset: 0;
    border-radius: inherit;
    box-shadow: inset 0 0 0 0.5px var(--hairline);
  }
  .layer {
    position: absolute;
    inset: 0;
  }
  .picture {
    background-position: center;
    background-size: cover;
    background-repeat: no-repeat;
  }
  .fade-top {
    mask-image: linear-gradient(to bottom, transparent, var(--mask));
  }
  .fade-bottom {
    mask-image: linear-gradient(to bottom, var(--mask), transparent);
  }
</style>
