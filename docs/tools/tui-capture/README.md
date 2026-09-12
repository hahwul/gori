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
   the same run. The OAST scene is the one shot whose data does **not** come off
   the wire: `seed_oast` writes a provider, an idle listener, and four callbacks
   straight into the throwaway DB, so nothing registers with a public interactsh
   server and no real source IP ends up in a published image (the addresses are
   RFC 5737 documentation ranges).
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

Requirements: `bash`, `tmux`, `python3`, `curl`, `sqlite3`, `jq` (the statusline scene's
command is a jq program).

Set `ONLY` to shoot a subset of the three groups (`scenes themes readme`):

```bash
ONLY=readme docs/tools/tui-capture/capture.sh   # just the README hero
```

Set `SCENES` to shoot named scenes only, which is what you want after fixing
one frame: every capture carries live timestamps and durations, so a full run
rewrites all of them and buries the change you meant to make.

```bash
ONLY=scenes SCENES=project docs/tools/tui-capture/capture.sh
ONLY=scenes SCENES="project issues" docs/tools/tui-capture/capture.sh
```

Captures are reproducible but not pixel-identical run to run (timestamps,
durations, and live response bodies vary), so eyeball the output before
committing. The theme gallery on the Themes page (`theme-<name>.svg`) is shot in
the same run by `shoot_themes` — the History scene under each gallery palette.

A scene on the bar reaches its tab by positional jump — the bar is nine numbered
slots, so `1`-`9` are Project · Target · History · Intercept · Repeater · Fuzzer ·
Probe · Issues · Notes and nothing else. A scene off the bar reaches its tab by
NAME, with `0` (Go to tab…), type, `↵`: that is what the guide tells a reader to
press, and it is the only navigation here that cannot silently retarget. A
positional jump is a position in `Chrome::TABS` minus `DEFAULT_HIDDEN`, and a tab
moving on or off the bar slides every digit to its right — the Decoder scene once
shipped a picture of the OAST tab for three weeks that way. When the catalog
changes, read the tab strip back out of a capture and fix the numbers.

`0` lands in the BODY (the picker drills in, like the palette's "Go to …"), so an
off-bar scene needs no `Tab` after it — and the tab it opens rides the far right
of the bar without a number until you leave it, which is supposed to be in the
shot.

`statusline.svg` is the one scene that edits `settings.json` before firing: the statusline
ships off, so there is nothing to photograph until a command is configured. It runs last in
`shoot_all` and puts the plain settings back, and it shoots the same History screen as the
first scene on purpose — the picture is about the extra row at the bottom, so the rest of
the frame has to be something the reader already recognises. Its command is a `jq` program
built inside `write_statusline_settings`; it deliberately prints only fields that come
straight off the live session (capture state, project, bind address, flow count, probe mode,
catch-all upstream), so `SCENES=statusline` gives the same row whether or not the Issues
scene has run first and promoted findings.

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

It is also the only shot with Miss Ring on (`write_settings <theme> companion`); she
ships off, and the doc scenes document the default install. Her corner is why
`seed_readme_extra` stops at ten: the flow list has to end a few rows short of
the bottom or she covers live SIZE/DUR cells.

## Render a single frame by hand

```bash
tmux capture-pane -e -p > frame.ansi          # from any gori tmux session
python3 ansi2svg.py frame.ansi frame.svg --title "gori · History"
```
