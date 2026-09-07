+++
title = "Brand Kit"
description = "The gori mark, the palette behind it, and the wallpapers — with direct downloads."
weight = 40
+++

These are the files this site itself uses. Right-clicking the mark in the header
opens the logo downloads as a menu; this page adds the palette and the
wallpapers, and says which variant belongs where.

## The mark {#mark}

Three variants, each shipped as SVG, PNG and WebP. The raster files are
512 × 512; the SVGs draw on a `0 0 512 512` viewBox and scale to anything.

<div class="art-gallery">
  <figure>
    <img src="/images/gori.png" alt="The gori mark: two interlocking rings drawn as a single ribbon, in flat brand gold">
    <figcaption><strong>Mark</strong> — flat <code>#d9c28b</code><br>
      <a href="/images/gori.svg" download="gori-logo.svg">SVG</a> ·
      <a href="/images/gori.png" download="gori-logo.png">PNG</a> ·
      <a href="/images/gori.webp" download="gori-logo.webp">WebP</a></figcaption>
  </figure>
  <figure>
    <img style="--plate:#faf9f7" src="/images/gori_dark.png" alt="The same gori mark as a solid black silhouette">
    <figcaption><strong>Mono</strong> — solid <code>#000000</code><br>
      <a href="/images/gori_dark.svg" download="gori-logo-mono.svg">SVG</a> ·
      <a href="/images/gori_dark.png" download="gori-logo-mono.png">PNG</a> ·
      <a href="/images/gori_dark.webp" download="gori-logo-mono.webp">WebP</a></figcaption>
  </figure>
  <figure>
    <img src="/images/gori_white.png" alt="The same gori mark filled with a gold-leaf gradient running from pale cream to deep bronze">
    <figcaption><strong>Gradient</strong> — gold leaf<br>
      <a href="/images/gori_white.svg" download="gori-logo-gradient.svg">SVG</a> ·
      <a href="/images/gori_white.png" download="gori-logo-gradient.png">PNG</a> ·
      <a href="/images/gori_white.webp" download="gori-logo-gradient.webp">WebP</a></figcaption>
  </figure>
</div>

| Variant | Reach for it when |
|---------|-------------------|
| **Mark** | Default. One flat gold that holds up on a light or a dark background, and survives being shrunk to a favicon |
| **Mono** | One-colour printing, a light background that already carries colour, or anywhere the gold would compete |
| **Gradient** | Large display only — a title slide, a sticker, a hero. The ramp is `#f7ecd0 → #e9d49d → #d9c28b → #8c7458`, and it turns to mud below about 96 px |

On disk the three are `gori`, `gori_dark` and `gori_white`, and the header's
download menu labels them **Mark**, **Dark** and **Color**. Note that
`gori_white` is the *gradient*, not a white knockout: the filename predates the
labels and other things point at it, so it keeps the name. There is no reversed
white-on-dark mark — on a dark background, use the flat gold.

## Colours {#colours}

<div class="swatches">
  <div class="swatch" style="--c:#d9c28b"><b aria-hidden="true"></b><span><em>Brand gold</em>#d9c28b</span></div>
  <div class="swatch" style="--c:#f7ecd0"><b aria-hidden="true"></b><span><em>Gold highlight</em>#f7ecd0</span></div>
  <div class="swatch" style="--c:#c8a860"><b aria-hidden="true"></b><span><em>Leaf gold</em>#c8a860</span></div>
  <div class="swatch" style="--c:#8a6a28"><b aria-hidden="true"></b><span><em>Deep gold</em>#8a6a28</span></div>
  <div class="swatch" style="--c:#0a0a0b"><b aria-hidden="true"></b><span><em>Ink</em>#0a0a0b</span></div>
  <div class="swatch" style="--c:#080a11"><b aria-hidden="true"></b><span><em>Indigo-black</em>#080a11</span></div>
  <div class="swatch" style="--c:#6c7eb2"><b aria-hidden="true"></b><span><em>Cloud indigo</em>#6c7eb2</span></div>
  <div class="swatch" style="--c:#faf9f7"><b aria-hidden="true"></b><span><em>Paper</em>#faf9f7</span></div>
</div>

The terminal and this site draw on one palette, so most of these values have two
homes:

| Colour | Hex | Role | Where the value lives |
|--------|-----|------|-----------------------|
| Brand gold | `#d9c28b` | The mark, and the focus ring around whatever has your attention | The fill in `gori.svg`, `focus_gold` in the `goridark` theme, and the last stop of the site's wordmark gradient — one value, three places |
| Gold highlight | `#f7ecd0` | The lit edge of the gradient mark | First stop of `gori_white.svg` |
| Leaf gold | `#c8a860` | Links, rules and accents on this site | The site's `--accent` |
| Deep gold | `#8a6a28` | The same role on a light canvas, dark enough to stay readable | `focus_gold` in `goriday`; this site uses `#a8791f` |
| Ink | `#0a0a0b` | The terminal canvas | `bg` in `goridark` |
| Indigo-black | `#080a11` | This site's canvas — the same night, a shade bluer | The site's `--bg` |
| Cloud indigo | `#6c7eb2` | The cloud and wave line-work in the wallpapers | The site's `--cloud-rgb` |
| Paper | `#faf9f7` | The light canvas, on both surfaces | `bg` in `goriday`, and the site's light `--bg` |

Only HTTP status keeps functional colour in the TUI, and that is a theme
decision rather than a brand one — the [Themes guide](/guide/themes/) covers all
thirty built-in palettes.

## Wallpaper {#wallpaper}

Ink, gold leaf and brushed cloud line-work: the painting the whole palette was
sampled from. Two cuts, at the only sizes that exist.

<div class="art-gallery">
  <figure>
    <img src="/images/gori-wallpaper.webp" alt="Dark ink-and-gold wallpaper of stylised clouds and waves, with the gold gori mark and wordmark centred">
    <figcaption><strong>With the mark</strong> — 1984 × 992<br>
      <a href="/images/gori-wallpaper.webp" download="gori-wallpaper.webp">WebP</a></figcaption>
  </figure>
  <figure>
    <img src="/images/wallpaper.webp" alt="The same ink-and-gold cloud and wave painting without any logo">
    <figcaption><strong>Plain</strong> — 1152 × 768<br>
      <a href="/images/wallpaper.webp" download="gori-wallpaper-plain.webp">WebP</a></figcaption>
  </figure>
</div>

## Using these {#usage}

gori is Apache-2.0, and that licence covers the code — not the mark. Use these
files to refer to gori: a post, a talk, a comparison table, a badge on something
that integrates with it.

Please don't restyle the mark, rebuild it from scratch, or adopt it as the mark
of your own project or product, and don't use it in a way that suggests gori
endorses something. If you are unsure, [ask](https://github.com/hahwul/gori/issues).
