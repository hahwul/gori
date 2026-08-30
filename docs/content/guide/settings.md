+++
title = "Settings"
description = "The Preferences modal: one place for every gori setting, reachable from anywhere."
weight = 90

[extra]
group = "Customize"
+++

Every persisted preference in gori is edited from one surface, the **Preferences** modal. It is the same modal in the app and in the project picker, so there is a single place to learn.

## Opening Preferences

| Open it with | Lands on |
|--------------|----------|
| `Ctrl-,` from anywhere | The group strip, so you pick a group first |
| The `⚙` chip in the top bar | Same as `Ctrl-,` |
| `Ctrl-P` → any **Settings: …** entry | That section's fields directly |

The palette entries and the modal's sections come from the same list, so anything you can reach one way you can reach the other.

## Moving Around

The modal has a group strip across the top (four groups) and the focused group's sections below it. Focus starts on the strip when you open with `Ctrl-,`, and on a field when you jump in from the palette.

| Key | Action |
|-----|--------|
| `←` / `→` | Switch group (while the strip has focus) |
| `↓` / `↵` | Drop from the strip into the fields |
| `↑` / `↓` | Move between fields; `↑` from the first field returns to the strip |
| `↵` | Save the current section, or open a section's editor |
| `Ctrl-R` | Reset the focused section to its defaults |
| `Esc` | Close, discarding unsaved edits |

Edits are a working copy: nothing is written until you press `↵`, and `Esc` throws them away. Saving applies live, with no restart.

`Ctrl-R` follows the same rule on a field row — it restores that section's defaults into the working copy, and still needs `↵`. On an **opener** row there is no working copy to edit, so it asks first and then writes immediately: the tab bar, the theme, and your hotkeys can each be put back that way. **Env** and **Hostname overrides** hold entries you typed rather than preferences, so `Ctrl-R` there says so instead of quietly emptying them — the factory reset below is what clears those, and it warns you.

## Field Types

| Type | How to edit |
|------|-------------|
| **Text** | Type into it (bind address, editor command, statusline command) |
| **Toggle** | `Space`, `←`, or `→` flips on/off |
| **Choice** | `←` / `→` cycles the options |
| **Opener** | `↵` opens that section's own editor |

Openers exist where a section needs more than a row of fields: the theme list, the tab bar, environment variables, hotkeys, and hostname overrides.

## The Sections

### General

| Section | Fields |
|---------|--------|
| **General** | Clipboard (OSC 52), Confirm before quit |
| **Notifications** | Bell on result, Toast on result, Retention (count) |
| **Statusline** | Statusline on/off, Command, Interval (s) |
| **Reset** | Action: restore every setting to its factory default |

Notifications fire on background results from the Miner, Fuzzer, Probe, and Discover. The [Statusline](/reference/config/#statusline) runs a shell command on an interval and renders its stdout as the bottom row.

**Reset** is the whole file, not one section — `↵` (or `Ctrl-P` → **Settings: Reset**) asks, then puts `settings.json` back to a fresh install's state and applies it live: theme, keymap, tab bar, list and preview prefs, and the proxy bind. It also drops the data that lives in the same file — your global env values, hostname overrides, OAST provider tokens, saved decoder chains, and global rewriter and colormarker rules. Projects and their captures are untouched, and so are a project's own pinned bind and env.

One thing survives on purpose: the global rule-id counters. A project can override a global rewriter or colormarker rule by id, and those overrides live in the project's own database, which a settings reset never opens. Rewinding the counter would hand a fresh rule an id an old override still names, so it keeps counting up and `settings.json` keeps a rules-less block to remember where it got to.

### Appearance

| Section | Fields |
|---------|--------|
| **Theme** | Opener: the theme picker (built-ins plus your own) |
| **Display** | Default detail pane, History list time, Line numbers, Wrap long lines, Preview body limit (KiB), Resource meter, Terminal title |
| **Layout** | History Req/Res preview, Probe issue preview, Issues preview, History list order, Sitemap expand depth |
| **Companion** | Companion (Miss Ring), Placement, Motion, Notices |

The Theme row previews the current theme inline, showing its name and a swatch of its palette. See the [Themes guide](/guide/themes/).

Companion is off by default. Turned on, Miss Ring — a gilded ring mascot — says hello on the frame she first appears on, then blinks and winks on her own and reacts to background results, before dozing off after 90 seconds of inactivity and stopping animating entirely. Every 25 seconds or so she also plays one of seven idle gestures, picked at random: a yawn, a smile, a squint, a deadpan, a curious look that turns knowing, a small huff she blinks away, and a narrow-eyed "hmm". Her brows do as much of that as her eyes — both lashes lift for the open, resting face, turn over for the furrowed one, and one at a time for the quizzical one. Her reactions are arcs rather than single faces too: a result lands, she hits the peak — beams, tenses, or recoils — and after a second and a half settles into a quieter version of it for the rest of the reaction. Motion `calm` halves her blink rate and drops the gestures, for SSH sessions and battery; `still` drops the blink as well, so nothing she does on her own moves and she never repaints — the same zero cost as her doze, without the ninety-second wait, for an asciinema recording, a screen reader or a shared tmux pane. The reactions stay in all three; `still` suppresses only the part of one that is literally movement, the flinch on an error, and keeps the face. While a background job is running — a fuzz, a discover, a mine, an in-flight repeater send — she wears a dot bobbing in her badge cell for as long as it lasts, in step with the status row's own activity spinner because it is driven by the same counter. That matters most in `body` placement, where the activity chip is off screen: the corner of the pane is then the only thing telling you the run is still going. A reaction outranks it, so a failure mid-run still shows as `×`. She will not doze off while work is in flight, and work an agent starts over MCP wakes her. That hello is the only thing she says unprompted in a session, and it comes once per launch of gori; with Notices off she says nothing at all.

She stands on the project picker too, in the bottom-right corner beside the card, and that is where the hello now lands: one hello per launch of gori, on whichever screen she first appears on. It is also where she delivers the once-per-release **update available** notice — she says hi, then a beat later that a new version is out and how to install it. She speaks in the same bubble she uses in a session, floating above her head and over the card's right edge for the few seconds she is talking. On a terminal too narrow to seat her beside the card she doesn't appear at all, and the notice goes back to being a plain centered line, exactly as it is with Companion off.

She also turns up in the two standalone screens. The **setup wizard** has a COMPANION step — a still of her beside an on/off choice and her motion — so a first-run user decides whether they want her before ever meeting her; nothing is written until you finish, so Esc leaves the setting exactly as it was. The **guided tour** (`gori tutorial`) is the one place she is genuinely part of the teaching: she stands at the right of the card and confirms each move as you make it — switching a tab, opening the palette, the action menu, INS mode — once each, and signs off at the end. The tour narrows its own card to seat her rather than dropping her on narrow terminals, so she is there from 80 columns; with Companion off the card keeps its full width and the tour renders exactly as it did before. Because the lessons themselves live in the card and she only ever reacts, turning Notices off costs you her encouragement and none of the tour.

Placement decides what she costs *in a session* (the picker has only the one spot). `body` puts an 8&times;3 sprite in the bottom-right of the tab body, where she covers three rows and announces results in a speech bubble. `bar` puts an eight-cell chip at the far right of the status row, past the clock — her face and her mood badge, without the ring's crown and floor: she covers nothing, and the bubble goes away because her line goes through the status row's own text slot instead. The badge is what keeps a reaction legible there at all; without it the chip says "something went wrong" only by shifting one gold a little redder, which is the signal a washed-out terminal has least of. She can sit on the edge like that because she is the same width in every expression, so she never nudges the clock or the CPU/MEM readout as she blinks. That slot holds one message, so the toast and her notice are resolved by whichever is newer. Notices is independent of the bottom-bar toast either way.

### Editor & Keys

| Section | Fields |
|---------|--------|
| **Editor** | External editor, Markdown highlight, Mouse, Pretty-print bodies |
| **Keys** | Command modifier |
| **Env** | Opener: global `$KEY` variables for outbound requests |
| **Hotkeys** | Opener: rebind any shortcut, or pick an OS default profile |

**External editor** is what `^E` opens in editable fields; blank falls back to `$VISUAL` / `$EDITOR` / `vi`. Turning **Mouse** off restores your terminal's native text selection.

**Keys** and **Hotkeys** are the pair: Keys picks *which modifier* fronts gori's built-in chord family (`^P` `^N` `^W` `^1-9`) — `Option (⌥)` adds `⌥` aliases without giving up Ctrl, for terminals that never deliver the Ctrl form — while Hotkeys rebinds *individual actions*. See [Command modifier](/guide/hotkeys/#command-modifier), [Hotkeys](/guide/hotkeys/) and [environment variables](/guide/repeater-and-fuzzer/#environment-variables).

### Network & Tabs

| Section | Fields |
|---------|--------|
| **Network** | Bind IP, Bind Port, Upstream proxy, Verify upstream TLS, Info page and CA download, Connect timeout (s), Idle timeout (s), Capture body limit (MiB), HTTP/2, Strip HTTP/3 Alt-Svc, TLS passthrough, Upstream rules (read-only), Outbound TLS (read-only), Hostname overrides (opener) |
| **Tabs** | Opener: show/hide and reorder the top tab bar |

Network here is the **global default**. A project can pin its own bind address, port, and upstream from the **Project** tab, and those win for that project. See [Configuration](/getting-started/configuration/#network) for the full precedence order.

## In the Project Picker

`Ctrl-,` opens the same modal from the project picker, before any project is loaded, so you can set your theme on first launch. Only **Theme** is editable there. The sections that need a live project (Tabs, Env, Hotkeys, and hostname overrides) stay hidden or report that you need to open a project first, and so does **Reset** — a factory reset has to be applied to a running session.

## Where Settings Live

Everything saved here is written to `settings.json` under the gori home directory. Print or open it directly:

```bash
gori settings          # print the settings.json path
gori settings --edit   # open it in your editor
```

Per-project overrides are not in this file; they live in the project database and are edited from the **Project** tab.

## Next Steps

- [Configuration](/getting-started/configuration/): the storage layout, network precedence, and the root CA
- [Configuration Reference](/reference/config/): every `settings.json` key
- [Themes](/guide/themes/): switch or write a colour theme
- [Hotkeys](/guide/hotkeys/): rebind shortcuts and the key-budget rules
