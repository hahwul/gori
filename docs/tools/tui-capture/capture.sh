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
# The jwt.io sample token, typed into the JWT scene's INPUT (see shoot_all). A literal,
# not a capture: that tab is pure local compute and the guide's shot has always used the
# token every reader recognises.
JWT_SAMPLE="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
ONLY="${ONLY:-scenes themes readme}"
want() { case " $ONLY " in *" $1 "*) return 0;; *) return 1;; esac; }

[ -x "$GORI" ] || { echo "gori binary not found/executable at $GORI (run 'shards build' first)"; exit 1; }
command -v tmux >/dev/null || { echo "tmux is required"; exit 1; }
# The statusline scene's command IS a jq program. Without jq that scene still "succeeds":
# the child exits 127, the row captures as `⋯ (exit 127)` — in the caution colour, which
# reads as a deliberate warning in the SVG — and that gets committed as the documented
# picture of the feature. Refuse up front instead.
command -v jq >/dev/null || { echo "jq is required (the statusline scene's command is a jq program)"; exit 1; }

WORK="$(mktemp -d)"
export GORI_HOME="$WORK/home"
mkdir -p "$GORI_HOME"
DB="$GORI_HOME/projects/default/gori.db"
trap 'tmux kill-session -t goricap 2>/dev/null || true; rm -rf "$WORK"' EXIT

# A minimal settings.json so the first-run wizard is skipped. The theme is
# rewritten before each palette pass; the seed run below doesn't care which.
# write_settings <theme> [companion] — pass "companion" to wake Miss Ring in the body's
# bottom-right corner. She ships OFF, so only the hero shot asks for her; the
# doc scenes document the default install.
write_settings() {
  local companion=""
  if [ "${2:-}" = companion ]; then
    companion='"companion":{"enabled":true,"placement":"body","motion":"lively","notices":true},'
  fi
  cat > "$GORI_HOME/settings.json" <<JSON
{"theme":"$1","mouse":true,"pretty_bodies":true,$companion
 "network":{"bind_host":"127.0.0.1","bind_port":8070,"upstream_proxy":""}}
JSON
}
write_settings goridark

# The statusline scenes are the shots that have to turn a feature ON: it ships off, so there
# is nothing to photograph until settings say so. Written from python rather than a heredoc
# because every one of these commands is thick with backslashes, quotes and the single quote
# that would close a bash string — python takes them as raw strings and does the JSON escaping
# itself, so what you read below is what /bin/sh receives.
#
# write_statusline_settings <theme> [preset] — write_settings plus a live statusline row.
#
# `preset` picks the command. `script` (the default) is the whole-screen scene's: the
# composite the guide prints under "When one line is not enough", run from a file the way a
# row that long should be. The other three are the guide's one-line presets, each shot as a
# strip directly under the command it is a picture of — which is why they are held HERE, in
# one place, rather than retyped per scene: a command that has drifted from the page it
# illustrates is worse than no picture at all. Keep them byte-identical to the guide's code
# blocks.
#
# All four deliberately say what the top bar cannot — when the token under test expires,
# whether the target has started answering 5xx, what is still unchecked in the notes — because
# the row this feature sells has to earn its line. They call `gori run`, so the pane puts the
# built binary on PATH (_shoot).
write_statusline_settings() {
  python3 - "$GORI_HOME/settings.json" "$1" "${2:-script}" <<'PY'
import json, sys
path, theme, preset = sys.argv[1], sys.argv[2], sys.argv[3]
# "\u001b" stays a six-character escape all the way down; jq is what turns it into a real ESC.
commands = {
    "script": r'''sh "${GORI_HOME:-$HOME/.gori}/statusline.sh"''',
    "token": (
        r"""jq -rn --argjson exp "$(gori run jwt "$(cat "${GORI_HOME:-$HOME/.gori}/token.jwt")" """
        r"""--format json | jq .payload.exp)" '(($exp - now) / 60 | floor) as $m |"""
        r''' if $m < 5 then "\u001b[31m\u26a0 token \($m)m left\u001b[0m"'''
        r""" else "\u001b[32m\u25cf\u001b[0m token \($m)m left" end'"""
    ),
    "errors": (
        r"""p=$(jq -r .project); gori run history --project "$p" -q 'status:>=500' --format json"""
        r""" 2>/dev/null | jq -rs 'length | if . == 0 then "" else"""
        r""" "\u001b[31m\(.) \u00d7 5xx\u001b[0m" end'"""
    ),
    "todo": (
        r"""p=$(jq -r .project); gori run notes --all --project "$p" |"""
        r""" awk '/^- \[ \]/ { n++; if (n == 1) first = substr($0, 7) }"""
        r""" END { if (n) printf "todo %d · %s", n, first }'"""
    ),
}
json.dump({
    "theme": theme, "mouse": True, "pretty_bodies": True,
    "statusline": {"enabled": True, "command": commands[preset], "interval": 3, "timeout": 10},
    "network": {"bind_host": "127.0.0.1", "bind_port": 8070, "upstream_proxy": ""},
}, open(path, "w"))
PY
}

# write_statusline_script — the composite the whole-screen scene photographs, byte-identical
# to the one the guide prints (docs/content/guide/statusline.md, "When one line is not
# enough"). A quoted heredoc: nothing in it is expanded as it is WRITTEN, only when it RUNS.
#
# The hero shot used to print the project, the bind address and the probe mode — every one of
# which is already a chip two rows above it, so the picture argued against the feature. This
# says what the chrome cannot.
write_statusline_script() {
  cat > "$GORI_HOME/statusline.sh" <<'SH'
#!/bin/sh
# statusline.sh — one row: how long the token has, whether the target is erroring,
# and what is still unchecked. The context arrives on stdin, so read it once.
ctx=$(cat)
project=$(printf '%s' "$ctx" | jq -r .project)

token=$(jq -rn --argjson exp "$(gori run jwt "$(cat "${GORI_HOME:-$HOME/.gori}/token.jwt")" --format json | jq .payload.exp)" \
  '(($exp - now) / 60 | floor) as $m | if $m < 5 then "\u001b[31m⚠ token \($m)m left\u001b[0m" else "\u001b[32m●\u001b[0m token \($m)m left" end')
errors=$(gori run history --project "$project" -q 'status:>=500' --format json 2>/dev/null |
  jq -rs 'length | if . == 0 then "" else "\u001b[31m\(.) × 5xx\u001b[0m" end')
todo=$(gori run notes --all --project "$project" |
  awk '/^- \[ \]/ { n++; if (n == 1) first = substr($0, 7) } END { if (n) printf "todo %d · %s", n, first }')

printf '%s' "$token"
[ -n "$errors" ] && printf '   %s' "$errors"
[ -n "$todo" ] && printf '   %s' "$todo"
printf '\n'
SH
}

# The `token` preset reads the JWT under test from $GORI_HOME, which is how a reader would
# keep one. Minted by gori itself, an hour out, so the row reads as a session that has just
# authenticated rather than one already broken.
write_demo_token() {
  "$GORI" run jwt "$JWT_SAMPLE" --encode --alg HS256 --secret secret \
    --set exp=$(( $(date +%s) + 3540 )) 2>/dev/null | tail -1 > "$GORI_HOME/token.jwt"
}

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

# A provider, an idle listener session, and four callbacks, written straight
# into the throwaway DB for the OAST scene. The tab hydrates its Callbacks table
# from `oast_callbacks`, so this is the whole shot — nothing registers with a
# public interactsh server and nothing waits on a real callback.
#
# The source IPs are RFC 5737 documentation addresses ON PURPOSE. A live capture
# would put a real resolver and a real egress IP — mine, or whoever regenerates
# these — into an image published on the docs site.
seed_oast() {
  local now=1754750000000000
  sqlite3 "$DB" <<SQL
INSERT INTO oast_providers (created_at,updated_at,name,kind,host,token,enabled,position)
  VALUES ($now,$now,'oast.pro','interactsh','oast.pro',NULL,1,0);
INSERT INTO oast_sessions (created_at,provider_id,kind,server_url,correlation_id,secret,private_key_pem,token,last_poll_at)
  VALUES ($now,1,'interactsh','https://oast.pro','ux9u36vnxl7cfjfk6kgy','',NULL,NULL,$now);
INSERT INTO oast_callbacks (session_id,created_at,provider_uid,protocol,method,source_ip,full_id,raw_request,raw_response) VALUES
 (1,$((now + 1000000)),'cb-1','dns','A','203.0.113.10','ux9u36vnxl7cfjfk6kgyp75ihzbesxa9u.oast.pro',X'00',NULL),
 (1,$((now + 2000000)),'cb-2','http','GET','203.0.113.24','ux9u36vnxl7cfjfk6kgyp75ihzbesxa9u.oast.pro',X'00',NULL),
 (1,$((now + 3000000)),'cb-3','http','GET','203.0.113.24','ux9u36vnxl7cfjfk6kgyp75ihzbesxa9u.oast.pro',X'00',NULL),
 (1,$((now + 4000000)),'cb-4','dns','A','198.51.100.7','ux9u36vnxl7cfjfk6kgyp75ihzbesxa9u.oast.pro',X'00',NULL);
SQL
}
seed_oast

# The Project scene's DESCRIPTION pane renders whatever `settings.description`
# holds, and the throwaway project this script creates has none — so the pane
# shot as an empty box under the stats. `ProjectRegistry.create` writes this
# same key from its `description` argument; the project here is created
# implicitly by the capture run, so set it directly — scene dressing, like
# seed_oast above, not traffic.
seed_description() {
  sqlite3 "$DB" \
    "INSERT OR REPLACE INTO settings (key, value)
     VALUES ('description', 'Staging assessment for httpbingo.org and the GitHub API. Scope is on for both hosts; findings go to Issues.');"
}
seed_description

# The Notes tab is one of the nine slots, so the showcase strip has a button for it — and an
# empty project shot the onboarding card instead of the thing the tab is for. Notes live in
# `settings` as one JSON doc (`Gori::Notes::DOCS_KEY`), not a table, so this is the same
# one-row dressing `seed_description` is. Two notes, because the sub-tab strip only appears at
# two or more and the strip is half of what the tab looks like.
seed_notes() {
  sqlite3 "$DB" <<'SQL'
INSERT OR REPLACE INTO settings (key, value) VALUES ('notes.docs', json_object(
  'cur', 0,
  'next_id', 3,
  'notes', json_array(
    json_object('id', 1, 'text', 'httpbingo — scope notes' || char(10) || char(10) ||
      'Login sets TWO cookies: a Flask session (itsdangerous, weak key) and a bearer' || char(10) ||
      'JWT echoed in the body. Both reach /v1/users/:id — see Issues #2.' || char(10) || char(10) ||
      '- [x] map the API surface (Target > Discover)' || char(10) ||
      '- [x] mine /v1/search for hidden params -> `debug`, `next`' || char(10) ||
      '- [ ] re-test #4 after the token rotation lands' || char(10) ||
      '- [ ] ask about the /v1/import allowlist before filing the SSRF'),
    json_object('id', 2, 'text', 'github api — read-only pass' || char(10) || char(10) ||
      'Unauthenticated only. Rate limit is 60/h so keep the Fuzzer off this host.')
  )
));
SQL
}
seed_notes

# _shoot <name> <rows> <title> <subcmd> <preamble:0|1> <tmux-keys...>
# Launches `gori <subcmd>` in a fresh tmux pane, optionally walks the project
# picker preamble, sends the keys, and renders the capture to SVG. Interleave
# the literal token SLEEP<seconds> to pause between keys.
# The pane also carries the built binary on PATH: the statusline preset strips run
# `gori run …`, the spelling the guide prints and the one a reader has on PATH.
# Set SHOT_COLS for a single call to widen that pane beyond the default $COLS,
# and SHOT_ARIA when the window title is decorative and needs a spoken label.
# SHOT_TAIL=<n> renders only the last n drawn rows, with no window chrome — a
# strip of the screen rather than a screenshot of it (see run_strip).
_shoot() {
  local name="$1" rows="$2" title="$3" subcmd="$4" preamble="$5"; shift 5
  local cols="${SHOT_COLS:-$COLS}"
  tmux kill-session -t goricap 2>/dev/null || true
  TERM=xterm-256color tmux new-session -d -s goricap -x "$cols" -y "$rows"
  tmux send-keys -t goricap \
    "cd $REPO && clear && PATH=$(dirname "$GORI"):\$PATH GORI_HOME=$GORI_HOME TERM=xterm-256color '$GORI' $subcmd 2>/dev/null" C-m
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
  # A strip carries no window chrome: it is one row lifted out of a screen the
  # reader has already been shown whole, and a title bar over a single line
  # reads as a window with nothing in it. The scene title becomes the spoken
  # label instead, since nothing else in the picture says what it is.
  local render=()
  if [ -n "${SHOT_TAIL:-}" ]; then
    render=(--tail "$SHOT_TAIL" --pad 10 --aria "${SHOT_ARIA:-$title}")
  else
    render=(--title "$title")
    if [ -n "${SHOT_ARIA:-}" ]; then render+=(--aria "$SHOT_ARIA"); fi
  fi
  python3 "$HERE/ansi2svg.py" "$WORK/$name.ansi" "$OUT/$name.svg" \
    "${render[@]}" --fs 15
}

# run_scene <name> <rows> <title> <tmux-keys...> — the full TUI over the seeded DB.
# `--db` opens it directly (no project-picker preamble needed).
#
# SCENES filters by name, for re-shooting one frame after a fix without
# disturbing the others: every capture carries live timestamps and durations,
# so a full run rewrites all of them and buries a one-scene change in noise.
#   SCENES=project docs/tools/tui-capture/capture.sh
run_scene() {
  local name="$1" rows="$2" title="$3"; shift 3
  if [ -n "${SCENES:-}" ]; then
    case " $SCENES " in *" $name "*) ;; *) return 0;; esac
  fi
  _shoot "$name" "$rows" "$title" "tui --port $PORT --db '$DB'" 0 "$@"
}

# run_tour <name> <rows> <title> <tmux-keys...> — `gori tutorial` (no picker).
# Honours SCENES like run_scene does: without it, re-shooting one frame still spent half a
# minute driving the guided tour and rewrote its two SVGs with a fresh (identical-looking,
# not identical) capture, which is exactly the noise SCENES exists to avoid.
run_tour() {
  local name="$1" rows="$2" title="$3"; shift 3
  if [ -n "${SCENES:-}" ]; then
    case " $SCENES " in *" $name "*) ;; *) return 0;; esac
  fi
  _shoot "$name" "$rows" "$title" "tutorial" 0 "$@"
}

# run_strip <name> <aria> <tmux-keys...> — the same TUI as run_scene, rendered as its LAST
# ROW ONLY: the statusline, with no window chrome around it. A bare row carries no title to
# speak, so `aria` is what a screen reader gets.
run_strip() {
  local name="$1" aria="$2"; shift 2
  SHOT_TAIL=1
  SHOT_ARIA="$aria"
  run_scene "$name" 26 "$aria" "$@"
  unset SHOT_TAIL SHOT_ARIA
}

# Every scene, rendered into the current $OUT. Called once per theme, which it takes as an
# argument rather than reading the caller's loop variable: the statusline scene below has to
# rewrite settings.json under that palette and put it back.
shoot_all() {
  local theme="$1"
  run_scene history      26 "gori · History"                   3 SLEEP1 Enter
  run_scene response-detail 26 "gori · Response detail"        3 SLEEP0.6 Enter SLEEP0.3 Down Down SLEEP0.3 Enter SLEEP1 Right SLEEP1
  run_scene command-palette 26 "gori · Command palette · Ctrl-P" 3 SLEEP0.8 C-p SLEEP1
  run_scene space-menu   26 "gori · Space menu"                3 SLEEP0.8 Down SLEEP0.3 Space SLEEP1
  run_scene sitemap      26 "gori · Sitemap"                   2 SLEEP1.2
  run_scene project      26 "gori · Project"                   1 SLEEP1.2
  run_scene intercept    26 "gori · Intercept"                 4 SLEEP1.2
  # THE BAR IS NINE NUMBERED SLOTS, and `1`-`9` reach exactly those nine:
  #
  #   1 Project · 2 Target · 3 History · 4 Intercept · 5 Repeater · 6 Fuzzer ·
  #   7 Probe · 8 Issues · 9 Notes
  #
  # Everything else — OAST, Decoder, JWT, Sequencer, the rest — is off the bar and reached
  # with `0` (Go to tab…), which is a NAME, not a position. Prefer `0 <name> Enter` for those:
  # it is what the guide tells a reader to press, and it is the only navigation here that
  # cannot silently retarget. A positional jump is a position in `Chrome::TABS` minus
  # `Chrome::DEFAULT_HIDDEN`, and a tab going on or off the bar slides every digit to its
  # right — that is how the Decoder scene once spent three weeks shipping a picture of the
  # OAST tab. After a catalog change, re-read the strip in a capture and fix the numbers.
  #
  # `0` lands in the BODY (the picker drills in, like the palette's "Go to …"), so an off-bar
  # scene needs no `Tab` after it. The tab it opens also rides the far right of the bar
  # WITHOUT a number until you leave it — that is the temporary tenth tab, and it is supposed
  # to be in the shot.
  run_scene probe        26 "gori · Probe scanner"             7 SLEEP1.4
  run_scene issues       26 "gori · Issues"                    7 SLEEP0.5 Enter SLEEP0.4 p SLEEP0.6 Down SLEEP0.3 p SLEEP0.6 Down SLEEP0.3 p SLEEP0.6 Down SLEEP0.3 p SLEEP0.7 Escape SLEEP0.3 ] SLEEP1.4
  run_scene notes        26 "gori · Notes"                     9 SLEEP1.4
  # The Decoder opens EMPTY, so the shot has to build the chain the guide describes
  # (base64-encode then upper, with the per-step PIPELINE readout). At TABS scope a bare `i`
  # is the intercept toggle, not "edit" — but `0` has already dropped focus into the body, so
  # `i` is the editor here. The trailing Escape closes the converter completer, which
  # otherwise hangs over CHAIN's bottom border.
  run_scene decoder      26 "gori · Decoder"                   0 SLEEP0.6 decoder SLEEP0.5 Enter SLEEP0.8 i SLEEP0.4 "admin:hunter2" SLEEP0.4 Escape SLEEP0.4 Down SLEEP0.5 "base64 > upper" SLEEP0.8 Escape SLEEP0.8
  # OAST reads its Callbacks table straight out of the project DB (hydrate →
  # oast_callbacks_since 0), so seed_oast's synthetic hits are all this needs —
  # no live registration, no third-party provider, and no real source IP baked
  # into a published image.
  run_scene oast         26 "gori · OAST"                      0 SLEEP0.6 oast SLEEP0.5 Enter SLEEP1.4
  # The Go-to card itself: `0` from the bar, before anything is typed, so the shot shows the
  # whole catalog — the nine slots wearing their digits and everything else wearing none.
  run_scene tab-goto     26 "gori · Go to tab…"                0 SLEEP1.2
  # The Sequencer shot is the SEND TO SEQUENCER card over History, not the tab
  # (which is hidden and empty until something is sent to it). Down x7 lands on
  # the /cookies/set flow — the one with a Set-Cookie for the config card to
  # auto-detect — and `q` is that verb's space-menu mnemonic.
  run_scene sequencer    26 "gori · Sequencer"                 3 SLEEP1.4 Down Down Down Down Down Down Down SLEEP0.5 Space SLEEP0.4 q SLEEP1.4
  run_scene repeater     26 "gori · Repeater"                  3 SLEEP0.6 Enter SLEEP0.4 C-r SLEEP1.2 C-r SLEEP3
  run_scene fuzzer       34 "gori · Fuzzer"                    3 SLEEP0.6 Enter SLEEP0.3 Down SLEEP0.3 I SLEEP1 C-a SLEEP0.6 C-l SLEEP0.8 admin Enter root SLEEP0.5 Escape SLEEP0.7 C-r SLEEP5
  # JWT is off the bar, so this reaches it the way the guide tells a reader to (`0`, type,
  # ↵), then types the sample token and sends the caret Home so INPUT shows where the token
  # STARTS — typing leaves the view on its tail, which reads as a truncated blob.
  run_scene jwt          26 "gori · JWT"                       0 SLEEP0.6 jwt SLEEP0.5 Enter SLEEP1.2 Enter SLEEP0.3 "$JWT_SAMPLE" SLEEP1 Home SLEEP0.3 Escape SLEEP0.6
  run_tour  tutorial     26 "gori · Guided tour"               SLEEP1.5
  # LAST, and it puts settings back: this is the only scene that edits settings.json, and
  # every scene above documents the default install. Same History screen as the first shot
  # on purpose — the picture is about the extra row at the bottom, so the rest of the frame
  # has to be something the reader already recognises.
  write_demo_token
  write_statusline_script
  write_statusline_settings "$theme"
  run_scene statusline   26 "gori · Statusline"                3 SLEEP1 Enter
  # The preset gallery on the Statusline guide: the same three commands the page prints,
  # each shot as ONE ROW. The card puts the picture directly under the command it came from,
  # and a full 26-row screenshot there would be three-quarters History for a feature that is
  # one line tall. The extra sleep is for the COMMAND, not the UI: _shoot has already waited
  # out the launch, and the row only fills once the first run returns.
  #
  # Nothing here is staged except the token file: the 5xx count and the notes come out of the
  # seeded project through `gori run`, the same way a reader's would.
  write_demo_token
  write_statusline_settings "$theme" token
  run_strip statusline-token \
    "gori statusline row: a green dot, then how long the token under test has before it expires" \
    3 SLEEP2
  write_statusline_settings "$theme" errors
  run_strip statusline-errors \
    "gori statusline row, in red: how many captured responses came back 5xx" \
    3 SLEEP2
  write_statusline_settings "$theme" todo
  run_strip statusline-todo \
    "gori statusline row: how many unchecked tasks the project notes hold, and the first of them" \
    3 SLEEP2
  write_settings "$theme"
}

# The Themes-page gallery (docs/content/guide/themes.md): the same History scene shot
# under each gallery palette, written flat into tui/ as theme-<name>.svg with a
# "<theme> · default" window title. Not part of shoot_all — these are their own named
# theme cards, not the light/dark split of a scene.
shoot_themes() {
  OUT="$TUI_ROOT"
  for th in goridark goriday tokyonight gruvbox dancheong hanji; do
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
  write_settings "$theme" companion
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
  # holds it for Companion::GREET_TTL (8s) from TUI start, and _shoot has already slept 3s
  # waiting for the pane. Pad these and the hero loses the speech bubble.
  #
  # AND THE SHOT MUST NOT GO THROUGH THE PROJECT PICKER. The hello is once per PROCESS
  # (Companion.@@greeted) and she now stands on the picker too, so a preamble=1 run would have
  # her say it THERE and reach History already greeted — a silent hero, with nothing in
  # the capture to say why. run_scene opens the db directly (`--db`, preamble 0), which
  # is the only reason this still works; keep it that way.
  SHOT_COLS=180 SHOT_ARIA="gori TUI — the History tab listing captured HTTP flows" \
    run_scene readme 38 "𝓰𝓸𝓻𝓲" 3 SLEEP0.4 Enter SLEEP1
}

# One pass per "theme:subdir" spec in $SHOTS. Every pass photographs the same project:
# only the theme in settings.json changes between them.
#
# Which means the DB has to be PUT BACK between passes, because scenes mutate it. The
# Issues scene promotes findings, so the second pass promoted three more on top of the
# first pass's three — the light Issues shot listed rows the dark one did not, and a
# statusline strip counting `.issues` disagreed with its own light twin on a page where
# the reader can flip between them with one click. The seed snapshot is taken after all
# seeding (flows, OAST callbacks, notes) and restored at the top of each pass.
SEED_SNAPSHOT="$WORK/seed.db"
cp "$DB" "$SEED_SNAPSHOT"

if want scenes; then
  for spec in $SHOTS; do
    theme="${spec%%:*}" subdir="${spec#*:}"
    OUT="$TUI_ROOT${subdir:+/$subdir}"
    cp "$SEED_SNAPSHOT" "$DB"; rm -f "$DB-wal" "$DB-shm"
    write_settings "$theme"
    mkdir -p "$OUT"
    echo "▸ capturing $theme → $OUT"
    shoot_all "$theme"
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
