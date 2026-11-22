+++
title = "TUI Settings"
description = "The Preferences modal: one place for every gori setting, reachable from anywhere."
weight = 90

[extra]
group = "Customize"
+++

Every persisted preference in gori is edited from one surface, the **Preferences** modal. It is the same modal in the app and in the project picker.

## Opening Preferences

| Open it with | Lands on |
|--------------|----------|
| `Ctrl-,` from anywhere | The group strip, so you pick a group first |
| The `⚙` chip in the top bar | Same as `Ctrl-,` |
| `Ctrl-P` → any **Settings: …** entry | That section's fields directly |

The palette entries and the modal's sections come from the same list, so every section is reachable both ways.

## Moving Around

The modal has a group strip across the top (five groups) and the focused group's sections below it. Focus starts on the strip when you open with `Ctrl-,`, and on a field when you jump in from the palette.

| Key | Action |
|-----|--------|
| `←` / `→` | Switch group (while the strip has focus) |
| `↓` / `↵` | Drop from the strip into the fields |
| `↑` / `↓` | Move between fields; `↑` from the first field returns to the strip |
| `↵` | Save the current section, or open a section's editor |
| `Ctrl-R` | Reset the focused section to its defaults |
| `Esc` | Close; with unsaved edits the first press warns and a second discards them |

Edits go to a working copy. Nothing is written until you press `↵`, and `Esc` twice throws them away (the first press names the unsaved sections). Saving applies live, with no restart.

On a field row, `Ctrl-R` restores that section's defaults into the working copy, which still needs `↵`. On an **opener** row there is no working copy, so it asks first and then writes immediately. The tab bar, the theme and your hotkeys can each be reset this way. **Env**, **User-Agents** and **Host overrides** hold entries you typed, so `Ctrl-R` there leaves them in place and tells you so. The factory reset below clears them, after a warning.

## Field Types

| Type | How to edit |
|------|-------------|
| **Text** | Type into it (bind address, editor command, statusline command) |
| **Toggle** | `Space`, `←`, or `→` flips on/off |
| **Choice** | `←` / `→` cycles the options |
| **Opener** | `↵` opens that section's own editor |

Openers exist where a section needs more than a row of fields: the theme list, the tab bar, environment variables, hotkeys, the keyset playground, hostname overrides, and the User-Agent list.

## The Sections

### General

| Section | Fields |
|---------|--------|
| **General** | Clipboard (OSC 52), Confirm before quit, Update check, History retention (flows), Record Repeater sends |
| **Notifications** | Bell on result, Toast on result, Retention (count) |
| **Statusline** | Statusline on/off, Command, Interval (s), Timeout (s) |
| **Reset** | Action: restore every setting to its factory default |

Notifications fire on background results from the Miner, Fuzzer, Probe, and Discover. The [Statusline](/guide/statusline/) runs a shell command on an interval and renders its stdout as the bottom row. The command reads a [JSON context](/guide/statusline/#context) describing the live session on stdin, and there are [ready-made commands](/guide/statusline/#presets) to paste into it.

**Reset** is the whole file, not one section. `↵` (or `Ctrl-P` → **Settings: Reset**) asks, then puts `settings.json` back to a fresh install's state and applies it live: theme, keymap, tab bar, list and preview prefs, and the proxy bind. It also drops the data that lives in the same file: your global env values, hostname overrides, global OAST providers, saved decoder chains, global rewriter, colormarker and Probe rules, saved views, redaction profiles, upstream rules, outbound TLS settings, extra listeners, and the User-Agent list. MCP permissions go back to every group on, and Channel delivery back to off. Projects and their captures are untouched, and so are a project's own pinned bind and env.

Two things survive a reset. The redaction salt is kept, because discarding it would break every placeholder in an artifact already written. The global rule-id counters are kept too. A project can override a global rewriter or colormarker rule by id, and those overrides live in the project's own database, which a settings reset never opens. A new rule must not reuse an id an old override still names, so the counters keep counting up and `settings.json` keeps a rules-less block that records where they got to.

### Appearance

| Section | Fields |
|---------|--------|
| **Theme** | Opener: the theme picker (built-ins plus your own) |
| **Display** | *lists:* History list order, History list time, History Req/Res preview, Probe finding preview, Issues preview, Sitemap expand depth · *message panes:* Default detail pane, Line numbers, Wrap long lines, Preview body limit (KiB) · *window:* Tab numbers, Tab bar slots, Resource meter, Terminal title |
| **Companion** | Companion (Miss Ring), Placement, Motion, Notices, Agent replies |

The Theme row previews the current theme inline, showing its name and a swatch of its palette. See the [Themes guide](/guide/themes/).

Companion is on by default. **Companion → off** turns her off. Short of that, Motion `still` keeps her face and drops every repaint she starts herself, and Placement `bar` keeps her in the status row at all times. In `body` she never covers anything. Where a tab draws in her corner, and on a terminal under 100×30, she moves to the status row by herself. Miss Ring, a gilded ring mascot, says hello on the frame she first appears on, then blinks and winks on her own and reacts to background results. After 90 seconds of inactivity she dozes off and stops animating. Every 25 seconds or so she also plays one of seven idle gestures, picked at random: a yawn, a smile, a squint, a deadpan, a curious look that turns knowing, a small huff she blinks away, and a narrow-eyed "hmm". Her brows move as much as her eyes. Both lashes lift for the open, resting face, turn over for the furrowed one, and lift one at a time for the quizzical one. Each reaction has two stages. When a result lands she hits the peak (beams, tenses, or recoils), and after a second and a half settles into a quieter version of it for the rest of the reaction. Motion `calm` halves her blink rate and drops the gestures, for SSH sessions and battery. `still` drops the blink as well, so she never moves or repaints on her own. That has the same zero cost as her doze without the ninety-second wait, and suits an asciinema recording, a screen reader or a shared tmux pane. The reactions stay in all three modes. `still` suppresses only the movement in one, the flinch on an error, and keeps the face. While a background job is running (a fuzz, a discover, a mine, an in-flight repeater send) a dot bobs in her badge cell, in step with the status row's activity spinner, which is driven by the same counter. In `body` placement, where the activity chip is off screen, that dot is the only sign the run is still going. A reaction outranks it, so a failure mid-run still shows as `×`. She will not doze off while work is in flight, and work an agent starts over MCP wakes her. That hello is the only thing she says unprompted in a session, once per launch of gori. With Notices off she says nothing.

She stands on the project picker too, in the bottom-right corner beside the card. The hello comes once per launch of gori, on whichever screen she first appears on. The picker is also where she delivers the once-per-release **update available** notice: she says hi, then a beat later that a new version is out and how to install it. She speaks in the same bubble she uses in a session, floating above her head and over the card's right edge for the few seconds she is talking. On a terminal too narrow to seat her beside the card she doesn't appear, and the notice goes back to being a plain centered line, as with Companion off.

She also turns up in the two standalone screens. The **setup wizard** has a COMPANION step (a still of her beside an on/off choice and her motion), so a first-run user decides whether they want her before meeting her. Nothing is written until you finish, so Esc leaves the setting unchanged. The **guided tour** (`gori tutorial`) is the only place she takes part in the teaching. She stands at the right of the card and confirms each move as you make it (switching a tab, opening the palette, the action menu, INS mode), once each, and signs off at the end. She stands only where the tour's card keeps its full width beside her (about 94 columns and up), and she speaks only where her bubble fits outside the card, so on an 80-column terminal the tour looks as it does with Companion off. The lessons live in the card and she only reacts, so turning Notices off removes her encouragement and none of the tour.

Placement decides what she costs *in a session* (the picker has only one spot). `body` puts an 8&times;3 sprite in the bottom-right of the tab body while that corner is empty, where she announces results in a speech bubble. Once a list or a pane fills the corner she moves to the status row, and comes back when it clears. `bar` puts an eight-cell chip at the far right of the status row, past the clock: her face and her mood badge, without the ring's crown and floor. She covers nothing, and there is no bubble, because her line goes through the status row's text slot. The badge keeps a reaction legible there. Without it the chip would signal an error only by shifting one gold a little redder, which a washed-out terminal barely shows. She is the same width in every expression, so she never nudges the clock or the CPU/MEM readout as she blinks. That slot holds one message, so the newer of the toast and her notice wins. Notices is independent of the bottom-bar toast either way. In both placements, clicking her opens the notification ring, where the line she just spoke is the newest note.

**Agent replies** decides how long she keeps saying something an agent sent you with the MCP `reply_to_operator` tool. On `hold`, the default, the reply stays in her bubble (or the status row, in `bar`) until your next key or click, and a job result that lands after it changes her face but not her words. Only a newer reply replaces it. A key you were already pressing when it arrived does not erase it. It still stays for the few seconds any notice gets. `timed` lets a reply go after those few seconds like everything else. Either way it is a notification in the open window, not a mailbox. Replies that arrive while no gori TUI is open on the project are not replayed one by one. The next window to open sums them up in one note she holds the same way, and the agent is told so.

### Editor & Keys

| Section | Fields |
|---------|--------|
| **Editor** | External editor, Markdown highlight, Pretty-print bodies |
| **Mouse** | Mouse, Drag release |
| **Keys** | Command modifier, Editor keyset, Keyset playground (opener) |
| **Env** | Opener: global `$ENV.KEY` variables for outbound requests. It also reports the token grammar in force; switching that is [`gori settings env-syntax`](/reference/cli/#env-syntax), which re-spells the tokens already stored |
| **User-Agents** | Opener: your own list for `$GEN.USER_AGENT`, one per line. It replaces the built-in browser list; empty means the built-in one |
| **Hotkeys** | Opener: rebind any shortcut, or pick an OS default profile |

**External editor** is what `^E` opens in editable fields. Blank falls back to `$VISUAL` / `$EDITOR` / `vi` (`notepad` on Windows).

**Mouse** covers the pointer. Turning it off hands click, wheel and drag back to the terminal, so its own text selection works again. **Drag release** decides what letting go of a drag over a text pane does. `select only` leaves the band highlighted and waits for the copy key (`y` in READ, `^Y` while typing), which is gori's original behaviour. `select + copy` also copies it to the clipboard on release, like a terminal's primary selection. A plain click selects nothing, so under `select + copy` it still copies nothing. The mode acts only on a band a drag built, and copies through the same path as the copy key, so the toast and each tab's meaning of "copy" are the same either way.

**Keys** picks which modifier fronts gori's built-in chord family (`^P` `^N` `^W` `^1-9`). `Option (⌥)` adds `⌥` aliases without giving up Ctrl, for terminals that never deliver the Ctrl form. **Hotkeys** rebinds individual actions. Keys also picks the **Editor keyset** (`helix` or `vim`), which respells a text pane's READ-mode keys. See [Editor keysets](/guide/hotkeys/#editor-keysets). See [Command modifier](/guide/hotkeys/#command-modifier), [Hotkeys](/guide/hotkeys/) and [environment variables](/guide/repeater-and-fuzzer/#environment-variables).

### Network & Tabs

| Section | Fields |
|---------|--------|
| **Network** | Bind IP, Bind Port, Upstream proxy, Proxy host, Proxy port, Proxy TLS CA, Verify proxy TLS, Verify upstream TLS, Info page and CA download, Connect timeout (s), Idle timeout (s), Capture body limit (MiB), HTTP/2, Strip HTTP/3 Alt-Svc, TLS passthrough, Upstream rules (read-only), Environment proxy (read-only), Outbound TLS (read-only), Host overrides (opener) |
| **Tabs** | Opener: one ordered list, where the rows above the seam are the bar's numbered slots. `⇧K` / `⇧J` move a row and `space` sends it across the seam; while **Tab bar slots** is on, a tenth is refused (`⇧K` trades a row in instead). Everything off the bar stays reachable with `0` |

Network here is the **global default**. A project can pin its own bind address, port, and upstream from the **Project** tab, and those win for that project. See [Configuration](/getting-started/configuration/#network) for the full precedence order.

### AI

| Section | Fields |
|---------|--------|
| **MCP server** | Channel delivery (off), Usage log (off) |
| **MCP permissions** | Send traffic, Intercept control, Edit project data, Change scope & sandbox, Manage projects, Run local commands (each `on`, `ask` or `off`; all `on` by default) |

**MCP server** holds two switches for the `gori mcp` server. **Channel delivery** concerns how it delivers a "Tell the agent…" message to an attached agent. The inbox-socket, Codex-queue, tool-result and `operator_messages`-poll layers always run. **Channel delivery** adds the `claude/channel` push *behind* them, tried only when no route that can confirm delivery has answered. It is off by default because it is a research preview that needs Claude Code launched with a development-channels flag. It is read when a `gori mcp` process starts, so an agent already running keeps the answer it was given. See [Messages from gori](/guide/mcp/#messages-from-gori).

**Usage log** makes `gori mcp` record each tool call's name, argument names, outcome, size and duration in `~/.gori/mcp-usage.jsonl`, never an argument's value, a reply, a host or a project name. Nothing is sent anywhere, and `gori mcp --usage` prints the summary. It is off by default and, like Channel delivery, read when the server starts. See [Usage Log](/guide/mcp/#usage-log).

**MCP permissions** decides what an agent attached over `gori mcp` may do, one group at a time: `off` withholds the group, and `ask` holds each of its calls for your approval on the TUI's `ask:` card. Reading the capture is always allowed. Like Channel delivery, the setting is read when the server starts. See [Permissions from Preferences](/guide/mcp/#permissions-from-preferences).

## In the Project Picker

`Ctrl-,` opens the same modal from the project picker, before any project is loaded, so you can set your theme on first launch. Every form section is editable there, but **Theme** is the only opener that works. The sections that need a live project (Tabs, Env, Hotkeys, the Keyset playground, hostname overrides, and User-Agents) stay hidden or report that you need to open a project first, and so does **Reset**, because a factory reset has to be applied to a running session.

## Where Settings Live

Everything saved here is written to `settings.json` under the gori home directory. Print or open it directly:

```bash
gori settings          # print the settings.json path
gori settings --edit   # open it in your editor
```

Per-project overrides are not in this file. They live in the project database and are edited from the **Project** tab.

## Next Steps

- [Configuration](/getting-started/configuration/): the storage layout, network precedence, and the root CA
- [Configuration Reference](/reference/config/): every `settings.json` key
- [Themes](/guide/themes/): switch or write a colour theme
- [Hotkeys](/guide/hotkeys/): rebind shortcuts and the key-budget rules
