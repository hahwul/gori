+++
title = "Screenshot"
description = "Turn any pane into an SVG, PNG, ANSI dump, or plain text — from the keyboard, the shell, or an agent."
weight = 130

[extra]
group = "Customize"
+++

A screenshot is the real chrome — the shipping UI, not a mock — written to a file: the exact frame the backend last put on the glass, with menus down and the project's redaction profile painted over it. Two things earn a row here that a JSON export cannot. A picture is **evidence** — the exact layout that proved a finding, dropped straight into a report or an issue. And a picture is what an **agent** actually needs when the question is "what does this pane look like", not "what rows does it hold": a chart, a badge, a wrapped column — shape the JSON tools cannot say.

All three surfaces draw through the same seam, `Tui::Headless.render` booting the same `Runner` `gori` boots — so a shot in a bug report, a README, or an agent's transcript is the version that actually ships, never a mock that drifts from it.

## From the TUI

Two palette entries, both `Ctrl-P`:

| Verb | Palette label | What it does |
|------|----------------|--------------|
| `screenshot` | **Screenshot** | Writes the current screen straight to a file — format and directory come from [`settings:screenshot`](#settings) |
| `screenshot.save-as` | **Screenshot to…** | Opens an export card prefilled with the settings default; the extension you type (`.svg`, `.png`, `.ansi`, `.txt`) picks the format |

Both also show up in the space menu (`Space`) and in Help. Neither has a key binding: the Global bare-letter budget is already spent on `c`/`i`/`s`, and a picture of a live engagement should cost a deliberate palette entry rather than a stray keypress.

The shot is of the **screen as it is**, with one adjustment: the palette and the space menu close themselves first, so you never get a picture of the menu you opened to reach the verb. Everything else stays — an open detail pane, a scrolled list, a card you have up — **is** photographed, because that is usually the thing worth capturing.

On write, the toast says what happened and where it landed:

```text
screenshot written · SANITIZED (3) · /Users/you/.gori/screenshots/acme-history-20260918-141205.svg
```

`SANITIZED (N)` only appears when a redaction profile actually ran and covered something; see [Redaction](#redaction) below.

### Settings {#settings}

Preferences (`Ctrl-,`) → **Appearance** → **Screenshot**, or **`settings:screenshot`** in the palette:

| Field | Default | Meaning |
|-------|---------|---------|
| Format | `svg` | What **Screenshot** writes: `svg`, `png`, `ansi`, or `txt` |
| Directory | *(empty)* | Where it lands. Blank means `~/.gori/screenshots/` |
| PNG scale | `2` | Pixels per terminal cell edge, `1`–`8`. Only read for `png` |

The default filename is `<project>-<tab>-<YYYYmmdd-HHMMSS>.<format>`, with a `-2`, `-3`… suffix if that exact name is already taken — a burst of shots inside one second does not overwrite itself. Full field reference: [`screenshot` in the configuration reference](/reference/config/#screenshot).

## Headless, from the shell

`gori run screenshot` (alias `shot`) draws the same TUI with no terminal attached, against an offscreen terminal (132×38 by default — the shape gori's own docs are captured at, `--size WxH` for another), and writes the frame out. The project opens **view-only**: no port bound, no capture lock taken, the active-project pointer untouched.

```bash
# SVG of the current project's home tab, default size
gori run screenshot

# Jump to a tab, then draw it
gori run screenshot --tab history -o history.svg

# Navigate first, in tmux send-keys grammar, then draw
gori run screenshot --tab repeater --keys 'Down Down Enter' -o repeater.svg

# A specific theme, so a doc shot matches the surrounding page
gori run screenshot --theme goriday --tab issues -o issues-light.svg

# A retina-ish PNG for somewhere that only takes a bitmap
gori run screenshot --format png --scale 2 -o docs/shot.png

# A gori running in another terminal — or one that has already ended
tmux capture-pane -e -p -t gori | gori run screenshot --from-ansi - -o remote.svg
```

`--keys` drives **navigation**, not waiting: a frame is a picture of the store as it is *right now*, so a Repeater send or a scan started by a key script is photographed mid-flight, never awaited. Point it at things that are already in the database — a tab, a filter, a selection — not at something async you just triggered.

Full flag table, every refusal, and the `--from-ansi` ingestion rules: [`run screenshot` in the CLI reference](/reference/cli/#run-screenshot).

## From an agent

The MCP `screenshot` tool draws the bound project the same way — real chrome, view-only, capture chip reading `off` — and returns the path it wrote. Pass `inline:true` to also get the picture back in the tool result: an `image/png` content block for PNG, the document itself as text for SVG/ANSI/TXT. It is refused past 1 MiB encoded, so an agent that wants a big shot narrows `cols`/`rows` instead of raising the limit.

```json
{
  "tab": "issues",
  "keys": "C-p \"acme\" Enter",
  "format": "png",
  "inline": true
}
```

It is a **gated write tool** — it puts a file on disk outside the project database, the one thing every other read tool never does — but it is not an `agent_action`: nothing in the project changes, nothing goes out on the wire, and an event-feed row per screenshot would bury the mutations that feed exists to surface. It is unavailable under `--read-only`. See [MCP tools](/guide/mcp/#tools) for the rest of the catalog, and the tool's own field list for `cols`/`rows`/`theme`/`scale`/`overwrite`/`include_sensitive`.

## Redaction {#redaction}

A screenshot of a live engagement is evidence, and it leaves gori's process the moment it is written — so the project's redaction profile is painted over the frame's **cells** before a single byte reaches disk, the same [redaction profile](/reference/cli/#run-redact) `--redact` on an export or the copy menu already applies to a body. `--redact`/`--no-redact` on the CLI and `include_sensitive` on the MCP tool are the two override switches; the TUI verbs always follow the project's ambient profile.

Being honest about the shape of it:

- **What is caught.** Body-shaped secrets, over the text a pane actually drew: a profile's own field names re-expressed as `"name": "value"` or `name=value`, its own patterns, and the two built-in credential shapes gori always looks for — a JWS compact serialization (a JWT) and a PEM private-key block. A secret soft-wrapped across two screen rows is rejoined before matching, so a long token wrapped mid-value in a narrow pane is still caught whole.
- **What is not.** Headers are outside every profile's scope everywhere in gori — the copy menu does not touch them either — so a header that happens to read `token=…` on screen is caught by the form-key rule like any other text, but a header value a profile does not otherwise name is not. A value cut short by column truncation (`sec…`) can fall below what a pattern needs to recognise. And the hex view draws bytes, not text — a matcher looking for `"password"` never sees a page of hex pairs.
- **The count is honest, and so is its absence.** A masked region wide enough carries the same `[REDACTED:…]` correlation tag a redacted export uses — two screenshots holding the same value carry the same tag. One too narrow is filled with `▒` instead: half a tag reads as a truncated secret. The toast's `SANITIZED (N)` only appears once a profile actually ran; no profile configured means no claim is made either way, which is a different statement from "ran, and found nothing" (`SANITIZED (0)`).

Redaction changes the **picture**, never the store — the captured bytes underneath are untouched, and a screenshot taken before and after enabling a profile of the same live session looks different while History still holds the same rows.

## Formats and fonts

| Format | What it is | Reach for it when |
|--------|------------|--------------------|
| `svg` (default) | Self-contained vector: window chrome, a `textLength`-aligned grid, `data-theme`/`-cols`/`-rows`/`-sanitized` attributes. Text stays selectable and searchable, and it is a few tens of KB | You want the crisp, small default — this is what gori's own docs are captured with |
| `png` | A raster image, rendered through an embedded bitmap font | Somewhere that only takes a bitmap: a chat, an issue tracker's paste box, an agent that reads images |
| `ansi` | Truecolor SGR escapes, CRLF row endings | You want to paste it back into a terminal, or re-ingest it later with `--from-ansi` |
| `txt` | Plain glyphs, no colour, no chrome | Grepping, diffing, or a place that strips everything else |

**PNG and the embedded font.** gori ships a subset of GNU Unifont 18.0.01 (SIL OFL 1.1) baked into the binary — Latin, Greek, Cyrillic, symbols, box-drawing, braille, kana, and every Hangul syllable — so a PNG needs no system font and no font server to render. CJK ideographs and emoji are outside the subset on purpose (they are the bulk of Unifont, and a terminal screenshot rarely needs them); a codepoint gori has no glyph for draws as **tofu**, a hollow box, never a silent blank. To render them anyway, drop a full Unifont `.hex` at `~/.gori/fonts/unifont.hex`, point `$GORI_SCREENSHOT_FONT` at one, or install the system `unifont` package — gori probes the usual Homebrew prefixes automatically. The external file is merged over the built-in subset — the external glyph wins.

**Anti-aliasing.** `--scale` is block replication, not resampling — every cell is drawn once and repeated `scale` times per edge, so glyph edges stay hard at any scale rather than smoothing out. For an anti-aliased bitmap, render the SVG instead and convert it:

```bash
gori run screenshot -o shot.svg
rsvg-convert shot.svg -o shot.png
```

## What a headless shot looks like

A `gori run screenshot` or MCP shot never captured anything, and it says so rather than pretending otherwise: the top bar's capture chip reads `off`, because this process never bound a port or took the capture lock — the real capturer, if there is one, is untouched. Everything else in the chrome is drawn exactly as it would be in an attached session, including the clock: it is `Time.local` at the moment of render, not a frozen or synthetic time, so two shots taken a minute apart show two different clocks even against the same unchanged project.
