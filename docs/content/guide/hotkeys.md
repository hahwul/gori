+++
title = "Hotkeys"
description = "Rebind gori's keyboard shortcuts from settings:hotkeys."
+++

gori's keyboard shortcuts are rebindable from **`settings:hotkeys`** in the command palette (`Ctrl-P`). The editor lists every rebindable action grouped by where it fires (GLOBAL, HISTORY, REPEATER, FUZZER, INTERCEPT, …); pick a row, press a new key, done.

```text
Ctrl-P → settings:hotkeys
```

## Key budget (how new shortcuts earn a key)

Bare letter keys are scarce. New actions should pick a **price tier** before taking a chord:

| Tier | Price | When | Examples |
|------|-------|------|----------|
| **L0 Structural** | `Esc` `Enter` `Tab` arrows `Space` (leader) | Always | focus, open/close, READ/INS, space menu |
| **L1 Loop** | bare letter or sticky family (`^R`) | many times / minute | History `j/k` `/` `y`, Repeater send |
| **L2 Session breath** | Global bare (cap: `c` `i` `s` only) | many times / session | capture, intercept, scope lens |
| **L3 Contextual** | `Space` then mnemonic | occasional, pane-local | compare, mine, send-group, copy-as |
| **L4 Rare / config** | palette (`Ctrl-P`) only | rare | settings, Match & Replace, notifications |

Rules of thumb:

- Default for new pane actions is L3 (space menu only). Promote to a direct key only after the loop proves it.
- **Ctrl** is for actions that must work while typing (INS) or that are destructive. It is not a general upgrade from bare.
- **History → Repeater** and **Repeater send** stay on **`Ctrl-R`** (same muscle memory). Do not move History→Repeater to bare `r`.
- Match & Replace and Notifications ship keyless (palette / badge); rebind them if you want a Global chord.

## Editing

The editor opens a working copy. Nothing is saved until you press `Enter`, and `Esc` discards every change.

| Key | Action |
|-----|--------|
| `↑` / `↓` (or `j` / `k`), wheel | Move the selection |
| `e` or `Space` | Rebind the selected action, then press the new key |
| `x` or `Backspace` | Unbind the selected action |
| `r` | Reset the selected action to its default |
| `Shift-R` | Reset every action to its defaults |
| `←` / `→` | Cycle the OS default profile (see below) |
| `Enter` | Save + apply (live, no restart) |
| `Esc` | Discard and close |

When you start a rebind the footer shows *"press a key to bind"*. Press the chord you want, modifiers included, except the ones listed under *Reserved keys* below. If the key is reserved or already used by another action **in the same place**, the editor refuses it and tells you why; capture stays open so you can try another key.

A row's chord shows `(unbound)` when nothing is bound. The `●` marker means you've changed it from the default; `·` means it's at the default.

## Conflicts

Two actions may share a key only if they fire in **different** places. That's by design (`s` is "scope lens" almost everywhere but "swap" on the Comparer tab, `c` is "toggle capture" everywhere except the Intercept queue where it cycles the catch direction). The editor blocks only a **same-place** collision, because there the keymap could keep just one of them.

## Reserved Keys

Some keys can't be rebound because the terminal or gori needs them:

- **Quit**: `Ctrl-C`, `Ctrl-D`.
- **Indistinguishable from named keys**: `Ctrl-M` / `Ctrl-J` (Enter), `Ctrl-I` (Tab), `Ctrl-H` (Backspace), `Ctrl-[` (Escape).
- **Structural**: `Enter`, `Esc`, `Tab`, `Backspace`, and a bare `:` (the command line).
- **gori shortcuts claimed before the keymap**: `Ctrl-G` (go to line), `Ctrl-F` (find, then `Tab` for find & replace), `Ctrl-B` (reveal whitespace), `Ctrl-E` (external editor), `Ctrl-P` (command palette), `Ctrl-N` (new repeater/fuzz/note), `Ctrl-W` (close sub-tab), and `Ctrl-1`…`Ctrl-9` (switch sub-tab). These are handled by a hardcoded guard before the keymap, so a binding on them would never fire. For the same reason **Command palette**, **New repeater request**, and **New fuzz session** aren't listed in the editor. Their key is fixed.

Flow-control/signal chords like `Ctrl-S` are **not** reserved; gori runs the terminal in raw mode, so they reach the app (Repeater's SNI toggle ships on `Ctrl-S`).

## OS Default Profiles

The `←` / `→` profile selector picks which **default** key set a fresh (un-overridden) binding uses: `auto` (tracks the platform gori was built for), `macOS`, `Linux`, or `Windows`. Your own rebindings always sit on top of the chosen profile, regardless of OS.

Today the per-OS defaults are identical: in a terminal, `Ctrl`+letter chords reach the application on macOS, Linux, and Windows alike, and the genuinely hazardous keys are the reserved control characters above (blocked everywhere). The profile mechanism is in place so a real per-terminal clash can be fixed without touching dispatch. For now, `auto` is the right choice for everyone.

## Where It's Stored

Saved to `~/.gori/settings.json` (override the directory with `$GORI_HOME`) under a sparse `hotkeys` block. Only the bindings you changed are written, as a list of chord labels per action id; an empty list is an explicit unbind:

```json
{
  "hotkeys": {
    "os": "auto",
    "bindings": {
      "rules.edit": ["g"],
      "scope.edit": []
    }
  }
}
```

An absent action uses the profile default. Unknown ids and unparseable chords are ignored on load, so hand-edits and version drift degrade gracefully.

## Limitations

- Only an action's **primary** chord is shown/edited; navigation aliases (e.g. the arrow-key duplicates of `j` / `k`) aren't listed.
- The **command palette** and the **Help** tab (Global / History / Repeater rows wired to verb ids) resolve chords through the effective keymap after a rebind. Other Help sections and some status chips may still use curated defaults.
- Space-menu **mnemonic** letters are stable action identities (Helix-like); rebinding changes the *direct* chord, not the space-menu letter.
- Pane-local keys that share a letter (Repeater response `x` = hex vs request/target `x` = select line) stay controller-owned so both meanings can coexist.
- Press **`?`** from a navigable context to jump to the **Help** tab (mitmproxy-style cheat-sheet).

## Next Steps

- [Themes](/guide/themes/): switch or create colour themes the same way
- [Configuration Reference](/reference/config/): the `hotkeys` key in `settings.json`
