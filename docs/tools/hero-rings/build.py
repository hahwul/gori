#!/usr/bin/env python3
"""Generate templates/partials/hero-rings.html -- the crossing-rings hero mark.

A disc of the official art sits at the centre; around it three broad,
translucent ring bands, each flat in its own plane, crossing in front of and
behind the planet and one another -- an armillary rather than a Saturn.

Every ring is authored face-on in its own "ring space" (origin at the
planet's centre, the band an annulus of radii [a, b]) and carried to the
screen by one transform, translate * rotate(rot) * scale(1, k). That is the
exact orthographic projection of a flat sheet seen from elevation asin(k),
and the depth of the sheet's material at screen point p is linear in p:
z_i(p) = sqrt(1 - k^2)/k * (local y). Linear depths make the whole weave
derivable:

* The rings' radial ranges are DISJOINT, so two bands never occupy the same
  3D point. For any pair, z_i(p) = z_j(p) is a straight line through the
  centre -- and because equal depth at equal screen position would mean the
  same 3D point, that line can never cross a region where both bands have
  material. Every over/under decision is therefore constant on each side of
  the pair's line, and the painter's order is geometry, not authoring.

* Translucent paint cannot be split along a visible edge (complementary
  antialiased coverage composes to less than either side: a dark seam -- the
  single most expensive artifact of this hero's first Saturn incarnation).
  So nothing here is ever split where it shows. Each ring's base copy is one
  unbroken sheet. Where ring i must come back OVER a later-painted ring j,
  it is repainted clipped to the safe half-plane and weighted by ring j's
  own band-alpha mask: the repaint fades in exactly where ring j's material
  fades in, so the patch has no visible boundary of its own. The half-plane
  clip's hard edge only ever crosses zero-alpha content (see above). The
  slight double-density where a patch overlays its own base copy lands only
  where the two bands genuinely overlap, and reads as two translucent
  sheets stacking -- which is what it is.

Each ring's band structure (sub-bands, gaps, ringlet grain) is one radial
gradient of white stops used as a luminance mask; base colour, highlight
wash, orbiting grain, depth scrim, and every shadow paints through it, so
the bands keep their translucency: page and planet genuinely show through.

Occlusion by the planet is real: full sheets behind the disc, and each
ring's near half repainted in front, clipped to a screen circle a hair
wider than the disc (the edge hides under the rim stroke; the half-plane
cut lies at radii the disc never reaches). At ring-ring crossings the over
band lays a soft displaced shadow on the under band's material -- shaped by
the over band's mask, weighted by the under band's -- and the near bands
cast a blurred displaced copy of themselves onto the disc.

Rotation stays honest: turning a flat sheet about its own axis is rigid, so
the CSS spins each ring's grain group (inner rings faster) without any
depth relationship ever going wrong. The bands' gradients are rotationally
symmetric; only the grain and the traffic nodes show the turn.

Regenerate rather than edit the emitted markup by hand; a run also prints
the traffic nodes' offset paths for static/css/style.css.
"""
import math
import pathlib
import random

C = 120.0            # centre of the 240x240 viewBox
DISC = 62.0          # radius of the planet disc

# The two rings, outermost first (base painting order) -- the logo's pair.
# Disjoint radial ranges are what make the weave derivable -- see the module
# docstring.
RINGS = [
    dict(a=98.0, b=117.0, k=0.30, rot=-16.0, lane=108.0,
         dur="40s", ph="-25s", step="0.75s", spin="110s"),
    dict(a=79.0, b=92.0, k=0.52, rot=38.0, lane=85.5,
         dur="28s", ph="-11s", step="0.6s", spin="70s"),
]

CAST_DX, CAST_DY = 3.0, 5.0     # screen offset of the rings' shadow on the disc
XSH_DX, XSH_DY = 2.2, 3.2       # screen offset of ring-on-ring crossing shadows

rng = random.Random(11)

OUT = pathlib.Path(__file__).resolve().parents[2] / "templates/partials/hero-rings.html"


def fmt(v, p=1):
    s = f"{v:.{p}f}".rstrip("0").rstrip(".")
    return s if s not in ("-0", "") else "0"


def smooth(a, b, x):
    """0 before a, 1 after b, smoothstep between."""
    if x <= a:
        return 0.0
    if x >= b:
        return 1.0
    t = (x - a) / (b - a)
    return t * t * (3 - 2 * t)


def bump(x, mu, s):
    return math.exp(-(((x - mu) / s) ** 2))


def ringlets(r, ph):
    """Fine radial texture, a fixed sum of incommensurate waves in [-1, 1]."""
    return (0.5 * math.sin(r * 2.13 + ph)
            + 0.3 * math.sin(r * 3.71 + 0.4 + ph)
            + 0.15 * math.sin(r * 5.10 + 2.9 + ph))


def window(r, a, b, e=1.2):
    return smooth(a, a + e, r) - smooth(b - e, b, r)


def band_alpha(i, r):
    """Ring i's opacity profile: a luminous tube, not a flat tape -- a soft
    translucent body swelling toward a bright mid-radius, one thin lane and
    one faint gap for texture."""
    if i == 0:
        win = window(r, 98.4, 116.8, 2.2)
        core = win * (0.30 + 0.26 * bump(r, 107.0, 4.2))
        core += 0.10 * bump(r, 103.0, 0.7) * win
        core *= 1 - 0.28 * (smooth(110.6, 111.2, r) - smooth(112.0, 112.6, r))
        tex = 1 + 0.07 * ringlets(r, 1.7)
    else:
        win = window(r, 79.2, 91.9, 2.0)
        core = win * (0.34 + 0.28 * bump(r, 85.3, 3.0))
        core += 0.08 * bump(r, 82.4, 0.6) * win
        core *= 1 - 0.22 * (smooth(88.2, 88.7, r) - smooth(89.4, 89.9, r))
        tex = 1 + 0.06 * ringlets(r, 0.2)
    return min(0.94, max(0.0, core * tex))


# The hot core streak riding each tube's mid-radius: (centre, width).
HI_CORE = [(107.0, 3.6), (85.3, 2.6)]


# --- transforms -------------------------------------------------------------

def lin(i):
    """Ring i's linear screen map: rotate(rot) * scale(1, k)."""
    R = RINGS[i]
    c, s = math.cos(math.radians(R["rot"])), math.sin(math.radians(R["rot"]))
    return (c, s, -R["k"] * s, R["k"] * c)     # columns of the 2x2 matrix


def inv(m):
    a, b, c, d = m
    det = a * d - b * c
    return (d / det, -b / det, -c / det, a / det)


def mul(m, n):
    a, b, c, d = m
    e, f, g, h = n
    return (a * e + c * f, b * e + d * f, a * g + c * h, b * g + d * h)


def apply(m, v):
    a, b, c, d = m
    return (a * v[0] + c * v[1], b * v[0] + d * v[1])


def plane(i):
    R = RINGS[i]
    return (f'transform="translate({fmt(C)} {fmt(C)}) '
            f'rotate({fmt(R["rot"])}) scale(1 {fmt(R["k"], 2)})"')


def matrix(m, t=(0.0, 0.0)):
    a, b, c, d = m
    return (f'transform="matrix({fmt(a, 4)} {fmt(b, 4)} {fmt(c, 4)} {fmt(d, 4)} '
            f'{fmt(t[0], 2)} {fmt(t[1], 2)})"')


def depth_grad(i):
    """z_i(p) as a screen gradient: sqrt(1-k^2)/k times local y."""
    a, b, c, d = inv(lin(i))
    cb = math.sqrt(1 - RINGS[i]["k"] ** 2) / RINGS[i]["k"]
    return (cb * b, cb * d)    # row y of the inverse, scaled


# Pair half-planes: for i < j, z_i(p) - z_j(p) = n . (p - C) with n constant.
# The line n . (p - C) = 0 is where the two sheets would be equally deep --
# and since equal depth at equal screen point means the same 3D point, which
# disjoint radii forbid, this hard clip edge never crosses paint where both
# bands have material.
def half_angle(i, j):
    wi, wj = depth_grad(i), depth_grad(j)
    n = (wi[0] - wj[0], wi[1] - wj[1])
    return math.degrees(math.atan2(n[1], n[0]))


# --- per-ring markup pieces -------------------------------------------------

def band_stops(i):
    R = RINGS[i]
    lines, r = [], R["a"] - 1.5
    while r <= R["b"] + 1.5 + 1e-6:
        lines.append(f'        <stop offset="{fmt(r / (R["b"] + 2), 4)}" stop-color="#fff" '
                     f'stop-opacity="{fmt(band_alpha(i, r), 3)}"/>')
        r += 0.3
    return "\n".join(lines)


def hi_stops(i):
    """The core streak as sampled gradient stops."""
    R = RINGS[i]
    mid, w = HI_CORE[i]
    pts = [mid + t * w for t in (-2.2, -1.6, -1.0, -0.5, 0.0, 0.5, 1.0, 1.6, 2.2)]
    return "\n".join(f'        <stop class="rs-hi" offset="{fmt(r / (R["b"] + 2), 4)}" '
                     f'stop-opacity="{fmt(0.5 * bump(r, mid, w), 3)}"/>' for r in pts)


# The halo: a thin bright rim hugging each tube's outer edge -- a crisp
# contour, not a diffuse glow. (centre, width, peak) per ring; the centre
# sits just past the band's outer radius so the rim reads as a clean edge
# line on the page rather than a wash bleeding into it.
GLOW = [(118.5, 1.5, 0.5), (93.2, 1.3, 0.5)]


def glow_extent(i):
    """The rim's own radius: far enough out that the bump has died to zero
    within it. The rect it fills is this big too, so the gradient's pad
    region (a radialGradient holds its last stop past offset 1) is never
    seen -- otherwise the square corners glow faintly."""
    mid, w, _ = GLOW[i]
    return mid + 3.4 * w


def glow_stops(i):
    mid, w, pk = GLOW[i]
    ge = glow_extent(i)
    lines, r = [], max(0.0, mid - 3.4 * w)
    while r <= ge + 1e-6:
        a = pk * bump(r, mid, w)
        lines.append(f'        <stop class="rs-glow" offset="{fmt(r / ge, 4)}" '
                     f'stop-opacity="{fmt(a, 3)}"/>')
        r += w / 3
    return "\n".join(lines)


def arc(r, a0, span):
    a1 = a0 + span
    x0, y0 = r * math.cos(a0), r * math.sin(a0)
    x1, y1 = r * math.cos(a1), r * math.sin(a1)
    la = 1 if span > math.pi else 0
    return f"M{fmt(x0)} {fmt(y0)}A{fmt(r)} {fmt(r)} 0 {la} 1 {fmt(x1)} {fmt(y1)}"


def make_grain(i, n_dark, n_light, n_clump):
    """Streaks of orbiting ring material. They carry NO mask: a streak sits
    at one radius, where the band's alpha is a constant, so that alpha is
    baked into the streak's own opacity instead. That keeps every animated
    element outside every mask -- the masked band sheets stay static and
    cacheable, and the per-frame work is a few dozen plain strokes. The two
    anchor dots pin the group's fill-box centre to the ring centre, so the
    CSS spin cannot wobble no matter where the random streaks land."""
    R = RINGS[i]
    e = R["b"] + 2
    lines = [f'<g class="ring-grain ring-grain-r{i}">',
             f'  <circle class="rg-anchor" cx="{fmt(-e)}" cy="{fmt(-e)}" r="0.01" fill="none"/>',
             f'  <circle class="rg-anchor" cx="{fmt(e)}" cy="{fmt(e)}" r="0.01" fill="none"/>']

    def streak(cls, w_lo, w_hi, o_lo, o_hi, s_lo=28, s_hi=130):
        r = rng.uniform(R["a"] + 0.4, R["b"] - 0.4)
        op = rng.uniform(o_lo, o_hi) * band_alpha(i, r)
        if op < 0.015:
            return
        lines.append(f'  <path class="{cls}" stroke-width="{fmt(rng.uniform(w_lo, w_hi), 2)}" '
                     f'opacity="{fmt(op, 3)}" '
                     f'd="{arc(r, rng.uniform(0, 2 * math.pi), math.radians(rng.uniform(s_lo, s_hi)))}"/>')

    for _ in range(n_dark):
        streak("rg-d", 0.6, 1.4, 0.05, 0.12)
    for _ in range(n_light):
        streak("rg-l", 0.5, 1.1, 0.05, 0.11)
    for _ in range(n_clump):
        streak("rg-l", 0.9, 1.3, 0.14, 0.22, 2.5, 8)
    lines.append('</g>')
    return "\n".join(lines)


GRAIN = [make_grain(0, 14, 8, 3), make_grain(1, 10, 6, 2)]


def indented(text, pad):
    return "\n".join(pad + ln for ln in text.split("\n"))


def sheet_inner(i, pad):
    """Ring i's paint stack from the band mask inward: base colour,
    highlight wash, depth scrim -- all static, so the mask composites once
    and caches. The orbiting grain lives OUTSIDE this group (see
    grain_layer); repaints and front caps simply omit it."""
    R = RINGS[i]
    e = fmt(R["b"] + 2)
    side = fmt(2 * (R["b"] + 2))
    rect = f'<rect x="-{e}" y="-{e}" width="{side}" height="{side}"'
    return "\n".join([
        f'{pad}<g mask="url(#rgMask{i})">',
        f'{pad}  {rect} class="ring-fill"/>',
        f'{pad}  {rect} fill="url(#rgHi{i})"/>',
        f'{pad}  {rect} fill="url(#rgDepth{i})"/>',
        f'{pad}  {rect} fill="url(#rgLume{i})"/>',
        f'{pad}</g>'])


def grain_layer(i):
    """Ring i's spinning grain, over the band sheet with a second masked
    copy of the depth scrim above it so the far side still dims the
    streaks. Both masked neighbours are static; only plain strokes move."""
    R = RINGS[i]
    e = fmt(R["b"] + 2)
    side = fmt(2 * (R["b"] + 2))
    return "\n".join([
        f'    <g {plane(i)}>',
        indented(GRAIN[i], "      "),
        f'      <g mask="url(#rgMask{i})">',
        f'        <rect x="-{e}" y="-{e}" width="{side}" height="{side}" fill="url(#rgDepth{i})" opacity="0.6"/>',
        '      </g>',
        '    </g>'])


def cross_shadow(under, over, pad):
    """The over band's soft displaced shadow, shaped by its own mask and
    laid only on the under band's material. Lives inside the under ring's
    face-on space."""
    m = mul(inv(lin(under)), lin(over))
    t = apply(inv(lin(under)), (XSH_DX, XSH_DY))
    e = RINGS[over]["b"] + 2
    rect = (f'<rect x="-{fmt(e)}" y="-{fmt(e)}" width="{fmt(2 * e)}" height="{fmt(2 * e)}" '
            f'class="ring-cast-fill"/>')
    return "\n".join([
        f'{pad}<g mask="url(#rgMask{under})">',
        f'{pad}  <g {matrix(m, t)} filter="url(#rgSoft)" opacity="0.18">',
        f'{pad}    <g mask="url(#rgMask{over})">',
        f'{pad}      {rect}',
        f'{pad}    </g>',
        f'{pad}  </g>',
        f'{pad}</g>'])


def under_shadow(i, j, front):
    """Base-order side of pair (i, j): j paints later, so where j is the
    nearer sheet its shadow must land on i just before j paints."""
    lines = [f'    <g clip-path="url(#rgHm{i}{j})">',
             f'      <g {plane(i)}>']
    if front:
        lines.append('        <g clip-path="url(#rgNear)">')
    lines.append(cross_shadow(i, j, "          " if front else "        "))
    if front:
        lines.append('        </g>')
    lines += ['      </g>', '    </g>']
    return "\n".join(lines)


def patch(i, j, front):
    """Ring i repainted over ring j on the safe side of their line, weighted
    by ring j's band alpha so the repaint has no boundary of its own."""
    m = mul(inv(lin(j)), lin(i))
    pad = "            " if front else "          "
    lines = [f'    <g clip-path="url(#rgHp{i}{j})">',
             f'      <g {plane(j)}>']
    if front:
        lines.append('        <g clip-path="url(#rgNear)">')
    lines.append(f'        <g mask="url(#rgMask{j})">')
    lines.append(cross_shadow(j, i, pad))
    lines.append(f'          <g {matrix(m)}>')
    if front:
        lines.append('            <g clip-path="url(#rgNear)">')
    lines.append(sheet_inner(i, pad))
    if front:
        lines.append('            </g>')
    lines.append('          </g>')
    lines.append('        </g>')
    if front:
        lines.append('        </g>')
    lines += ['      </g>', '    </g>']
    return "\n".join(lines)


def base_sheet(i):
    return "\n".join([f'    <g {plane(i)}>', sheet_inner(i, "      "), '    </g>'])


def halo_layer(i):
    """A thin bright rim hugging the tube's outer edge -- a crisp halo, not a
    diffuse glow. The band is radially symmetric in ring space, so the rim is
    just a narrow radial gradient (rgGlow{i}) painted straight onto a rect --
    NO mask and NO blur filter. This matters for cost, not just tidiness: an
    SVG re-rasterizes as a whole whenever anything inside it animates, so a
    live feGaussianBlur here would re-run every frame the rings turn. A
    gradient fill is nearly free to re-raster."""
    ge = fmt(glow_extent(i))
    gside = fmt(2 * glow_extent(i))
    return "\n".join([
        f'    <g {plane(i)}>',
        f'      <rect x="-{ge}" y="-{ge}" width="{gside}" height="{gside}" fill="url(#rgGlow{i})"/>',
        '    </g>'])


def front_cap(i):
    """Ring i's near half again, only across the planet's face; the circle
    clip edge hides under the rim stroke, and the half-plane cut lies at
    radii the disc never reaches."""
    return "\n".join([
        '    <g clip-path="url(#rgDiscLip)">',
        f'      <g {plane(i)}>',
        '        <g clip-path="url(#rgNear)">',
        sheet_inner(i, "          "),
        '        </g>',
        '      </g>',
        '    </g>'])


def planet_shade(i):
    """The planet's shadow on ring i's sheet behind it: ambient rim
    darkening plus a cast lobe pushed away from the upper-left light, faded
    out toward the lit horizon so the shadow needs no hard cut of its own."""
    return "\n".join([
        f'    <g {plane(i)}>',
        '      <g mask="url(#rgShadowFade)">',
        f'        <g mask="url(#rgMask{i})">',
        f'          <rect x="-125" y="-125" width="250" height="250" fill="url(#rgAo{i})"/>',
        f'          <rect x="-125" y="-125" width="250" height="250" fill="url(#rgCast{i})"/>',
        '        </g>',
        '      </g>',
        '    </g>'])


def nodes(kind):
    """One head and three trail dots per lane. The same dots exist twice,
    once behind the disc and once in front; complementary opacity windows in
    the motion CSS mean each lap shows the front copies for the near half and
    the back copies for the far half -- real occlusion, not a fade."""
    lines = [f'    <g class="ring-nodes ring-nodes-{kind}">']
    for i in range(len(RINGS)):
        for kk, r in enumerate([3.6, 2.6, 2.0, 1.5]):
            lines.append(f'      <circle class="ring-node rn-r{i} rn-t{kk}" r="{r}" '
                         f'fill="url(#rgNodeGlow)"/>')
    lines.append("    </g>")
    return "\n".join(lines)


def lane_path(i):
    """The lane's projected ellipse, starting at a horizon, near half first
    (which is what the front/back opacity windows in the CSS assume)."""
    R = RINGS[i]
    r, t = R["lane"], math.radians(R["rot"])

    def pt(th):
        x, y = r * math.cos(th), R["k"] * r * math.sin(th)
        return (C + x * math.cos(t) - y * math.sin(t),
                C + x * math.sin(t) + y * math.cos(t))

    x0, y0 = pt(0.0)
    xh, yh = pt(math.pi)
    rx, ry = fmt(r), fmt(R["k"] * r)
    return (f"M{fmt(x0)} {fmt(y0)}A{rx} {ry} {fmt(R['rot'])} 0 1 {fmt(xh)} {fmt(yh)}"
            f"A{rx} {ry} {fmt(R['rot'])} 0 1 {fmt(x0)} {fmt(y0)}")


# --- defs -------------------------------------------------------------------

def ring_defs(i):
    R = RINGS[i]
    e = fmt(R["b"] + 2)
    inv_k = fmt(1 / R["k"], 3)
    cb = math.sqrt(1 - R["k"] ** 2)
    cast_c = apply(inv(lin(i)), (12.0, 5.0))
    return f"""      <radialGradient id="rgBands{i}" gradientUnits="userSpaceOnUse" cx="0" cy="0" r="{e}">
{band_stops(i)}
      </radialGradient>
      <mask id="rgMask{i}" maskUnits="userSpaceOnUse" x="-125" y="-125" width="250" height="250">
        <circle cx="0" cy="0" r="{e}" fill="url(#rgBands{i})"/>
      </mask>
      <radialGradient id="rgHi{i}" gradientUnits="userSpaceOnUse" cx="0" cy="0" r="{e}">
{hi_stops(i)}
      </radialGradient>
      {{# The halo: the band's glow as a plain radial gradient (no mask, no
         blur), so it costs nothing to re-raster when the rings turn. Its
         radius reaches past where the glow dies to zero, so the gradient's
         pad region never shows as a faint square. #}}
      <radialGradient id="rgGlow{i}" gradientUnits="userSpaceOnUse" cx="0" cy="0" r="{fmt(glow_extent(i))}">
{glow_stops(i)}
      </radialGradient>
      <linearGradient id="rgDepth{i}" gradientUnits="userSpaceOnUse" x1="0" y1="-{e}" x2="0" y2="{e}">
        <stop class="rs-lo" offset="0" stop-opacity="{fmt(0.52 * cb, 3)}"/>
        <stop class="rs-lo" offset="0.42" stop-opacity="{fmt(0.25 * cb, 3)}"/>
        <stop class="rs-lo" offset="0.5" stop-opacity="{fmt(0.14 * cb, 3)}"/>
        <stop class="rs-lo" offset="0.66" stop-opacity="{fmt(0.03 * cb, 3)}"/>
        <stop class="rs-lo" offset="1" stop-opacity="0"/>
      </linearGradient>
      {{# The near rim of the tube catching the light: a glow that rises
         toward the front horizon, so a spinning band brightens as it comes
         round to the front. #}}
      <linearGradient id="rgLume{i}" gradientUnits="userSpaceOnUse" x1="0" y1="-{e}" x2="0" y2="{e}">
        <stop class="rs-glow" offset="0" stop-opacity="0"/>
        <stop class="rs-glow" offset="0.5" stop-opacity="0"/>
        <stop class="rs-glow" offset="0.7" stop-opacity="0.05"/>
        <stop class="rs-glow" offset="0.86" stop-opacity="0.12"/>
        <stop class="rs-glow" offset="1" stop-opacity="0.2"/>
      </linearGradient>
      <radialGradient id="rgAo{i}" gradientUnits="userSpaceOnUse" cx="0" cy="0" r="112"
                      gradientTransform="scale(1 {inv_k})">
        <stop class="rs-sh" offset="0.55" stop-opacity="0.4"/>
        <stop class="rs-sh" offset="0.67" stop-opacity="0.16"/>
        <stop class="rs-sh" offset="0.83" stop-opacity="0.05"/>
        <stop class="rs-sh" offset="1" stop-opacity="0"/>
      </radialGradient>
      <radialGradient id="rgCast{i}" gradientUnits="userSpaceOnUse" cx="{fmt(cast_c[0])}" cy="{fmt(cast_c[1])}" r="108"
                      gradientTransform="scale(1 {inv_k})">
        <stop class="rs-sh" offset="0.55" stop-opacity="0.38"/>
        <stop class="rs-sh" offset="0.76" stop-opacity="0.14"/>
        <stop class="rs-sh" offset="1" stop-opacity="0"/>
      </radialGradient>"""


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
    """Static gold dust: most of it strewn along the two ring planes, the
    rest scattered in a loose donut around the whole system."""
    lines = ['    <g class="ring-dust">']

    def dot(x, y):
        lines.append(f'      <circle cx="{fmt(x)}" cy="{fmt(y)}" r="{fmt(rng.uniform(0.3, 0.85), 2)}" '
                     f'opacity="{fmt(rng.uniform(0.08, 0.42), 2)}"/>')

    for i in range(len(RINGS)):
        R = RINGS[i]
        for _ in range(26):
            th = rng.uniform(0, 2 * math.pi)
            rr = rng.uniform(R["a"] - 9, R["b"] + 11)
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
    base_stack.append(halo_layer(j))
    base_stack.append(base_sheet(j))
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
    "\n".join([f'            <g {plane(i)}>',
               '              <g clip-path="url(#rgNear)">',
               f'                <rect x="-125" y="-125" width="250" height="250" '
               f'class="ring-cast-fill" mask="url(#rgMask{i})"/>',
               '              </g>',
               '            </g>']) for i in range(N))

doc = f"""{{# The hero mark: three broad translucent rings crossing around the
   official art disc -- an armillary, not a Saturn. Generated geometry: each
   ring is a flat annular sheet in its own plane (disjoint radii), its band
   structure a radial opacity profile used as a luminance mask; the painter's
   over/under order at every crossing is derived from the sheets' linear
   depth fields, and repaints are weighted by the other ring's mask so no
   translucent paint is ever split along a visible edge. The stylesheet owns
   all colour and motion.
   Re-generate (tools/hero-rings/build.py) rather than edit by hand. #}}
<figure class="hero-art">
  <svg class="hero-rings" viewBox="0 0 240 240" role="img" aria-label="{{{{ "home.hero_art_alt" | t }}}}">
    <defs>
{chr(10).join(ring_defs(i) for i in range(N))}
{pair_defs()}
      <clipPath id="rgNear"><rect x="-125" y="0" width="250" height="125"/></clipPath>
      <clipPath id="rgDiscLip"><circle cx="{fmt(C)}" cy="{fmt(C)}" r="{fmt(DISC + 0.3)}"/></clipPath>
      <clipPath id="rgDisc"><circle cx="{fmt(C)}" cy="{fmt(C)}" r="{fmt(DISC)}"/></clipPath>
      {{# Fades the planet's shadow out as a sheet comes round into the
         light, so the shadow needs no hard half-plane cut of its own. #}}
      <linearGradient id="rgFadeY" gradientUnits="userSpaceOnUse" x1="0" y1="-10" x2="0" y2="4">
        <stop offset="0" stop-color="#fff"/>
        <stop offset="1" stop-color="#000"/>
      </linearGradient>
      <mask id="rgShadowFade" maskUnits="userSpaceOnUse" x="-125" y="-125" width="250" height="250">
        <rect x="-125" y="-125" width="250" height="250" fill="url(#rgFadeY)"/>
      </mask>
      <linearGradient id="rgSheen" gradientUnits="userSpaceOnUse"
                      x1="{fmt(C - DISC)}" y1="{fmt(C - DISC)}" x2="{fmt(C + DISC)}" y2="{fmt(C + DISC)}">
        <stop class="ring-s0" offset="0"/>
        <stop class="ring-s1" offset="0.42"/>
        <stop class="ring-s2" offset="1"/>
      </linearGradient>
      <filter id="rgSoft"><feGaussianBlur stdDeviation="1.7"/></filter>
      {{# The traffic dots' glow, baked into a gradient fill: a filter here
         would re-blur every moving dot every frame. #}}
      <radialGradient id="rgNodeGlow">
        <stop class="rs-glow" offset="0" stop-opacity="1"/>
        <stop class="rs-glow" offset="0.4" stop-opacity="0.8"/>
        <stop class="rs-glow" offset="0.72" stop-opacity="0.28"/>
        <stop class="rs-glow" offset="1" stop-opacity="0"/>
      </radialGradient>
    </defs>

    {{# Gold dust strewn along the ring planes and loosely around them. #}}
{dust()}

    {{# The sheets behind the planet, woven back to front, then the
       planet's own shadow across whatever lies behind it. #}}
{chr(10).join(base_stack)}
{nodes("back")}

    {{# The planet. Not in any ring group: the art holds still while the
       rings turn around it. The near bands' shadow falls across its face,
       displaced from the bands toward the lower right. #}}
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
          f'offset-path: path("{lane_path(i)}"); }}')
print()
for i, R in enumerate(RINGS):
    print(f'  .ring-grain-r{i} {{ animation: ring-turn {R["spin"]} linear infinite; }}')
