#!/usr/bin/env python3
"""Render a `tmux capture-pane -e -p` dump (truecolor ANSI) into a self-contained SVG.

The SVG is a faithful, grid-aligned screenshot of a real terminal frame: every
cell is placed on an exact monospace grid using textLength + lengthAdjust so the
output aligns regardless of the viewer's monospace font. No external assets.
"""
import sys, re, html, argparse

# Sentinels: a cell painted with no explicit colour inherits the detected
# dominant theme colour at render time (keeps the renderer theme-agnostic).
DEF_FG = None
DEF_BG = None
RESET_FG = (200, 200, 204)
RESET_BG = (10, 10, 11)

# xterm 256-color -> rgb
def xterm256(n):
    if n < 16:
        base = [(0,0,0),(205,49,49),(13,188,121),(229,229,16),(36,114,200),
                (188,63,188),(17,168,205),(229,229,229),(102,102,102),(241,76,76),
                (35,209,139),(245,245,67),(59,142,234),(214,112,214),(41,184,219),(255,255,255)]
        return base[n]
    if n >= 232:
        v = 8 + (n-232)*10
        return (v,v,v)
    n -= 16
    r = n // 36; g = (n % 36) // 6; b = n % 6
    conv = lambda c: 0 if c == 0 else 55 + c*40
    return (conv(r), conv(g), conv(b))

class Cell:
    __slots__ = ("ch","fg","bg","bold")
    def __init__(s, ch=" ", fg=DEF_FG, bg=DEF_BG, bold=False):
        s.ch=ch; s.fg=fg; s.bg=bg; s.bold=bold

def parse(text):
    rows = []
    fg, bg, bold, rev = DEF_FG, DEF_BG, False, False
    ansi = re.compile(r"\x1b\[([0-9;]*)m")
    for line in text.split("\n"):
        cells = []
        i = 0
        while i < len(line):
            m = ansi.match(line, i)
            if m:
                params = m.group(1)
                nums = [int(x) if x else 0 for x in params.split(";")] if params else [0]
                j = 0
                while j < len(nums):
                    c = nums[j]
                    if c == 0: fg,bg,bold,rev = DEF_FG,DEF_BG,False,False
                    elif c == 1: bold = True
                    elif c == 22: bold = False
                    elif c == 7: rev = True
                    elif c == 27: rev = False
                    elif c == 39: fg = DEF_FG
                    elif c == 49: bg = DEF_BG
                    elif 30 <= c <= 37: fg = xterm256(c-30)
                    elif 90 <= c <= 97: fg = xterm256(c-90+8)
                    elif 40 <= c <= 47: bg = xterm256(c-40)
                    elif 100 <= c <= 107: bg = xterm256(c-100+8)
                    elif c == 38 or c == 48:
                        if j+1 < len(nums) and nums[j+1] == 2:
                            col = (nums[j+2], nums[j+3], nums[j+4]); j += 4
                            if c == 38: fg = col
                            else: bg = col
                        elif j+1 < len(nums) and nums[j+1] == 5:
                            col = xterm256(nums[j+2]); j += 2
                            if c == 38: fg = col
                            else: bg = col
                    j += 1
                i = m.end()
                continue
            ch = line[i]
            f, b = (bg, fg) if rev else (fg, bg)
            cells.append(Cell(ch, f, b, bold))
            i += 1
        rows.append(cells)
    return rows

def hexc(c): return "#%02x%02x%02x" % c
def lum(c): return (0.2126*c[0] + 0.7152*c[1] + 0.0722*c[2]) / 255.0
def mix(a, b, t): return tuple(round(a[i]+(b[i]-a[i])*t) for i in range(3))

def render(rows, title, fs=15.0, pad=18.0):
    cw = fs*0.60
    ch = fs*1.20
    cols = max((len(r) for r in rows), default=0)
    # trim trailing fully-blank rows
    while rows and all(c.ch == " " for c in rows[-1]):
        rows.pop()
    nrows = len(rows)

    # Detect the theme's dominant background / foreground so the renderer is
    # palette-agnostic (works for light themes too). Unstyled cells inherit these.
    from collections import Counter
    bgc, fgc = Counter(), Counter()
    for row in rows:
        for c in row:
            if c.bg is not None: bgc[c.bg] += 1
            if c.fg is not None: fgc[c.fg] += 1
    dom_bg = bgc.most_common(1)[0][0] if bgc else RESET_BG
    dom_fg = fgc.most_common(1)[0][0] if fgc else RESET_FG
    for row in rows:
        for c in row:
            if c.bg is None: c.bg = dom_bg
            if c.fg is None: c.fg = dom_fg

    dark = lum(dom_bg) < 0.5
    ink = (255, 255, 255) if dark else (0, 0, 0)
    chrome_bg = mix(dom_bg, ink, 0.06)          # titlebar
    border_col = mix(dom_bg, ink, 0.16)         # outer hairline
    label_col = mix(dom_bg, ink, 0.55)          # window title text

    titleh = 34.0 if title is not None else 0.0
    W = cols*cw + pad*2
    H = nrows*ch + pad*2 + titleh
    aria = html.escape(title or "gori terminal screenshot")
    out = []
    out.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.0f}" height="{H:.0f}" '
               f'viewBox="0 0 {W:.1f} {H:.1f}" font-family="ui-monospace,\'SF Mono\',\'JetBrains Mono\',Menlo,Consolas,monospace" '
               f'font-size="{fs:.1f}px" role="img" aria-label="{aria}">')
    out.append(f'<rect x="0.5" y="0.5" width="{W-1:.1f}" height="{H-1:.1f}" rx="10" ry="10" '
               f'fill="{hexc(dom_bg)}" stroke="{hexc(border_col)}" stroke-width="1"/>')
    if title is not None:
        # slim window chrome
        out.append(f'<rect x="1" y="1" width="{W-2:.1f}" height="{titleh:.1f}" rx="10" ry="10" fill="{hexc(chrome_bg)}"/>')
        out.append(f'<rect x="1" y="{titleh-10:.1f}" width="{W-2:.1f}" height="10" fill="{hexc(chrome_bg)}"/>')
        for k,(cx,col) in enumerate([(0,"#e0645f"),(1,"#e0b24f"),(2,"#4fb06a")]):
            out.append(f'<circle cx="{pad+cx*16:.1f}" cy="{titleh/2:.1f}" r="5.5" fill="{col}"/>')
        out.append(f'<text x="{W/2:.1f}" y="{titleh/2+5:.1f}" text-anchor="middle" '
                   f'fill="{hexc(label_col)}" font-size="{fs*0.82:.1f}px">{html.escape(title)}</text>')
    y0 = pad + titleh
    body = []
    txt = []
    for ri, row in enumerate(rows):
        yb = y0 + ri*ch
        # background runs
        ci = 0
        while ci < len(row):
            cell = row[ci]
            if cell.bg != dom_bg:
                cj = ci
                while cj < len(row) and row[cj].bg == cell.bg:
                    cj += 1
                x = pad + ci*cw
                body.append(f'<rect x="{x:.2f}" y="{yb:.2f}" width="{(cj-ci)*cw:.2f}" height="{ch:.2f}" fill="{hexc(cell.bg)}"/>')
                ci = cj
            else:
                ci += 1
        # foreground runs (skip spaces)
        ci = 0
        ytext = yb + ch*0.76
        while ci < len(row):
            cell = row[ci]
            if cell.ch == " ":
                ci += 1; continue
            cj = ci
            while cj < len(row) and row[cj].ch != " " and row[cj].fg == cell.fg and row[cj].bold == cell.bold:
                cj += 1
            run = "".join(row[k].ch for k in range(ci, cj))
            x = pad + ci*cw
            tl = (cj-ci)*cw
            wt = ' font-weight="700"' if cell.bold else ''
            txt.append(f'<text x="{x:.2f}" y="{ytext:.2f}" textLength="{tl:.2f}" lengthAdjust="spacingAndGlyphs" '
                       f'fill="{hexc(cell.fg)}"{wt} xml:space="preserve">{html.escape(run)}</text>')
            ci = cj
    out.extend(body)
    out.extend(txt)
    out.append('</svg>')
    return "\n".join(out)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("infile")
    ap.add_argument("outfile")
    ap.add_argument("--title", default=None)
    ap.add_argument("--fs", type=float, default=15.0)
    a = ap.parse_args()
    with open(a.infile, "r", encoding="utf-8", errors="replace") as f:
        data = f.read()
    rows = parse(data)
    svg = render(rows, a.title, fs=a.fs)
    with open(a.outfile, "w", encoding="utf-8") as f:
        f.write(svg)
    print(f"wrote {a.outfile} ({len(svg)} bytes)")
