# Customizing hotkeys

gori's keyboard shortcuts are rebindable from **`settings:hotkeys`** in the command
palette (`^P`). The editor lists every rebindable action grouped by where it fires
(GLOBAL, HISTORY, REPLAY, FUZZER, INTERCEPT, …); pick a row, press a new key, done.

```
^P → settings:hotkeys
```

## Editing

The editor opens a working copy — nothing is saved until you press `↵`, and `esc`
discards every change.

| Key | Action |
|-----|--------|
| `↑/↓` (or `j/k`), wheel | move the selection |
| `e` or `␣` | rebind the selected action — then **press the new key** |
| `x` or `⌫` | unbind the selected action |
| `r` | reset the selected action to its default |
| `⇧R` | reset every action to its defaults |
| `←/→` | cycle the OS default profile (see below) |
| `↵` | save + apply (live — no restart) |
| `esc` | discard and close |

When you start a rebind the footer shows *"press a key to bind"*. Press the chord you
want (modifiers included, e.g. `Ctrl-J`… well, not that one — see *Reserved keys*). If
the key is reserved or already used by another action **in the same place**, the editor
refuses it and tells you why; capture stays open so you can try another key.

A row's chord shows `(unbound)` when nothing is bound. The `●` marker means you've
changed it from the default; `·` means it's at the default.

## Conflicts

Two actions may share a key only if they fire in **different** places — that's by
design (`s` is "scope lens" almost everywhere but "swap" on the Comparer tab, `c` is
"toggle capture" everywhere except the Intercept queue where it cycles the catch
direction). The editor blocks only a **same-place** collision, because there the keymap
could keep just one of them.

## Reserved keys

Some keys can't be rebound because the terminal or gori needs them:

- **Quit** — `Ctrl-C`, `Ctrl-D`.
- **Indistinguishable from named keys** — `Ctrl-M`/`Ctrl-J` (Enter), `Ctrl-I` (Tab),
  `Ctrl-H` (Backspace), `Ctrl-[` (Escape).
- **Structural** — `Enter`, `Esc`, `Tab`, `Backspace`, and a bare `:` (the command line).
- **gori shortcuts claimed before the keymap** — `Ctrl-G` (go to line), `Ctrl-F` (find),
  `Ctrl-B` (reveal whitespace), `Ctrl-E` (external editor), `Ctrl-P` (command palette),
  `Ctrl-N` (new replay/fuzz/note), `Ctrl-W` (close sub-tab), and `Ctrl-1`…`Ctrl-9` (switch
  sub-tab). These are handled by a hardcoded guard before the keymap, so a binding on them
  would never fire. For the same reason **Command palette**, **New replay request**, and
  **New fuzz session** aren't listed in the editor — their key is fixed.

Flow-control/signal chords like `Ctrl-S` are **not** reserved — gori runs the terminal
in raw mode, so they reach the app (replay's SNI toggle ships on `Ctrl-S`).

## OS default profiles

The `←/→` profile selector picks which **default** key set a fresh (un-overridden)
binding uses: `auto` (tracks the platform gori was built for), `macOS`, `Linux`, or
`Windows`. Your own rebindings always sit on top of the chosen profile, regardless of OS.

Today the per-OS defaults are identical: in a terminal, `Ctrl`+letter chords reach the
application on macOS, Linux, and Windows alike, and the genuinely hazardous keys are the
reserved control characters above (blocked everywhere). The profile mechanism is in
place so a real per-terminal clash can be fixed without touching dispatch — for now,
`auto` is the right choice for everyone.

## Where it's stored

Saved to `~/.gori/settings.json` (override the directory with `$GORI_HOME`) under a
sparse `hotkeys` block — only the bindings you changed are written, as a list of chord
labels per action id; an empty list is an explicit unbind:

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

An absent action uses the profile default. Unknown ids and unparseable chords are
ignored on load, so hand-edits and version drift degrade gracefully.

## Limitations

- Only an action's **primary** chord is shown/edited; navigation aliases (e.g. the
  arrow-key duplicates of `j/k`) aren't listed.
- The **Help** tab (digit `9`) and the status-bar hints show **default** chords, not
  your rebindings — if you remap something, those still advertise the original key.
