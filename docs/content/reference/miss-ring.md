+++
title = "Miss Ring"
description = "gori's companion: where the character came from, and the eight cells she is drawn on."
weight = 50
+++

Miss Ring is gori's companion — off by default, and switched on in
**Preferences → Appearance → Companion**. The [Settings guide](/guide/settings/)
covers what she does and the [`companion` key](/reference/config/) covers how to
configure her. This page is about how she is drawn.

## From a character to eight cells {#origin}

<div class="art-gallery">
  <figure>
    <img src="/images/miss-ring-character.webp" alt="The original Miss Ring character: a gold ring seen face-on, holding a round cream face with large lashed eyes and a small smile">
    <figcaption>The character, as first drawn</figcaption>
  </figure>
  <figure>
    <img src="/images/miss-ring-sprite.webp" alt="The same character reduced to a blocky eight-by-three grid of gold and cream cells, with two round eyes, a small mouth and two lash strokes">
    <figcaption>The same ring on an 8 × 3 cell grid</figcaption>
  </figure>
</div>

The motif is Loki's Miss Minutes crossed with Claude's mascot: huge lashed eyes,
soft rounded forms, a face with almost nothing in it. The *silhouette*, though,
is not borrowed — it is the gori mark itself, a ring, painted in whatever the
live theme calls its brand gold.

Getting her into a terminal meant giving all of that up except the ring and five
glyphs. This is the whole sprite, and what your terminal actually paints:

<pre class="sprite"><code class="nohighlight"> ▄▀▀▀▄
▐´●u●`▌
 ▀▄▄▄▀</code></pre>

## The grid {#grid}

She is eight columns by three rows, and every cell holds exactly one glyph:

<pre class="sprite"><code class="nohighlight"> ▄▀▀▀▄ ˙
▐´●u●`▌
 ▀▄▄▄▀</code></pre>

- **Row 0** — the crown, and the mood badge alone in column 7 (here the dot
  she wears while a background job runs).
- **Row 1** — the two walls, with the five-cell face between them.
- **Row 2** — the floor. Column 7 is empty.

**Why she is round and not oval.** A terminal row is about twice as tall as a
cell is wide, so three rows buy six units of height — and to read as a circle
rather than an egg, the equator has to be six *cells* across, not seven. Half
blocks put it exactly there: the left wall starts half a cell in, the right wall
ends half a cell early, and the crown then tapers half a cell per step. A circle
of diameter six wants 6.0 / 5.2 / 3.3 cells at those three bands, and the
profile lands on 6.0 / 5.0 / 3.0.

**The cost is her arms.** A half-block wall begins at the midpoint of its cell,
but a stub in the column beside it ends at that column's edge — half a cell
short, with nothing able to bridge the gap. Closing it would mean making the
wall a full block, which pushes the equator back out to seven cells and loses
the circle. So Miss Ring has no arms, and the badge column carries mood instead.

| Glyph | Codepoint | Job |
|-------|-----------|-----|
| `▀` | U+2580 UPPER HALF BLOCK | Crown and floor |
| `▄` | U+2584 LOWER HALF BLOCK | Crown and floor |
| `▐` | U+2590 RIGHT HALF BLOCK | Left wall |
| `▌` | U+258C LEFT HALF BLOCK | Right wall |
| `´` | U+00B4 ACUTE ACCENT | A lash rising to the right |
| `` ` `` | U+0060 GRAVE ACCENT | A lash rising to the left |

The mouth is spelled with `u`, `o`, `_`, `·` or `n`, and never with a cup like
`˘` or `ᴗ`. A combining-style mark is drawn at cap height, which is exactly
where the lashes are, so it would put the mouth *above* the eyes; and `ᴗ`, which
sits at the right height, is missing from most monospace fonts and falls through
to a proportional face or a box. `u` is the same cup, at the same height, in
every monospace font there is.

Colour is a second grid laid over the first — one role per cell, so a new
expression never means restating the ring's shading:

<pre><code class="nohighlight">.CHRRC.X
HlemelS.
.CSSSC..</code></pre>

`H` highlight · `R` the base gold · `S` shadow · `C` a dimmed corner ·
`e` pupil · `l` lash · `m` mouth · `o` the hole · `X` badge · `.` the plate
behind her. The light source is fixed to the upper left, which is why the crown
runs highlight-then-base. The interior is a *hole*, painted the plate colour, so
the terminal shows through the way a real ring's does — filling it with a light
colour laid a bright bar through the middle of a three-row sprite, and the eye
read the bar before it read the ring.

## Poses {#poses}

The five cells inside the ring are the whole of an expression: two brows, two
eyes and a mouth. The eyes say what she is doing; the brows say how she feels
about it. Both lashes lean inward for the open resting face, both turn over for
the furrowed one, and one at a time for the quizzical one — same two glyphs,
opposite character.

| Pose | Face | When it plays |
|------|------|---------------|
| `idle` | ``▐´●u●`▌`` | Resting |
| `blink` | ``▐´─u─`▌`` | Every 3 seconds or so, and as the last beat of some gestures |
| `happy` | ``▐´^o^`▌`` | A background job succeeded |
| `alert` | ``▐´O_O`▌`` | A warning landed, or she was poked awake |
| `error` | ``▐`×_×´▌`` | Something failed — the one pose that also flinches |
| `doze` | ``▐´~·~`▌`` | Asleep after 90 seconds of quiet |
| `oh` | ``▐´●o●`▌`` | A yawn winding up, or a small "oh" on its own |
| `yawn` | ``▐´─o─`▌`` | Mid-yawn, eyes squeezed shut |
| `smile` | ``▐´^u^`▌`` | An idle gesture, and where `happy` settles |
| `squint` | ``▐´·u·`▌`` | Peering at something |
| `flat` | ``▐´●_●`▌`` | Deadpan, and where `error` settles |
| `wonder` | ``▐´●o●´▌`` | One brow cocked — the curious "oh?" |
| `wry` | ``▐`^u●`▌`` | One eye crinkled: she got it |
| `hmm` | ``▐´·_●´▌`` | Weighing something up, and where a warning settles |
| `pout` | ``▐`●n●´▌`` | The sulk — the cup turned over |

A reaction is an arc rather than a single face: she hits the peak, holds it
about a second and a half, then settles into the quieter version of it for the
rest. Six of these are reactions, the rest are idle gestures she plays
unprompted, and the three settle poses belong to both.

She also winks, but only from `idle` — a winking `alert` or `doze` would read as
a rendering glitch rather than a gesture:

| Wink | Face |
|------|------|
| Left | ``▐´─u●`▌`` |
| Right | ``▐´●u─`▌`` |

The badge in column 7 is the only thing outside the ring, and it says what she
could not fit into a face:

| Badge | Means |
|-------|-------|
| `z` | Dozing |
| `·` | Something succeeded |
| `!` | A warning |
| `×` | A failure |
| `˙` `·` `.` | A dot bobbing while a background job runs, in step with the status row's own spinner |

## In the terminal {#in-the-terminal}

<figure class="tui-shot">
  <img src="/images/tui/readme.svg" alt="The gori History tab with Miss Ring sitting in the bottom-right corner of the body, a speech bubble above her reading &quot;hi! ready when you are&quot;">
  <figcaption>Miss Ring in <code>body</code> placement, saying the one thing she says unprompted: <em>hi! ready when you are</em>.</figcaption>
</figure>

Two placements. `body` puts the full 8 × 3 sprite in the bottom-right corner of
the tab body, with room above her for a speech bubble; clicking her opens the
notification ring. `bar` folds her into an eight-cell chip in the status row —
the middle row plus the badge borrowed from the cell above it, which is why
every idle gesture lives in the face and not in the glint. Resting, a failure,
and dozing:

<pre class="sprite sprite--stack"><code class="nohighlight">▐´●u●`▌
▐`×_×´▌×
▐´~·~`▌z</code></pre>

Everything else — when she blinks, how often she moves, whether she speaks at
all — is in the [Settings guide](/guide/settings/).
