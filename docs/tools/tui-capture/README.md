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

Captures are reproducible but not pixel-identical run to run (timestamps,
durations, and live response bodies vary), so eyeball the output before
committing. The theme gallery on the Themes page (`theme-<name>.svg`) is shot in
the same run by `shoot_themes` — the History scene under each gallery palette.

## Render a single frame by hand

```bash
tmux capture-pane -e -p > frame.ansi          # from any gori tmux session
python3 ansi2svg.py frame.ansi frame.svg --title "gori · History"
```
