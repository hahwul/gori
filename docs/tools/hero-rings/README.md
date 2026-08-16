# hero-rings

Generates `templates/partials/hero-rings.html`, the neon-orbit mark in the
landing-page hero: the official art disc circled by three thin luminous
ring tubes -- glowing orbits, gold in the dark theme and ink-black on
paper -- each flat in its own plane, weaving in front of and behind the
planet and one another.

```
python3 tools/hero-rings/build.py
```

Each ring's plane is `(rot, k)`: the projection of a flat sheet seen from
elevation asin(k) is `translate * rotate(rot) * scale(1, k)`. Change a
constant in the `RINGS` table and re-run; the emitted markup should never
be edited directly.

## Why the tubes are strokes

Earlier incarnations of this mark authored each ring face-on in ring space
and let the plane transform squash it. That is right for a broad Saturn
band, but a thin ring drawn that way is a flat washer: k times thinner at
the horizons than at the sides, the single biggest tell of a fake ring. A
thin torus projects at constant screen width -- which is exactly what a
STROKE of the projected centreline ellipse gives. So every tube is drawn
in screen space, as a stack of concentric strokes: a dense ramp of faint
glow layers (few coarse steps read as terraces), a translucent body, a hot
narrow core. No gradient can ride a stroke's cross-section and no blur
filter is allowed (see below); the layered stack is the whole neon.

What varies ALONG a tube cannot ride the stroke either, so it is painted
as extra full-ellipse strokes weighted by static linear-gradient masks:
a far-fade scrim (the far side recedes) and a near-fade lume (the near rim
catches the light). A mask fades continuously, so nothing translucent is
ever split along a visible edge -- complementary antialiased coverage
composes darker than either side, the dark seam that cost a full round in
the original Saturn version.

## Why the weave is derived

The depth of a sheet's material is linear in screen position, so for any
pair of rings "who is in front" flips across a single straight line through
the centre. Because the rings' radial ranges are disjoint, two tubes can
never occupy the same 3D point, which means that line never crosses a spot
where both tubes have material: every crossing's over/under order is
constant and computable. The painter's stacking, the half-plane clips, and
the crossing shadows all fall out of that geometry:

- Each ring's base tube is one unbroken ellipse behind the planet; its
  near half is repainted in front only across the disc, clipped to a
  screen circle a hair wider than the rim (the edge hides under the rim
  stroke; the half-plane cut lies at radii the disc never reaches).
- Where ring i must come back over a later-painted ring j, the repaint is
  clipped to the safe half-plane and weighted by ring j's own soft tube
  mask, so it fades in exactly where ring j's material does and has no
  boundary of its own.
- The over tube lays a soft displaced shadow on the under tube at each
  crossing; the near tubes cast displaced copies onto the disc; the planet
  shades the far tubes behind it (a proximity mask hugging the disc's
  silhouette, times the far-fade).

## The performance discipline

An SVG re-rasterizes as a whole whenever anything inside it animates, so
no `feGaussianBlur` touches the rings at all -- glow is layered strokes,
and the moving comet dots glow by radial-gradient fill. Every mask in the
document is static and cacheable: the orbiting grain (bright energy
glints, short hot sparks, dark flickers riding each tube) carries no mask
-- it sits at the tube's centreline where the body is solid, so opacity is
baked per arc. The `will-change: transform` on the spinning grain groups
(in the no-reduced-motion block) promotes each to its own compositor
layer, so the turn runs on the GPU instead of repainting the static
artwork.

## Why the rings can turn

Turning a flat sheet about its own axis is rigid -- it never changes what
is near and what is far -- so the CSS spins each ring's grain group (inner
rings faster, as orbits are) without any depth relationship going wrong.
The tubes' strokes are rotationally symmetric; only the grain and the
traffic comets show the turn. Grain is authored in ring space so the spin
is honest; its strokes squash toward the horizons, which reads as
foreshortening because they stay thinner than the constant-width tube
body. Each grain group carries two zero-size anchor dots at opposite
corners of its square, pinning its fill-box centre to the ring centre so
the spin cannot wobble.

## What lives where

- **Geometry, the neon layer stack, grain, the weave, shadows' shape** --
  this script, into the partial.
- **Colour and motion** -- `static/css/style.css`, under "The hero mark".
  `--ring-base/--ring-hi/--ring-lo/--ring-sh/--ring-glow` are the theme
  palette; `--ring-spill` scales how far the glow layers reach into the
  page (the light theme halves it so ink stays ink); the `.ring-grain-r*`
  rules hold each ring's spin.
- **The traffic comets' motion paths** -- printed by the script, pasted
  onto the `.rn-r*` rules. Each lane IS its ring's centreline ellipse, so
  they have to be updated whenever the partial is regenerated. Each comet
  (a head and five trail dots) exists twice, front/back of the disc, with
  complementary opacity windows, which is what lets a lap really pass
  behind the planet.
