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

The Theme row previews the current theme inline, showing its name and a swatch of its palette. See the [Themes guide](/guide/themes/).

### Editor & Keys

| Section | Fields |
|---------|--------|
| **Editor** | External editor, Markdown highlight, Mouse, Pretty-print bodies |
| **Env** | Opener: global `$KEY` variables for outbound requests |
| **Hotkeys** | Opener: rebind any shortcut, or pick an OS default profile |

**External editor** is what `^E` opens in editable fields; blank falls back to `$VISUAL` / `$EDITOR` / `vi`. Turning **Mouse** off restores your terminal's native text selection. See [Hotkeys](/guide/hotkeys/) and [environment variables](/guide/repeater-and-fuzzer/#environment-variables).

### Network & Tabs

| Section | Fields |
|---------|--------|
| **Network** | Bind IP, Bind Port, Upstream proxy, Verify upstream TLS, Info page on direct access, Connect timeout (s), Idle timeout (s), Capture body limit (MiB), Hostname overrides (opener) |
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
