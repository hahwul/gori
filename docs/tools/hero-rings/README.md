# hero-rings

Generates `templates/partials/hero-rings.html`, the crossing-rings mark in
the landing-page hero: the official art disc circled by two broad,
translucent ring bands -- the logo's pair -- each flat in its own plane,
weaving in front of and behind the planet and one another.

```
python3 tools/hero-rings/build.py
```

Each ring is authored face-on in its own "ring space" (an annulus of radii
[a, b]) and carried to the screen by one transform,
`translate * rotate(rot) * scale(1, k)` -- the exact orthographic projection
of a flat sheet seen from elevation asin(k). Change a constant in the
`RINGS` table and re-run; the emitted markup should never be edited
directly.

## Why the weave is derived

The depth of a sheet's material is linear in screen position, so for any
pair of rings "who is in front" flips across a single straight line through
the centre. Because the rings' radial ranges are disjoint, two bands can
never occupy the same 3D point, which means that line never crosses a spot
where both bands have material: every crossing's over/under order is
constant and computable. The painter's stacking, the half-plane clips, and
the crossing shadows all fall out of that geometry.

## The translucency discipline

Translucent paint cannot be split along a visible edge -- complementary
antialiased coverage composes darker than either side, a seam that cost a
full round in this hero's earlier Saturn incarnation. So nothing is ever
split where it shows:

- Each ring's base copy is one unbroken sheet behind the planet.
- Its near half is repainted in front only across the disc, clipped to a
  screen circle a hair wider than the rim (the edge hides under the rim
  stroke; the half-plane cut lies at radii the disc never reaches).
- Where ring i must come back over a later-painted ring j, the repaint is
  clipped to the safe half-plane and weighted by ring j's own band mask, so
  it fades in exactly where ring j's material does and has no boundary of
  its own.

Each band's structure (sub-bands, gaps) is one radial opacity profile used
as a luminance mask; base colour, highlight, depth scrim and all shadows
paint through it, so the bands stay genuinely translucent. The orbiting
grain is the exception, on purpose: a streak sits at one radius, where the
band's alpha is a constant, so that alpha is baked into the streak's own
opacity and the streaks carry no mask at all. Every mask in the document is
therefore static and cacheable -- the per-frame work of the spin is a few
dozen plain strokes, which is what keeps the hero cheap. (The three-ring
version of this mark animated grain inside seven masked sheet copies, and
scrolling felt it.)

## The luminous treatment

The bands are not flat tape: each ring's opacity profile is a soft tube that
swells toward a bright mid-radius, so it reads as a rounded rod rather than a
ribbon. On top of that the generator adds, all static:

- a **halo** (`rgGlow`) -- a thin bright rim hugging each tube's outer edge.
  It is a crisp contour, not a diffuse glow: because the band is radially
  symmetric in ring space, the rim is just a narrow radial gradient painted
  onto a rect, with **no mask and no blur filter**;
- a **near-rim sweep** (`rgLume`) that brightens the front horizon, so a
  spinning band lights up as it comes round to the front;
- a **hot core streak** down each tube's mid-radius;
- **gold dust** strewn along the ring planes and loosely around the system.

No `feGaussianBlur` touches the rings at all -- an SVG re-rasterizes as a
whole whenever anything inside it animates, so a live blur would re-run every
frame the rings turn. Everything above is a plain gradient fill. The moving
comet dots glow by radial-gradient fill for the same reason, never a filter.
The `will-change: transform` on the spinning grain groups (in the
no-reduced-motion block) promotes each to its own compositor layer, so the
turn runs on the GPU instead of repainting the static artwork.

## Why the rings can turn

Turning a flat sheet about its own axis is rigid -- it never changes what is
near and what is far -- so the CSS spins each ring's grain group (inner
rings faster, as orbits are) without any depth relationship going wrong.
The bands' gradients are rotationally symmetric; only the grain and the
traffic nodes show the turn. Each grain group carries two zero-size anchor
dots at opposite corners of its square, pinning its fill-box centre to the
ring centre so the spin cannot wobble. The traffic dots glow by gradient
fill, not filter -- a drop-shadow on a moving dot re-blurs every frame.

## What lives where

- **Geometry, band profiles, grain, the weave, shadows' shape** -- this
  script, into the partial.
- **Colour and motion** -- `static/css/style.css`, under "The hero mark".
  `--ring-base/--ring-hi/--ring-lo/--ring-sh` are the theme palette; the
  `.ring-grain-r*` rules hold each ring's spin.
- **The traffic nodes' motion paths** -- printed by the script, pasted onto
  the `.rn-r*` rules. They are the lanes' projected ellipses, so they have
  to be updated whenever the partial is regenerated. Each node exists twice
  (front/back of the disc) with complementary opacity windows, which is
  what lets a lap really pass behind the planet.
