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
| `Ctrl-R` | Reset the current section to its defaults (still needs `↵` to persist) |
| `Esc` | Close, discarding unsaved edits |

Edits are a working copy: nothing is written until you press `↵`, and `Esc` throws them away. Saving applies live, with no restart.

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

Notifications fire on background results from the Miner, Fuzzer, Probe, and Discover. The [Statusline](/reference/config/#statusline) runs a shell command on an interval and renders its stdout as the bottom row.

### Appearance

| Section | Fields |
|---------|--------|
| **Theme** | Opener: the theme picker (built-ins plus your own) |
| **Display** | Default detail pane, History list time, Line numbers, Preview body limit (KiB), Resource meter, Terminal title |
| **Layout** | History Req/Res preview, Probe issue preview, Issues preview, History list order, Sitemap expand depth |
| **Pet** | Pet (Miss Ring), Placement, Motion, Notices |

The Theme row previews the current theme inline, showing its name and a swatch of its palette. See the [Themes guide](/guide/themes/).

Pet is off by default. Turned on, Miss Ring — a gilded ring mascot — says hello on the frame she first appears on, then blinks and winks on her own and reacts to background results, before dozing off after 90 seconds of inactivity and stopping animating entirely. Motion `calm` halves her blink rate and drops the rest, for SSH sessions and battery. That hello is the only thing she says unprompted in a session, and it comes once per launch of gori; with Notices off she says nothing at all.

She stands on the project picker too, in the bottom-right corner beside the card, and that is where the hello now lands: one hello per launch of gori, on whichever screen she first appears on. It is also where she delivers the once-per-release **update available** notice — she says hi, then a beat later that a new version is out and how to install it. She speaks in the same bubble she uses in a session, floating above her head and over the card's right edge for the few seconds she is talking. On a terminal too narrow to seat her beside the card she doesn't appear at all, and the notice goes back to being a plain centered line, exactly as it is with Pet off.

Placement decides what she costs *in a session* (the picker has only the one spot). `body` puts an 8&times;3 sprite in the bottom-right of the tab body, where she covers three rows and announces results in a speech bubble. `bar` puts a seven-cell chip at the far right of the status row, past the clock — her face alone, without the ring's crown and floor: she covers nothing, and the bubble goes away because her line goes through the status row's own text slot instead. She can sit on the edge like that because she is the same width in every expression, so she never nudges the clock or the CPU/MEM readout as she blinks. That slot holds one message, so the toast and her notice are resolved by whichever is newer. Notices is independent of the bottom-bar toast either way.

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
| **Network** | Bind IP, Bind Port, Upstream proxy, Verify upstream TLS, Info page and CA download, Connect timeout (s), Idle timeout (s), Capture body limit (MiB), Hostname overrides (opener) |
| **Tabs** | Opener: show/hide and reorder the top tab bar |

Network here is the **global default**. A project can pin its own bind address, port, and upstream from the **Project** tab, and those win for that project. See [Configuration](/getting-started/configuration/#network) for the full precedence order.

## In the Project Picker

`Ctrl-,` opens the same modal from the project picker, before any project is loaded, so you can set your theme on first launch. Only **Theme** is editable there. The sections that need a live project (Tabs, Env, Hotkeys, and hostname overrides) stay hidden or report that you need to open a project first.

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
