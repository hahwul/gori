# TUI screenshots

The terminal screenshots in the docs (`docs/static/images/tui/*.svg`) are **real
captures** of the gori TUI, not hand-drawn mock-ups. They are rendered to
self-contained SVG so they stay crisp at any size, weigh a few KB, and carry
their own theme colours (they blend into the dark docs and read as a card on the
light theme).

## How it works

1. `capture.sh` spins up a throwaway project under a temp `GORI_HOME`, seeds it
   with real traffic (httpbingo / github / example.com through the proxy), then
   drives a real TUI inside a `tmux` session and grabs each screen with
   `tmux capture-pane -e` (truecolor ANSI). Frames are shot at 132 columns so
   they read as a full-width terminal in the docs. After seeding, the script
   counts 5xx rows in the throwaway DB and reseeds if the upstream was flaky.
   The guided-tour shot (`tutorial.svg`) is captured from `gori tutorial` in
   the same run.
2. `ansi2svg.py` parses that ANSI into a cell grid and emits an SVG, placing each
   run of text with `textLength` + `lengthAdjust` so the monospace grid stays
   aligned regardless of the viewer's font. It auto-detects the theme's
   background, so light themes render correctly too.

Nothing here touches your real `~/.gori`.

## Regenerate

```bash
shards build                       # ensure ./bin/gori exists
docs/tools/tui-capture/capture.sh  # writes docs/static/images/tui/*.svg
```

Requirements: `bash`, `tmux`, `python3`, `curl`, `sqlite3`.

Set `ONLY` to shoot a subset of the three groups (`scenes themes readme`):

```bash
ONLY=readme docs/tools/tui-capture/capture.sh   # just the README hero
```

Captures are reproducible but not pixel-identical run to run (timestamps,
durations, and live response bodies vary), so eyeball the output before
committing. The theme gallery on the Themes page (`theme-<name>.svg`) is shot in
the same run by `shoot_themes` — the History scene under each gallery palette.

`readme.svg` is its own shot (`shoot_readme`), not part of the doc set: the
repo README renders one image edge to edge with no sidebar, so it uses a much
wider 180x38 pane and tops the throwaway project up with extra traffic first.
It runs last, so the doc scenes above keep the smaller, stable flow set. It is
also the docs landing showcase, which swaps with the reader's theme, so it is
shot once per `SHOTS` palette like the scenes are (the traffic top-up happens
only on the first pass, so light and dark show the same flows).

Its window chrome carries the `𝓰𝓸𝓻𝓲` wordmark instead of a `gori · Scene`
caption — it stands for the tool, not for one screen. Decorative glyphs say
nothing out loud, so the shot passes `SHOT_ARIA` and `ansi2svg.py` writes that
as the SVG's `aria-label` instead of the title.

It is also the only shot with Miss Ring on (`write_settings <theme> pet`); she
ships off, and the doc scenes document the default install. Her corner is why
`seed_readme_extra` stops at ten: the flow list has to end a few rows short of
the bottom or she covers live SIZE/DUR cells.

## Render a single frame by hand

```bash
tmux capture-pane -e -p > frame.ansi          # from any gori tmux session
python3 ansi2svg.py frame.ansi frame.svg --title "gori · History"
```
