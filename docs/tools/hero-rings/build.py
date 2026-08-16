#!/usr/bin/env python3
"""Generate templates/partials/hero-rings.html -- the neon-orbit hero mark.

A disc of the official art sits at the centre; around it three thin luminous
ring tubes, each flat in its own plane, crossing in front of and behind the
planet and one another -- glowing orbits rather than a Saturn sheet.

Geometry. Each ring's plane is described by (rot, k): the projection of a
flat sheet seen from elevation asin(k) is translate * rotate(rot) *
scale(1, k), and the depth of the sheet's material at screen point p is
LINEAR in p: z_i(p) = sqrt(1 - k^2)/k * (local y). Linear depths make the
whole weave derivable:

* The rings' radial ranges are DISJOINT, so two tubes never occupy the same
  3D point. For any pair, z_i(p) = z_j(p) is a straight line through the
  centre -- and because equal depth at equal screen position would mean the
  same 3D point, that line can never cross a region where both tubes have
  material. Every over/under decision is therefore constant on each side of
  the pair's line, and the painter's order is geometry, not authoring.

Rendering. Unlike the earlier broad-band marks, the tubes are STROKES of
the projected centreline ellipse, drawn in screen space. A stroke keeps a
constant screen width the whole way round, which is exactly how a thin
torus projects -- the flat-washer look of a stroked ring-space circle
(k times thinner at the horizons than at the sides) is the single biggest
tell of a fake ring. The neon body is a stack of concentric strokes: wide
faint glow layers, a translucent body, a hot narrow core -- a cross-tube
intensity profile without any gradient-on-stroke support and without any
blur filter (an SVG re-rasterizes as a whole whenever anything inside it
animates, so a live feGaussianBlur would re-run every frame the grain
turns; layered strokes re-raster for free).

What varies ALONG the tube -- the far side receding, the near rim catching
the light -- cannot ride the stroke either, so it is painted as extra full
ellipse strokes weighted by static linear-gradient masks (far-fade, near-
fade). A mask fades continuously, so nothing translucent is ever split
along a visible edge (complementary antialiased coverage composes darker
than either side: the dark-seam lesson).

Occlusion is real, and inherited from the band-era build:

* Full tubes behind the disc; each ring's near half repainted in front,
  clipped to a screen circle a hair wider than the disc (the edge hides
  under the rim stroke; the half-plane cut lies at radii the disc never
  reaches).
* Where ring i must come back OVER a later-painted ring j, it is repainted
  clipped to the safe half-plane and weighted by ring j's own soft tube
  mask: the repaint fades in exactly where ring j's material fades in, so
  the patch has no visible boundary of its own. The half-plane clip's hard
  edge only ever crosses zero-alpha content (see above).
* At ring-ring crossings the over tube lays a soft displaced shadow on the
  under tube's material; the near tubes cast displaced copies onto the
  disc; the planet shades the far tubes passing behind it (a proximity
  mask around the disc times the far-fade).

Rotation stays honest: turning a flat sheet about its own axis is rigid, so
the CSS spins each ring's grain group -- bright energy glints and dark
flickers riding the tube, authored in ring space (inner rings faster)
-- without any depth relationship ever going wrong. The tubes' strokes are
rotationally symmetric; only the grain and the traffic comets show the
turn.

Regenerate rather than edit the emitted markup by hand; a run also prints
the traffic lanes' offset paths and the per-ring spin rules for
static/css/style.css.
"""
import math
import pathlib
import random

C = 120.0            # centre of the 240x240 viewBox
DISC = 62.0          # radius of the planet disc

# The three orbits, outermost first (base painting order). mid is the tube
# centreline radius, w the neon body's core width in screen units. Disjoint
# radial ranges (mid +/- the widest glow layer) are what make the weave
# derivable -- see the module docstring.
RINGS = [
    dict(mid=108.0, w=2.6, k=0.30, rot=-16.0,
         dur="40s", ph="-25s", step="0.55s", spin="110s"),
    dict(mid=85.0, w=2.2, k=0.52, rot=38.0,
         dur="28s", ph="-11s", step="0.45s", spin="70s"),
    dict(mid=71.0, w=1.9, k=0.42, rot=-58.0,
         dur="21s", ph="-6s", step="0.4s", spin="52s"),
]

# The neon cross-section, outermost layer first: (width factor of w,
# opacity, class). A dense ramp of glow strokes approximating a Gaussian
# bloom (few coarse steps read as terraces around the tube), then the
# translucent gold body and the hot core -- additive enough to read as a
# lit tube, translucent enough that the page shows through the spill.
TUBE_LAYERS = [
    (5.4, 0.028, "rt-glow"),
    (4.3, 0.045, "rt-glow"),
    (3.4, 0.07, "rt-glow"),
    (2.7, 0.10, "rt-glow"),
    (2.15, 0.135, "rt-glow"),
    (1.7, 0.18, "rt-glow"),
    (1.35, 0.26, "rt-glow"),
    (1.12, 0.5, "rt-body"),
    (0.6, 0.78, "rt-core"),
    (0.27, 0.92, "rt-core"),
]

# The soft tube-footprint mask: white strokes matching the layers' reach,
# so patches weighted by it fade in exactly where the tube's material does.
MASK_LAYERS = [(5.0, 0.18), (3.2, 0.4), (1.9, 0.7), (1.1, 1.0)]

CAST_DX, CAST_DY = 3.0, 5.0     # screen offset of the rings' shadow on the disc
XSH_DX, XSH_DY = 2.2, 3.2       # screen offset of ring-on-ring crossing shadows

rng = random.Random(11)

OUT = pathlib.Path(__file__).resolve().parents[2] / "templates/partials/hero-rings.html"


def fmt(v, p=1):
    s = f"{v:.{p}f}".rstrip("0").rstrip(".")
    return s if s not in ("-0", "") else "0"


def cb(i):
    """Depth per unit of local y -- also how steeply ring i tilts away."""
    return math.sqrt(1 - RINGS[i]["k"] ** 2)


# --- transforms -------------------------------------------------------------

def lin(i):
    """Ring i's linear screen map: rotate(rot) * scale(1, k)."""
    R = RINGS[i]
    c, s = math.cos(math.radians(R["rot"])), math.sin(math.radians(R["rot"]))
    return (c, s, -R["k"] * s, R["k"] * c)     # columns of the 2x2 matrix

def inv(m):
    a, b, c_, d = m
    det = a * d - b * c_
    return (d / det, -b / det, -c_ / det, a / det)

def apply(m, v):
    a, b, c_, d = m
    return (a * v[0] + c_ * v[1], b * v[0] + d * v[1])


def plane(i):
    R = RINGS[i]
    return (f'transform="translate({fmt(C)} {fmt(C)}) '
            f'rotate({fmt(R["rot"])}) scale(1 {fmt(R["k"], 2)})"')


def depth_grad(i):
    """z_i(p) as a screen gradient: sqrt(1-k^2)/k times local y."""
    a, b, c_, d = inv(lin(i))
    s = cb(i) / RINGS[i]["k"]
    return (s * b, s * d)    # row y of the inverse, scaled


# Pair half-planes: for i < j, z_i(p) - z_j(p) = n . (p - C) with n constant.
# The line n . (p - C) = 0 is where the two sheets would be equally deep --
# and since equal depth at equal screen point means the same 3D point, which
# disjoint radii forbid, this hard clip edge never crosses paint where both
# tubes have material.
def half_angle(i, j):
    wi, wj = depth_grad(i), depth_grad(j)
    n = (wi[0] - wj[0], wi[1] - wj[1])
    return math.degrees(math.atan2(n[1], n[0]))


# --- the tube ---------------------------------------------------------------

def ellipse_path(i, r=None):
    """Ring i's projected centreline, starting at a horizon, near half
    first (which is what the comet opacity windows in the CSS assume)."""
    R = RINGS[i]
    r = R["mid"] if r is None else r
    t = math.radians(R["rot"])

    def pt(th):
        x, y = r * math.cos(th), R["k"] * r * math.sin(th)
        return (C + x * math.cos(t) - y * math.sin(t),
                C + x * math.sin(t) + y * math.cos(t))

    x0, y0 = pt(0.0)
    xh, yh = pt(math.pi)
    rx, ry = fmt(r), fmt(R["k"] * r)
    return (f"M{fmt(x0)} {fmt(y0)}A{rx} {ry} {fmt(R['rot'])} 0 1 {fmt(xh)} {fmt(yh)}"
            f"A{rx} {ry} {fmt(R['rot'])} 0 1 {fmt(x0)} {fmt(y0)}")


def stroke(i, cls, wf, op, p=None):
    d = ellipse_path(i) if p is None else p
    return (f'<path class="{cls}" stroke-width="{fmt(wf * RINGS[i]["w"], 2)}" '
            f'stroke-opacity="{fmt(op, 3)}" d="{d}"/>')


def mask_stroke(i, wf, op):
    """A white footprint stroke for ring i's soft tube mask."""
    return (f'<path stroke="#fff" fill="none" stroke-width="{fmt(wf * RINGS[i]["w"], 2)}" '
            f'stroke-opacity="{fmt(op, 2)}" d="{ellipse_path(i)}"/>')


def tube_stack(i, pad):
    """Ring i's whole static paint: the neon layer stack, then the far side
    receding (a scrim weighted by the far-fade mask) and the near rim
    catching the light (a lume weighted by the near-fade mask). All screen
    space, all static; the spinning grain lives elsewhere."""
    lines = [f'{pad}{stroke(i, cls, wf, op)}' for wf, op, cls in TUBE_LAYERS]
    lines.append(f'{pad}<g mask="url(#rtFadeF{i})">')
    lines.append(f'{pad}  {stroke(i, "rt-scrim", 1.5, 0.5 * cb(i))}')
    lines.append(f'{pad}</g>')
    lines.append(f'{pad}<g mask="url(#rtFadeN{i})">')
    lines.append(f'{pad}  {stroke(i, "rt-lume", 0.9, 0.32)}')
    lines.append(f'{pad}</g>')
    return "\n".join(lines)


# --- grain: the energy riding the tube --------------------------------------

def arc(r, a0, span):
    a1 = a0 + span
    x0, y0 = r * math.cos(a0), r * math.sin(a0)
    x1, y1 = r * math.cos(a1), r * math.sin(a1)
    la = 1 if span > math.pi else 0
    return f"M{fmt(x0)} {fmt(y0)}A{fmt(r)} {fmt(r)} 0 {la} 1 {fmt(x1)} {fmt(y1)}"


def make_grain(i, n_glint, n_spark, n_dim):
    """Arcs of energy orbiting inside the tube, authored in ring space so
    the CSS spin is a rigid motion of the sheet. They carry NO mask -- each
    sits at the tube's centreline where the body is solid, so opacity is
    baked per arc and every animated element stays outside every mask (the
    masked scrim/lume copies stay static and cacheable). The two anchor
    dots pin the group's fill-box centre to the ring centre, so the spin
    cannot wobble no matter where the random arcs land. Ring-space strokes
    squash toward the horizons; the arcs are thinner than the tube body, so
    the squash reads as foreshortening, not a break."""
    R = RINGS[i]
    e = R["mid"] + 3 * R["w"]
    lines = [f'<g class="ring-grain ring-grain-r{i}">',
             f'  <circle class="rg-anchor" cx="{fmt(-e)}" cy="{fmt(-e)}" r="0.01" fill="none"/>',
             f'  <circle class="rg-anchor" cx="{fmt(e)}" cy="{fmt(e)}" r="0.01" fill="none"/>']

    def streak(cls, w_lo, w_hi, o_lo, o_hi, s_lo, s_hi):
        r = R["mid"] + rng.uniform(-0.45, 0.45) * R["w"]
        lines.append(f'  <path class="{cls}" stroke-width="{fmt(rng.uniform(w_lo, w_hi), 2)}" '
                     f'opacity="{fmt(rng.uniform(o_lo, o_hi), 3)}" '
                     f'd="{arc(r, rng.uniform(0, 2 * math.pi), math.radians(rng.uniform(s_lo, s_hi)))}"/>')

    for _ in range(n_glint):          # long soft shimmer
        streak("rg-l", 0.5, 1.0, 0.16, 0.4, 24, 85)
    for _ in range(n_spark):          # short hot packets
        streak("rg-l", 0.8, 1.2, 0.45, 0.75, 3, 9)
    for _ in range(n_dim):            # slow dark flicker
        streak("rg-d", 0.6, 1.1, 0.07, 0.15, 30, 95)
    lines.append('</g>')
    return "\n".join(lines)


GRAIN = [make_grain(0, 9, 3, 5), make_grain(1, 7, 3, 4), make_grain(2, 6, 2, 3)]


def indented(text, pad):
    return "\n".join(pad + ln for ln in text.split("\n"))


def grain_layer(i):
    """Ring i's spinning grain, then a static far-side scrim above it so
    the far arcs still dim with depth. Only plain strokes move."""
    return "\n".join([
        f'    <g {plane(i)}>',
        indented(GRAIN[i], "      "),
        '    </g>',
        f'    <g mask="url(#rtFadeF{i})">',
        f'      {stroke(i, "rt-scrim", 1.5, 0.3 * cb(i))}',
        '    </g>'])


# --- shadows ----------------------------------------------------------------

def cross_shadow(under, over, pad):
    """The over tube's soft displaced shadow, laid only on the under tube's
    material (weighted by the under tube's own soft mask, so the shadow has
    no boundary of its own)."""
    return "\n".join([
        f'{pad}<g mask="url(#rtMask{under})">',
        f'{pad}  <g transform="translate({fmt(XSH_DX)} {fmt(XSH_DY)})" filter="url(#rgSoft)" opacity="0.3">',
        f'{pad}    {stroke(over, "rt-sh", 1.4, 1.0)}',
        f'{pad}  </g>',
        f'{pad}</g>'])


def under_shadow(i, j, front):
    """Base-order side of pair (i, j): j paints later, so where j is the
    nearer sheet its shadow must land on i just before j paints."""
    lines = [f'    <g clip-path="url(#rgHm{i}{j})">']
    if front:
        lines.append(f'      <g clip-path="url(#rtNear{i})">')
    lines.append(cross_shadow(i, j, "        " if front else "      "))
    if front:
        lines.append('      </g>')
    lines.append('    </g>')
    return "\n".join(lines)


def patch(i, j, front):
    """Ring i repainted over ring j on the safe side of their line, weighted
    by ring j's tube mask so the repaint has no boundary of its own -- plus
    ring i's shadow on ring j on that same side."""
    pad = "          " if front else "        "
    lines = [f'    <g clip-path="url(#rgHp{i}{j})">']
    if front:
        lines.append(f'      <g clip-path="url(#rtNear{i})">')
    lines.append(cross_shadow(j, i, pad[:-2]))
    lines.append(f'{pad[:-2]}<g mask="url(#rtMask{j})">')
    lines.append(tube_stack(i, pad))
    lines.append(f'{pad[:-2]}</g>')
    if front:
        lines.append('      </g>')
    lines.append('    </g>')
    return "\n".join(lines)


def planet_shade(i):
    """The planet's shadow on ring i where it passes behind: a proximity
    band hugging the disc's silhouette, times the far-fade so it exists
    only on the far half and needs no hard cut of its own."""
    return "\n".join([
        f'    <g mask="url(#rtFadeF{i})">',
        '      <g mask="url(#rtProx)">',
        f'        {stroke(i, "rt-sh", 1.7, 0.55)}',
        '      </g>',
        '    </g>'])


def base_tube(i):
    return tube_stack(i, "    ")


def front_cap(i):
    """Ring i's near half again, only across the planet's face; the circle
    clip edge hides under the rim stroke, and the half-plane cut lies at
    radii the disc never reaches."""
    return "\n".join([
        '    <g clip-path="url(#rgDiscLip)">',
        f'      <g clip-path="url(#rtNear{i})">',
        tube_stack(i, "        "),
        '      </g>',
        '    </g>'])


# --- traffic ----------------------------------------------------------------

def nodes(kind):
    """One head and five trail dots per lane -- a comet. The same dots exist
    twice, once behind the disc and once in front; complementary opacity
    windows in the motion CSS mean each lap shows the front copies for the
    near half and the back copies for the far half -- real occlusion, not a
    fade."""
    lines = [f'    <g class="ring-nodes ring-nodes-{kind}">']
    for i in range(len(RINGS)):
        for kk, r in enumerate([3.4, 2.5, 1.9, 1.45, 1.1, 0.85]):
            lines.append(f'      <circle class="ring-node rn-r{i} rn-t{kk}" r="{r}" '
                         f'fill="url(#rgNodeGlow)"/>')
    lines.append("    </g>")
    return "\n".join(lines)


# --- defs -------------------------------------------------------------------

def fade_points(i):
    """Screen endpoints of ring i's along-tube fades: the far horizon
    (ring-space (0, -mid)) to the near horizon (ring-space (0, +mid))."""
    R = RINGS[i]
    far = apply(lin(i), (0.0, -R["mid"]))
    near = apply(lin(i), (0.0, R["mid"]))
    return (C + far[0], C + far[1]), (C + near[0], C + near[1])


def ring_defs(i):
    far, near = fade_points(i)
    R = RINGS[i]
    mask_strokes = "\n".join(f'        {mask_stroke(i, wf, op)}' for wf, op in MASK_LAYERS)
    return f"""      {{# Ring {i}'s soft tube footprint (for patches and crossing
         shadows), and the two along-tube fades: far side receding, near rim
         catching the light. All static, so every mask composites once. #}}
      <mask id="rtMask{i}" maskUnits="userSpaceOnUse" x="-10" y="-10" width="260" height="260">
{mask_strokes}
      </mask>
      <linearGradient id="rtFadeFG{i}" gradientUnits="userSpaceOnUse"
                      x1="{fmt(far[0], 2)}" y1="{fmt(far[1], 2)}" x2="{fmt(near[0], 2)}" y2="{fmt(near[1], 2)}">
        <stop offset="0" stop-color="#fff"/>
        <stop offset="0.38" stop-color="#b0b0b0"/>
        <stop offset="0.52" stop-color="#4a4a4a"/>
        <stop offset="0.66" stop-color="#111"/>
        <stop offset="1" stop-color="#000"/>
      </linearGradient>
      <mask id="rtFadeF{i}" maskUnits="userSpaceOnUse" x="-10" y="-10" width="260" height="260">
        <rect x="-10" y="-10" width="260" height="260" fill="url(#rtFadeFG{i})"/>
      </mask>
      <linearGradient id="rtFadeNG{i}" gradientUnits="userSpaceOnUse"
                      x1="{fmt(near[0], 2)}" y1="{fmt(near[1], 2)}" x2="{fmt(far[0], 2)}" y2="{fmt(far[1], 2)}">
        <stop offset="0" stop-color="#fff"/>
        <stop offset="0.3" stop-color="#888"/>
        <stop offset="0.5" stop-color="#222"/>
        <stop offset="0.62" stop-color="#000"/>
        <stop offset="1" stop-color="#000"/>
      </linearGradient>
      <mask id="rtFadeN{i}" maskUnits="userSpaceOnUse" x="-10" y="-10" width="260" height="260">
        <rect x="-10" y="-10" width="260" height="260" fill="url(#rtFadeNG{i})"/>
      </mask>
      <clipPath id="rtNear{i}">
        <rect x="-400" y="0" width="800" height="400"
              transform="translate({fmt(C)} {fmt(C)}) rotate({fmt(R["rot"])})"/>
      </clipPath>"""


def pair_defs():
    out = []
    for i in range(len(RINGS)):
        for j in range(i + 1, len(RINGS)):
            ang = half_angle(i, j)
            for tag, extra in (("Hp", 0.0), ("Hm", 180.0)):
                out.append(
                    f'      <clipPath id="rg{tag}{i}{j}">'
                    f'<rect x="0" y="-400" width="800" height="800" '
                    f'transform="translate({fmt(C)} {fmt(C)}) rotate({fmt(ang + extra, 2)})"/>'
                    f'</clipPath>')
    return "\n".join(out)


def dust():
    """Static gold dust: most of it strewn along the three ring planes, the
    rest scattered in a loose donut around the whole system."""
    lines = ['    <g class="ring-dust">']

    def dot(x, y):
        lines.append(f'      <circle cx="{fmt(x)}" cy="{fmt(y)}" r="{fmt(rng.uniform(0.3, 0.85), 2)}" '
                     f'opacity="{fmt(rng.uniform(0.08, 0.42), 2)}"/>')

    for i in range(len(RINGS)):
        R = RINGS[i]
        for _ in range(20):
            th = rng.uniform(0, 2 * math.pi)
            rr = R["mid"] + rng.uniform(-9, 11)
            v = apply(lin(i), (rr * math.cos(th), rr * math.sin(th)))
            dot(C + v[0], C + v[1])
    for _ in range(26):
        th = rng.uniform(0, 2 * math.pi)
        rr = rng.uniform(70, 132)
        dot(C + rr * math.cos(th), C + 0.85 * rr * math.sin(th))
    lines.append('    </g>')
    return "\n".join(lines)


# --- the document -----------------------------------------------------------

# The art box overhangs the clip circle: the drift in the motion CSS scales
# and slides it, and without the overhang a corner would swing into view at
# the far end of the travel.
ART = DISC * 1.18
box = fmt(C - ART)
side = fmt(2 * ART)

N = len(RINGS)

base_stack = []
for j in range(N):
    for i in range(j):
        base_stack.append(under_shadow(i, j, front=False))
    base_stack.append(base_tube(j))
    base_stack.append(grain_layer(j))
    for i in range(j):
        base_stack.append(patch(i, j, front=False))
for i in range(N):
    base_stack.append(planet_shade(i))

front_stack = []
for j in range(N):
    for i in range(j):
        front_stack.append(under_shadow(i, j, front=True))
    front_stack.append(front_cap(j))
    for i in range(j):
        front_stack.append(patch(i, j, front=True))

cast_on_disc = "\n".join(
    "\n".join([f'            <g clip-path="url(#rtNear{i})">',
               f'              {stroke(i, "rt-sh", 1.4, 0.85)}',
               '            </g>']) for i in range(N))

doc = f"""{{# The hero mark: three thin luminous ring tubes crossing around the
   official art disc -- glowing orbits, not a Saturn sheet. Generated
   geometry: each tube is a constant-width neon stack of strokes on its
   plane's projected centreline ellipse; the painter's over/under order at
   every crossing is derived from the sheets' linear depth fields, and
   repaints are weighted by the other ring's soft tube mask so no
   translucent paint is ever split along a visible edge. The stylesheet
   owns all colour and motion.
   Re-generate (tools/hero-rings/build.py) rather than edit by hand. #}}
<figure class="hero-art">
  <svg class="hero-rings" viewBox="0 0 240 240" role="img" aria-label="{{{{ "home.hero_art_alt" | t }}}}">
    <defs>
{chr(10).join(ring_defs(i) for i in range(N))}
{pair_defs()}
      <clipPath id="rgDiscLip"><circle cx="{fmt(C)}" cy="{fmt(C)}" r="{fmt(DISC + 0.3)}"/></clipPath>
      <clipPath id="rgDisc"><circle cx="{fmt(C)}" cy="{fmt(C)}" r="{fmt(DISC)}"/></clipPath>
      {{# The planet's shadow zone: a band hugging the disc's silhouette,
         fading out by ~+26; the far-fade masks cut it to the far halves. #}}
      <radialGradient id="rtProxG" gradientUnits="userSpaceOnUse" cx="{fmt(C)}" cy="{fmt(C)}" r="{fmt(DISC + 30)}">
        <stop offset="0" stop-color="#fff"/>
        <stop offset="{fmt(DISC / (DISC + 30), 3)}" stop-color="#fff"/>
        <stop offset="{fmt((DISC + 12) / (DISC + 30), 3)}" stop-color="#666"/>
        <stop offset="{fmt((DISC + 22) / (DISC + 30), 3)}" stop-color="#161616"/>
        <stop offset="1" stop-color="#000"/>
      </radialGradient>
      <mask id="rtProx" maskUnits="userSpaceOnUse" x="-10" y="-10" width="260" height="260">
        <rect x="-10" y="-10" width="260" height="260" fill="url(#rtProxG)"/>
      </mask>
      <linearGradient id="rgSheen" gradientUnits="userSpaceOnUse"
                      x1="{fmt(C - DISC)}" y1="{fmt(C - DISC)}" x2="{fmt(C + DISC)}" y2="{fmt(C + DISC)}">
        <stop class="ring-s0" offset="0"/>
        <stop class="ring-s1" offset="0.42"/>
        <stop class="ring-s2" offset="1"/>
      </linearGradient>
      <filter id="rgSoft"><feGaussianBlur stdDeviation="1.7"/></filter>
      {{# The traffic comets' glow, baked into a gradient fill: a filter
         here would re-blur every moving dot every frame. #}}
      <radialGradient id="rgNodeGlow">
        <stop class="rs-glow" offset="0" stop-opacity="1"/>
        <stop class="rs-glow" offset="0.4" stop-opacity="0.8"/>
        <stop class="rs-glow" offset="0.72" stop-opacity="0.28"/>
        <stop class="rs-glow" offset="1" stop-opacity="0"/>
      </radialGradient>
    </defs>

    {{# Gold dust strewn along the ring planes and loosely around them. #}}
{dust()}

    {{# The tubes behind the planet, woven back to front, then the
       planet's own shadow across whatever passes behind it. #}}
{chr(10).join(base_stack)}
{nodes("back")}

    {{# The planet. Not in any ring group: the art holds still while the
       rings turn around it. The near tubes' shadow falls across its face,
       displaced from the tubes toward the lower right. #}}
    <g class="ring-core">
      <circle cx="{fmt(C)}" cy="{fmt(C)}" r="{fmt(DISC)}" fill="#0a0a0b"/>
      <g clip-path="url(#rgDisc)">
        <image class="ring-core-art" href="{{{{ base_url }}}}/images/wallpaper.webp"
               x="{box}" y="{box}" width="{side}" height="{side}"
               preserveAspectRatio="xMidYMid slice"/>
        <g class="ring-cast" filter="url(#rgSoft)" opacity="0.5">
          <g transform="translate({fmt(CAST_DX)} {fmt(CAST_DY)})">
{cast_on_disc}
          </g>
        </g>
      </g>
      <circle cx="{fmt(C)}" cy="{fmt(C)}" r="{fmt(DISC)}" fill="url(#rgSheen)"/>
      <circle class="ring-core-rim" cx="{fmt(C)}" cy="{fmt(C)}" r="{fmt(DISC - 0.4)}"/>
    </g>

    {{# The near halves again, in front, only across the planet's face --
       woven in the same order as behind. #}}
{chr(10).join(front_stack)}
{nodes("front")}
  </svg>
</figure>
"""

OUT.write_text(doc)
print(f"wrote {OUT} ({len(doc.splitlines())} lines)")
print()
print("Paste these into static/css/style.css, on the .rn-r* rules and the")
print(".ring-grain-r* spins -- lanes and grain ride the same planes, so they")
print("have to be regenerated together with the partial:")
print()
for i, R in enumerate(RINGS):
    print(f'  .rn-r{i} {{ --dur: {R["dur"]}; --ph: {R["ph"]}; --step: {R["step"]}; '
          f'offset-path: path("{ellipse_path(i)}"); }}')
print()
for i, R in enumerate(RINGS):
    print(f'  .ring-grain-r{i} {{ animation: ring-turn {R["spin"]} linear infinite; }}')
