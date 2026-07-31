#!/usr/bin/env bash
#
# capture.sh — regenerate the TUI screenshots under docs/static/images/tui/.
#
# It drives a real gori TUI inside an isolated tmux session against a throwaway
# project seeded with real traffic, grabs each screen as truecolor ANSI
# (tmux capture-pane -e), and renders every frame to a self-contained SVG with
# ansi2svg.py. Nothing here touches your real ~/.gori.
#
# Every scene is shot once per theme so the docs can swap the whole gallery when
# the reader flips light/dark. By default the dark set lands in tui/ and the
# light set in tui/light/; the docs pick the right one from the active theme.
#
# Requirements: bash, tmux, python3, curl, sqlite3, and a built ./bin/gori.
# Usage:  docs/tools/tui-capture/capture.sh [path-to-gori-binary]
# Env:    SHOTS="theme:subdir …"   which palettes to shoot and where under tui/.
#           default: "goridark: goriday:light"  (dark → tui/, light → tui/light/)
#           e.g. SHOTS="goriday:light" to refresh only the light set.
#         ONLY="scenes themes readme"  which groups to shoot (default: all three).
#           e.g. ONLY=readme to refresh just the README hero shot.
#
# The captures are deliberately reproducible but not pixel-identical run to run
# (timestamps, durations, and live response bodies vary). Eyeball the output.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
GORI="${1:-$REPO/bin/gori}"
TUI_ROOT="$REPO/docs/static/images/tui"
SHOTS="${SHOTS:-goridark: goriday:light}"
OUT="$TUI_ROOT"
# 132 columns reads as a real full-width terminal in the docs; at the old 104
# the SVGs scaled up chunky ("zoomed-in screenshot" feel) in the content column.
COLS=132 ROWS=26 PORT=8091
ONLY="${ONLY:-scenes themes readme}"
want() { case " $ONLY " in *" $1 "*) return 0;; *) return 1;; esac; }

[ -x "$GORI" ] || { echo "gori binary not found/executable at $GORI (run 'shards build' first)"; exit 1; }
command -v tmux >/dev/null || { echo "tmux is required"; exit 1; }

WORK="$(mktemp -d)"
export GORI_HOME="$WORK/home"
mkdir -p "$GORI_HOME"
DB="$GORI_HOME/projects/default/gori.db"
trap 'tmux kill-session -t goricap 2>/dev/null || true; rm -rf "$WORK"' EXIT

# A minimal settings.json so the first-run wizard is skipped. The theme is
# rewritten before each palette pass; the seed run below doesn't care which.
# write_settings <theme> [pet] — pass "pet" to wake Miss Ring in the body's
# bottom-right corner. She ships OFF, so only the hero shot asks for her; the
# doc scenes document the default install.
write_settings() {
  local pet=""
  if [ "${2:-}" = pet ]; then
    pet='"pet":{"enabled":true,"placement":"body","motion":"lively","notices":true},'
  fi
  cat > "$GORI_HOME/settings.json" <<JSON
{"theme":"$1","mouse":true,"pretty_bodies":true,$pet
 "network":{"bind_host":"127.0.0.1","bind_port":8070,"upstream_proxy":""}}
JSON
}
write_settings goridark

P="http://127.0.0.1:$PORT"
seed() { curl -sk -x "$P" -o /dev/null "$@" || true; }
# httpbingo.org is a drop-in httpbin clone with far better uptime; httpbin.org
# has whole days where most requests 503.
seed_all() {
  seed "https://httpbingo.org/anything/api/users?role=admin&id=42"
  seed "https://httpbingo.org/get?search=admin&page=2&debug=true"
  seed https://api.github.com/users/hahwul
  seed https://api.github.com/zen
  seed "https://httpbingo.org/cookies/set?session=8f3a1c"
  seed https://httpbingo.org/status/500
  seed -H 'Content-Type: application/json' -d '{"user":"admin","password":"hunter2"}' https://httpbingo.org/post
  seed https://httpbingo.org/user-agent
  seed https://httpbingo.org/headers
  seed https://httpbingo.org/json
  seed https://example.com/
}

# Seed, then check what actually landed: httpbin.org has flaky days, and a
# History full of 503 rows makes the docs read as "tool is broken". One 5xx is
# deliberate (/status/500); tolerate one flake on top, else wipe and reseed.
echo "▸ seeding a throwaway project with real flows…"
for attempt in 1 2 3; do
  "$GORI" run capture --listen 127.0.0.1 --port "$PORT" >/dev/null 2>&1 &
  CAP=$!; sleep 2
  seed_all
  sleep 1; kill "$CAP" 2>/dev/null || true; sleep 1
  bad="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM flows WHERE status >= 500;' 2>/dev/null || echo 99)"
  [ "${bad:-99}" -le 2 ] && break
  echo "▸ seeding hit $bad 5xx responses (flaky upstream); retrying…"
  rm -f "$DB" "$DB-wal" "$DB-shm"
done

# _shoot <name> <rows> <title> <subcmd> <preamble:0|1> <tmux-keys...>
# Launches `gori <subcmd>` in a fresh tmux pane, optionally walks the project
# picker preamble, sends the keys, and renders the capture to SVG. Interleave
# the literal token SLEEP<seconds> to pause between keys.
# Set SHOT_COLS for a single call to widen that pane beyond the default $COLS,
# and SHOT_ARIA when the window title is decorative and needs a spoken label.
_shoot() {
  local name="$1" rows="$2" title="$3" subcmd="$4" preamble="$5"; shift 5
  local cols="${SHOT_COLS:-$COLS}"
  tmux kill-session -t goricap 2>/dev/null || true
  TERM=xterm-256color tmux new-session -d -s goricap -x "$cols" -y "$rows"
  tmux send-keys -t goricap \
    "cd $REPO && clear && GORI_HOME=$GORI_HOME TERM=xterm-256color '$GORI' $subcmd 2>/dev/null" C-m
  sleep 3
  if [ "$preamble" = 1 ]; then
    # preamble: open the "default" project from the picker
    tmux send-keys -t goricap Down Down Down; sleep 0.3
    tmux send-keys -t goricap Enter; sleep 1.3
  fi
  for k in "$@"; do
    case "$k" in
      SLEEP*) sleep "${k#SLEEP}";;
      *)      tmux send-keys -t goricap $k;;
    esac
  done
  sleep 0.5
  tmux capture-pane -t goricap -e -p > "$WORK/$name.ansi"
  tmux send-keys -t goricap C-c 2>/dev/null || true; sleep 0.2
  tmux kill-session -t goricap 2>/dev/null || true
  # normalize the capture port to the documented default, then render
  python3 - "$WORK/$name.ansi" <<'PY'
import sys; p=sys.argv[1]; t=open(p).read().replace("8091","8070"); open(p,"w").write(t)
PY
  local aria=()
  if [ -n "${SHOT_ARIA:-}" ]; then aria=(--aria "$SHOT_ARIA"); fi
  python3 "$HERE/ansi2svg.py" "$WORK/$name.ansi" "$OUT/$name.svg" \
    --title "$title" ${aria[@]+"${aria[@]}"} --fs 15
}

# run_scene <name> <rows> <title> <tmux-keys...> — the full TUI over the seeded DB.
# `--db` opens it directly (no project-picker preamble needed).
run_scene() {
  local name="$1" rows="$2" title="$3"; shift 3
  _shoot "$name" "$rows" "$title" "tui --port $PORT --db '$DB'" 0 "$@"
}

# run_tour <name> <rows> <title> <tmux-keys...> — `gori tutorial` (no picker).
run_tour() {
  local name="$1" rows="$2" title="$3"; shift 3
  _shoot "$name" "$rows" "$title" "tutorial" 0 "$@"
}

# Every scene, rendered into the current $OUT. Called once per theme.
shoot_all() {
  run_scene history      26 "gori · History"                   3 SLEEP1 Enter
  run_scene response-detail 26 "gori · Response detail"        3 SLEEP0.6 Enter SLEEP0.3 Down Down SLEEP0.3 Enter SLEEP1 Right SLEEP1
  run_scene command-palette 26 "gori · Command palette · Ctrl-P" 3 SLEEP0.8 C-p SLEEP1
  run_scene space-menu   26 "gori · Space menu"                3 SLEEP0.8 Down SLEEP0.3 Space SLEEP1
  run_scene sitemap      26 "gori · Sitemap"                   2 SLEEP1.2
  run_scene project      26 "gori · Project"                   1 SLEEP1.2
  run_scene intercept    26 "gori · Intercept"                 4 SLEEP1.2
  # Probe and Issues sit past the 1-9 positional-jump range (10th/11th visible
  # tab), so land on Comparer (9) and cycle right with `]` the rest of the way.
  # Issues then promotes a few Probe findings on the way through so the shot
  # isn't the empty-state onboarding card.
  run_scene probe        26 "gori · Probe scanner"             9 SLEEP0.3 ] SLEEP1.4
  run_scene issues       26 "gori · Issues"                    9 SLEEP0.3 ] SLEEP0.3 Enter SLEEP0.4 p SLEEP0.6 Down SLEEP0.3 p SLEEP0.6 Down SLEEP0.3 p SLEEP0.6 Down SLEEP0.3 p SLEEP0.7 Escape SLEEP0.3 ] SLEEP1.4
  run_scene decoder      26 "gori · Decoder"                   7 SLEEP1.2
  run_scene repeater     26 "gori · Repeater"                  3 SLEEP0.6 Enter SLEEP0.4 C-r SLEEP1.2 C-r SLEEP3
  run_scene fuzzer       34 "gori · Fuzzer"                    3 SLEEP0.6 Enter SLEEP0.3 Down SLEEP0.3 I SLEEP1 C-a SLEEP0.6 C-l SLEEP0.8 admin Enter root SLEEP0.5 Escape SLEEP0.7 C-r SLEEP5
  run_tour  tutorial     26 "gori · Guided tour"               SLEEP1.5
}

# The Themes-page gallery (docs/content/guide/themes.md): the same History scene shot
# under each gallery palette, written flat into tui/ as theme-<name>.svg with a
# "<theme> · default" window title. Not part of shoot_all — these are their own named
# theme cards, not the light/dark split of a scene.
shoot_themes() {
  OUT="$TUI_ROOT"
  for th in goridark goriday tokyonight gruvbox; do
    write_settings "$th"
    run_scene "theme-$th" 26 "$th · default" 3 SLEEP1 Enter
  done
}

# Extra traffic on top of seed_all, so the README's taller History pane reads as
# a working engagement instead of a dozen rows over a lot of empty space. Only
# the README shot wants these, and it runs last, so the doc scenes above keep
# the smaller, stable flow set.
#
# Eight, not "as many as fit": the 38-row pane lists 25 flows and seed_all
# already lands 11, so this leaves the bottom rows empty — which is where Miss
# Ring sits, under a speech bubble three rows taller than she is. Add more and
# the greeting eats live SIZE/DUR cells, and a hero with a half-covered number
# column reads as a rendering bug.
seed_readme_extra() {
  seed "https://httpbingo.org/anything/api/v2/orders?status=paid&limit=50"
  seed -X PUT -H 'Content-Type: application/json' -d '{"role":"editor"}' https://httpbingo.org/anything/api/users/42
  seed -X DELETE https://httpbingo.org/anything/api/sessions/8f3a1c
  seed "https://httpbingo.org/anything/admin/config?debug=true"
  seed https://httpbingo.org/status/403
  seed https://httpbingo.org/redirect/1
  seed https://api.github.com/repos/hahwul/gori
  seed https://example.com/robots.txt
}

# The README hero (readme.svg): the History tab, shot on a much wider pane than
# the doc scenes. The README renders one image edge to edge with
# no sidebar, so the 132x26 doc geometry reads as a cramped little window there;
# 180x38 fills the width and still lands near a 2:1 card.
#
# This one shot wears the brand wordmark in the window chrome instead of a
# "gori · Scene" caption: it is the hero on both the README and the docs
# landing, where it stands for the tool rather than for one screen. The spoken
# label still says what the screen is (see SHOT_ARIA / ansi2svg --aria).
#
# It shows plain History — no menu over it — with Miss Ring on: a hero should
# read as the tool at rest, and she fills the corner the way an open Space menu
# used to. Every other scene keeps her off, defaults being what docs document.
readme_seeded=0
shoot_readme() {
  local theme="$1" out="$2"
  OUT="$out"; mkdir -p "$OUT"
  write_settings "$theme" pet
  # Top up once, not once per palette: a second pass would double every extra
  # flow and the light hero would no longer match the dark one.
  if [ "$readme_seeded" = 0 ]; then
    echo "▸ topping up the throwaway project for the README shot…"
    "$GORI" run capture --listen 127.0.0.1 --port "$PORT" >/dev/null 2>&1 &
    local cap=$!; sleep 2
    seed_readme_extra
    sleep 1; kill "$cap" 2>/dev/null || true; sleep 1
    readme_seeded=1
  fi
  # Keys land fast on purpose: Miss Ring greets on the frame she first appears on and
  # holds it for Pet::GREET_TTL (8s) from TUI start, and _shoot has already slept 3s
  # waiting for the pane. Pad these and the hero loses the speech bubble.
  SHOT_COLS=180 SHOT_ARIA="gori TUI — the History tab listing captured HTTP flows" \
    run_scene readme 38 "𝓰𝓸𝓻𝓲" 3 SLEEP0.4 Enter SLEEP1
}

# One pass per "theme:subdir" spec in $SHOTS. The seeded DB is shared across
# passes; only the theme in settings.json changes between them, so the light and
# dark galleries show the same flows.
if want scenes; then
  for spec in $SHOTS; do
    theme="${spec%%:*}" subdir="${spec#*:}"
    OUT="$TUI_ROOT${subdir:+/$subdir}"
    write_settings "$theme"
    mkdir -p "$OUT"
    echo "▸ capturing $theme → $OUT"
    shoot_all
  done
fi

if want themes; then
  echo "▸ capturing the theme gallery → $TUI_ROOT/theme-*.svg"
  shoot_themes
fi

# The hero is the docs landing showcase too, and that image swaps with the
# reader's theme, so it follows the same "theme:subdir" passes as the scenes.
if want readme; then
  for spec in $SHOTS; do
    theme="${spec%%:*}" subdir="${spec#*:}"
    echo "▸ capturing the README hero ($theme) → $TUI_ROOT${subdir:+/$subdir}/readme.svg"
    shoot_readme "$theme" "$TUI_ROOT${subdir:+/$subdir}"
  done
fi

echo "▸ done. Review the SVGs under $TUI_ROOT"
