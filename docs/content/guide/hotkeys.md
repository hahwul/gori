+++
title = "Hotkeys"
description = "Rebind gori's keyboard shortcuts from the Preferences modal."
weight = 110

[extra]
group = "Customize"
+++

gori's keyboard shortcuts are rebindable from the **Hotkeys** editor. Reach it from Preferences (`Ctrl-,` → **Editor & Keys** → **Hotkeys**, then `↵`), or jump straight there with **`settings:hotkeys`** in the command palette (`Ctrl-P`). The editor lists every rebindable action grouped by where it fires (GLOBAL, HISTORY, REPEATER, FUZZER, INTERCEPT, …); pick a row, press a new key, done.

```text
Ctrl-,  → Editor & Keys → Hotkeys
Ctrl-P  → settings:hotkeys
```

## Key budget (how new shortcuts earn a key)

Bare letter keys are scarce. New actions should pick a **price tier** before taking a chord:

| Tier | Price | When | Examples |
|------|-------|------|----------|
| **L0 Structural** | `Esc` `Enter` `Tab` arrows `Space` (leader) | Always | focus, open/close, READ/INS, space menu |
| **L1 Loop** | bare letter or sticky family (`^R`) | many times / minute | History/Issues `j/k` `/` `y` `t` (mark) `v` (view), sub-tab strip `t` (mark), Repeater send |
| **L2 Session breath** | Global bare (cap: `c` `i` `s` only) | many times / session | capture, intercept, scope lens |
| **L3 Contextual** | `Space` then mnemonic | occasional, pane-local | compare, mine, send-group, copy-as |
| **L4 Rare / config** | palette (`Ctrl-P`) or Preferences (`Ctrl-,`) | rare | settings, Match & Replace, notifications |

Rules of thumb:

- Default for new pane actions is L3 (space menu only). Promote to a direct key only after the loop proves it.
- **Ctrl** is for actions that must work while typing (INS), and for run/stop on a workbench (`Ctrl-R` / `Ctrl-X`). It is not a general upgrade from bare.
- **Shift** carries the whole-tab wipes. `⇧X` is `Clear` in every tab that has one (History, Probe, Authorize, Issues, and the Project ACTIVITY feed), with `X` as the space-menu letter beside it. The letter is `x` and not `c` because of what sits under the shift: bare `x` is bound in none of those five scopes, while bare `c` is live in all of them (`capture.toggle`, and `dismiss` on the Probe list), and a project wipe does not belong one shift above a key an operator presses all day. A destructive chord must also be **named where it can be read before it is pressed** (the Help sheet and the tab's own body hint, not the space menu alone), and it must ask first.
- **`d` destroys.** Bare `d` deletes or dismisses the selected row in every scope that binds it — sixteen of them. The Repeater's response diff was the one exception, and it now sits on `⇧D` so the reflex never lands on a display toggle. Its space-menu letter is `⇧D` too: `d` is **Duplicate sub-tab** on all nine sub-tab strips (see [the space menu](#space-menu)), and that bucket is drawn in every pane, so the plain letter was no longer the diff toggle's to keep — which leaves the row and the keyboard spelling it the same way. A new pane action that is not a delete does not get `d`.
- **Copy is the worked example of that rule.** `y` copies in READ, and `Ctrl-Y` copies in **INS as well**, in every text box. In INS a bare `y` is a literal character, and typing it over a `Shift`+arrows selection *replaces* the selection, so the copy reflex needs a chord that survives typing. Both are the same verb (`*.copy`), so a rebind moves the READ letter and **`Ctrl-Y` stays where it is**: it is pinned, in every scope, including through an explicit unbind. Unbinding `y` is a statement about READ mode, and it must not quietly leave a text pane with no way at all to copy what you just selected.
- **Every list that holds something worth copying binds `y`.** A pane that shows bytes, a row, or a line of record and answers nothing to `y` is a gap, not a design: the Intercept queue, the Evidence archive, the Project ACTIVITY feed and the OAST callback detail each had one and each now answers the letter. Where two copies live in one place and mean opposite things — OAST's list copies the payload gori *sent*, its detail copies what came *back* — only one can hold the chord (a scope has no focus dimension in the keymap), and the other keeps its space-menu letter.
- **`/` filters the list you are looking at.** Every list long enough to scroll answers it, including the three rule lists that did not: Colormarker, Match & Replace and the Probe **RULES** sub-tab (~40 built-in rules across three sections). The bar is a **lens** — it hides rows, it never disables one — and `Esc` clears it. The one thing it changes is reordering: on the two lists where order decides which rule wins, a move is refused while a query is held, because a filtered list is not the order the rule engine holds.
- **`f` has two tiers and one exception.** It is **freeze** in every evidence context (an Issue's RELATED card, the evidence viewer) and **find** on the sub-tab strip — a different tier, which cannot collide. History's follow and the Comparer's fold-unchanged are `Space` menu entries instead; both are session-rare toggles, which is what L3 is for. The exception is the **Intercept queue**, where `f` forwards the held request and `⇧F` forwards them all: that is the tab's own loop key and its `f`/`⇧F` family is internally coherent, so it is documented rather than moved — the same call `Ctrl-R` gets for History → Repeater.
- **`x` selects a line; `t` flips a row's flag.** `x` means "select this line" in fourteen scopes, and it was "enable/disable this rule" in four (Colormarker, Match & Replace, the Probe **RULES** list and the OAST providers). Those four now answer `t`, which is what `t` already means as **mark** in History, Issues, the Sitemap and the Intercept queue — a rule list has no marks, so nothing collides, and the Rewriter's toggle stops being a hand-rolled controller key and becomes an ordinary rebindable chord.
- The space menu is **not** an INS fallback: text editors swallow keys upstream, so `Space` stays a literal character there. An action that has to be reachable while typing needs a Ctrl chord, and a mnemonic alone is not enough. (This is why `Ctrl-Q`, not the space menu alone, carries the Repeater/Fuzzer decoder-chain editor after it gave `Ctrl-Y` up to Copy.)
- **History → Repeater** and **Repeater send** stay on **`Ctrl-R`** (same muscle memory). Do not move History→Repeater to bare `r`.
- Match & Replace and Notifications ship keyless (palette / badge); rebind them if you want a Global chord.

## Editing {#editing}

The editor opens a working copy. Nothing is saved until you press `Enter`, and `Esc` discards every change.

| Key | Action |
|-----|--------|
| `↑` / `↓` (or `j` / `k`), wheel | Move the selection |
| `/` | Search the action list |
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

## The Digit Family {#digits}

The tab bar is **nine numbered slots**, and the numbers are the primary way to move:

| Key | Action |
|-----|--------|
| `1`–`9` | Jump to slot N on the tab bar |
| `0` | **Go to tab…** — a type-to-filter list of all 21 tabs, the nine slots and the hidden ones |
| `⇧1`–`⇧9` | Jump to sub-tab N of the active tab |
| `⇧0` | **Find sub-tab…** — the same picker `f` opens from the strip |

These work from **everywhere** — the tab bar, the sub-tab strip, a list body, a drill-in
detail, a read-only pane — with one exception: while a field is taking text (an editor in
INS, a `/` query bar or search, a line prompt, a picker's filter, the CVSS scorer, the
Decoder's CHAIN field), a digit is a character. It is the same rule `Space` follows: where
`Space` types a space, `3` types a 3 — which is what makes `base64`, `sha256` and `rot13`
typeable into a conversion chain.

The bar paints the numbers by default (**Preferences → Layout → Tab numbers**, `settings:layout`).
The far-right pill reads `0:+12` — the key, and how many tabs are behind it.

### Nine slots, and the tenth tab

`settings:tabs` refuses a tenth ✓ and says so; hide one first. A layout saved by an older
build (the bar used to be unbounded) is truncated to its **first nine, in your own order**,
and gori names the folded tabs once on the launch that does it.

One tab can still ride past the ninth slot: a hidden tab you jumped to with `0` sits at the
far right of the bar, **without a number**, until you leave it. It is where you are standing,
not a slot you arranged — and no digit points at it.

If you want the old unbounded bar back, turn off **Preferences → Layout → Tab bar slots**.
The bar then scrolls with `‹` `›` again, `1`–`9` still reach its first nine tabs, and `0`
still reaches every tab.

### Keyboard layouts

A terminal speaking the **kitty keyboard protocol** reports `⇧3` as `3` plus a shift flag,
and gori binds that. Every other terminal sends the shifted digit as a **character** — `#` on
a US layout — which gori folds back onto `⇧3`. On a **non-US layout** that character is a
different one, so `⇧1`–`⇧9` work where your terminal reports the shift modifier and not
otherwise. Both fallbacks are always live: **`f`** on the sub-tab strip opens the same picker
`⇧0` does, and `Ctrl-1`…`Ctrl-9` is the alias for `⇧1`–`⇧9` on terminals that deliver it.

## The space menu {#space-menu}

`Space` in a navigable pane opens the action menu for **where you are standing** — the
pane's own verbs, grouped under `COMMON` and the focused area's label, each fronted by one
mnemonic letter. It is not the palette: there is no typing and no filter, just one keypress
per row.

### One menu per tab, whatever has focus

Nine tabs carry a **sub-tab strip** — Repeater, Fuzzer, Miner, Sequencer, Decoder, JWT,
Cookie, Comparer and Notes. The strip's own actions used to be a context section like any
other: they appeared *only* while the strip had focus, so from a body pane you had to walk
focus up a level before `Space` would even offer "close this sub-tab".

They are now their own `SUB-TABS` bucket, and it is in the menu from **every** level of a tab
that has a strip — the body panes, the strip itself and the tab bar. With `⇧1`–`⇧9` dropping
you anywhere, what `Space` offers must not depend on which row the cursor happens to be on.

### The same nine letters on all nine strips

The bucket is one table to learn, not nine. A tab that does not have an action simply omits
the row; it never spends that letter on something else.

| Key | Action | Direct chord |
|-----|--------|--------------|
| `n` | New sub-tab | `Ctrl-N` |
| `w` | Close sub-tab (or every marked one) | `Ctrl-W` |
| `d` | Duplicate sub-tab | |
| `e` | Rename sub-tab | `r` on the strip |
| `t` | Tag sub-tab (Repeater) | |
| `f` | Search sub-tabs — the `⌕` picker | `f` on the strip, `⇧0` anywhere |
| `/` | Filter the strip (name / host / method / tag) | |
| `T` | Mark every sub-tab the filter shows | |
| `N` | Clear the sub-tab marks | `Esc` on the strip |

`Ctrl-N` and `Ctrl-W` are shown beside their rows, and they work from any pane on all nine
tabs — the menu teaches the faster key rather than hiding it. (Miner and Sequencer seed
their sessions from a run, so they have no `n`.)

Because the bucket rides along with every pane, its nine letters are **reserved in every view
of those tabs**. A pane action that wanted one had to move: the rule is that the *pane* letter
yields, since the strip's letter has to read the same on all nine strips. `Space` `W` marks a
word in the Repeater/Fuzzer editors, `Space` `D` toggles the response diff, and the JWT and
Cookie lens toggles moved to `m` (Mode — the Decoder's letter for the same gesture).

## Editor Keysets {#editor-keysets}

gori's text panes are **modal**: `Esc` and `i` move between READ and INSERT, and in READ the bare letters are commands. The shipped grammar is helix-shaped — **`x` selects the line, then `y` copies it** — which is one gesture away from vim, where the same thing is `V` then `y`. That one difference is what a vim-trained hand fights all day.

**Preferences → Editor & Keys → Keys → Editor keyset** (`Ctrl-,`), or **`settings:keys`** in the palette, switches it:

| Keyset | Select line | Undo | Find | Append | Top / bottom |
|--------|-------------|------|------|--------|--------------|
| **helix-ish** (default) | `x` | `Ctrl-Z` | `Ctrl-F` | — | — |
| **vim-ish** | `⇧V` | `u` | `/` | `a` | `g` / `⇧G` |

Everything not in that table is the same under both keysets, because gori already spells it the way vim does: `i` enters INSERT, `Esc` leaves it, `y` copies, `Ctrl-G` goes to a line, and arrows plus `Shift` extend a selection.

### A keyset is a mapping, not an emulation

It is a named bundle of key **overrides** for a small, fixed set of editor actions — exactly the mechanism the [OS default profiles](#os-default-profiles) are, one layer up. It does not add an operator-pending grammar, registers, counts, text objects, or any editing operation gori's panes do not already have. A READ-mode pane is a caret, a selection and a copy; naming keys for operations that do not exist is how "vim mode" becomes a promise the editor breaks.

So some vim spellings are deliberately **not** offered, each for a reason you can check:

- **`gg`, `dd`, `yy` and every other two-key sequence.** A gori chord is one keystroke. `g` alone is the top of the pane, and `y` with nothing selected already copies the whole pane — which is the useful half of what `yy` means.
- **`:` commands, including `:42`.** A bare `:` is [reserved](#reserved-keys) for gori's own command line, so go-to-line stays `Ctrl-G` under both keysets.
- **Delete.** There is no delete-line in a READ-mode pane to put on `dd` or `D`. Editing happens in INSERT.
- **The enable/disable `x` on a rule list** (Colormarker, Probe rules, OAST providers, Rewriter). That `x` turns a rule on and off; it is not a selection, and a keyset does not move a state change onto `⇧V`.
- **The Intercept queue's select-line**, which ships keyless on purpose — that pane reaches it from the space menu, and a keyset respells keys rather than handing one to a pane whose author decided against it.

### The override order

Four layers, most specific first:

```text
your own rebinding  >  the keyset  >  the OS default profile  >  the shipped chord
```

A keyset is therefore a better **default**, never a ceiling: pick `vim-ish` and then rebind one action in the [Hotkeys editor](#editing), and that one stays where you put it. "Reset to default" on a row puts it back to the **active keyset's** spelling, not to the shipped one.

Every surface follows the active keyset with no extra step, because they all read the effective keymap: the status hint strips, the Help tab, the command palette, the space menu and the Hotkeys editor's own conflict messages. Under `vim-ish` the Notes footer reads `/ find` where it read `^F find`, and binding something to `⇧V` is refused by name because Select line is there.

### It does not touch the space menu's letters

A keyset moves the key you press **in the pane**, not the letter the [space menu](#space-menu) puts in front of a row — the same rule any per-action rebind follows, and the reason those letters are stable identities. Under `vim-ish` the menu still fronts Select line with `x`, and prints the live chord beside it:

```text
│ x Select line   ⇧V │
```

so the card teaches both halves rather than making you guess which one it means. The nine `SUB-TABS` letters (`n` `w` `d` `e` `t` `f` `/` `T` `N`) likewise mean the same thing on all nine strips whichever keyset you pick. The two namespaces cannot collide: the menu is modal, and a keyset only ever writes to the keymap.

That includes `/`, which is a `SUB-TABS` letter *and* `vim-ish`'s find key. They are different tiers — the menu letter acts on the strip while the card is up, the chord searches the text pane you are standing in — and gori checks the chord half at boot: `validate_chords!` sweeps every (OS profile × keyset) cell, and a keyset letter that shadowed a pane's own key would fail the build rather than ship.

### What still works whatever you pick

`Ctrl-Z` keeps undoing **inside INSERT** under `vim-ish` — that guard runs before the keymap in all nine text editors, which is where a typing hand wants it. `Ctrl-F` likewise still opens the find prompt, INSERT included; `/` is an addition in READ, not a replacement. And `i` is refused with a message on a read-only pane that sits beside an editor (the Repeater response, the Fuzzer results, the Decoder output), under both keysets.

## Reserved Keys {#reserved-keys}

Some keys can't be rebound because the terminal or gori needs them:

- **Quit**: `Ctrl-C`, `Ctrl-D`.
- **Indistinguishable from named keys**: `Ctrl-M` / `Ctrl-J` (Enter), `Ctrl-I` (Tab), `Ctrl-H` (Backspace), `Ctrl-[` (Escape).
- **Structural**: `Enter`, `Esc`, `Tab`, `Backspace`, `Space` (the space-menu leader), and a bare `:` (the command line).
- **gori shortcuts claimed before the keymap**: `Ctrl-G` (go to line), `Ctrl-F` (find, then `Tab` for find & replace), `Ctrl-B` (reveal whitespace), `Ctrl-E` (external editor), `Ctrl-P` (command palette), `Ctrl-N` (new repeater/fuzz/note), `Ctrl-W` (close the sub-tab, or every marked one), `Ctrl-Z` (undo, consumed by every text editor: Repeater, Fuzzer, Notes, Issues, Intercept, Decoder, JWT, Rewriter and the Project description), `Ctrl-,` (Preferences), and `Ctrl-1`…`Ctrl-9` (switch sub-tab — the **alias** for `⇧1`–`⇧9`, see [The digit family](#digits)). These are handled by a hardcoded guard before the keymap, so a binding on them would never fire. For the same reason **Command palette**, **Reveal whitespace**, **New repeater request**, and **New fuzz session** aren't listed in the editor. Their key is fixed.

  You can't move an individual key out of that family, but you *can* give the whole family a second modifier; see [Command modifier](#command-modifier) below.

  `Ctrl-G` / `Ctrl-F` act on whichever multi-line pane has focus: the Repeater's request and response, the History detail, the Intercept editor, Notes, the Project description, the Decoder's INPUT and OUTPUT, and the Fuzzer's template and result detail. `Tab` switches find to find & replace on the six that are editable; everything else is read-only, and the prompt says so rather than offering a swap it cannot make.

Flow-control/signal chords like `Ctrl-S` are **not** reserved; gori runs the terminal in raw mode, so they reach the app (Repeater's SNI toggle ships on `Ctrl-S`).

## OS Default Profiles {#os-default-profiles}

The `←` / `→` profile selector picks which **default** key set a fresh (un-overridden) binding uses: `auto` (tracks the platform gori was built for), `macOS`, `Linux`, or `Windows`. Your own rebindings always sit on top of the chosen profile, regardless of OS.

Today the per-OS defaults are identical: in a terminal, `Ctrl`+letter chords reach the application on macOS, Linux, and Windows alike, and the genuinely hazardous keys are the reserved control characters above (blocked everywhere). The profile mechanism is in place so a real per-terminal clash can be fixed without touching dispatch. For now, `auto` is the right choice for everyone.

## Command Modifier {#command-modifier}

The chord family listed under *Reserved keys* is fixed because a hardcoded guard runs before the keymap. That's a problem when your terminal never delivers the Ctrl form at all:

- **`Ctrl-1`…`Ctrl-9` is undeliverable on many terminals**: there is no control character for it, so the sub-tab jumps simply never arrive. You never need it: **`⇧1`–`⇧9`** is the primary sub-tab jump (see [The digit family](#digits)), and on a sub-tab strip **`f`** lists and searches every open sub-tab, from whichever chip you are standing on. (The **`⌕`** at the strip's left edge opens the same list; click it, or press `←` from the first chip.)
- **A multiplexer eats the chord first.** tmux's default prefix is `Ctrl-B`, which gori also uses for reveal-whitespace.

**Preferences → Editor & Keys → Keys → Command modifier** (`Ctrl-,`), or **`settings:keys`** in the palette, switches that family between `Ctrl` and `Option (⌥)`. It is an **alias, not a swap**: with Option selected, `⌥P` opens the palette *and* `^P` still does. Only the advertised form changes: status hints, the Help tab and the palette all start showing `⌥P`, `⌥N`, `⌥1-9`.

| Modifier | Effect |
|----------|--------|
| `Ctrl` (default) | `^P` `^N` `^W` `^G` `^F` `^B` `^E` `^Z` `^,` `^1`-`^9` |
| `Option (⌥)` | the above **plus** `⌥P` `⌥N` `⌥W` `⌥G` `⌥F` `⌥B` `⌥E` `⌥Z` `⌥,` `⌥1`-`⌥9` |

Because Ctrl keeps working, picking Option can never lock you out of the palette. That is worth knowing before you flip it, since **on macOS your terminal must be set to send Option as Meta/Esc+** or `⌥P` arrives as `π` and nothing happens:

- **Terminal.app**: Settings → Profiles → Keyboard → *Use Option as Meta key*
- **iTerm2**: Settings → Profiles → Keys → Left/Right Option key → *Esc+*

Two things it does not do. It doesn't touch chords the editor can already rebind (`^R` send, `^S` SNI, …); rebind those per action instead. And if you had bound an action to an `Option` chord in the family (`alt-n`, say), turning the alias on shadows it: the guard wins, that action reverts to its default, and the save toast names it.

The first-run wizard recaps this on its Review step, so you can pick a modifier before ever reaching the app.

## Where It's Stored

Saved to `~/.gori/settings.json` (override the directory with `$GORI_HOME`) under a sparse `hotkeys` block. Only the bindings you changed are written, as a list of chord labels per action id; an empty list is an explicit unbind:

```json
{
  "hotkeys": {
    "os": "auto",
    "command_modifier": "alt",
    "keyset": "vim",
    "bindings": {
      "rules.edit": ["g"],
      "scope.edit": []
    }
  }
}
```

`command_modifier` is `"ctrl"` (the default) or `"alt"`, and `keyset` is `"helix"` (the default) or `"vim"` — see [Editor keysets](#editor-keysets). An unknown value for either falls back to the default rather than to no keys. An untouched install writes no `hotkeys` block at all.

An absent action uses the profile default. Unknown ids and unparseable chords are ignored on load, so hand-edits and version drift degrade gracefully.

## Limitations

- Only an action's **primary** chord is shown/edited; navigation aliases (e.g. the arrow-key duplicates of `j` / `k`) aren't listed.
- Every surface that names a rebindable chord reads it from the effective keymap: the **command palette**, the **space menu**, the **Help** tab and its popup, the status-bar hint strips, and the empty-state cards. What stays literal is not a verb: the claimed `^P` / `^N` / `^W` / `^1-9` family (the sub-tab alias) and structural keys (`esc`, `↵`, arrows, `↹`).
- Space-menu **mnemonic** letters are stable action identities (Helix-like); rebinding changes the *direct* chord, not the space-menu letter.
- Where the **sub-tab strip** already binds a letter for an action, the menu spells that action with the same letter where it can: `f` lists and searches the sub-tabs, `t` marks a chip and `⇧T` marks the strip. Rename is the one it cannot match — the strip binds `r`, and `r` is `Run`/`Send` (the menu echo of `Ctrl-R`) in the Repeater, Fuzzer, Miner and Sequencer, where a rename does not get to displace it. One action must not have two spellings across the nine strips, so rename is **`e` on all of them** and the strip's `r` stays a raw chord. See [the space menu](#space-menu) for the whole table.
- The editor actions are rebindable individually, and as a set via [Editor keysets](#editor-keysets). What the rebind editor will not move is the handful whose chord a hardcoded guard answers first: `Esc` (back to READ), `Ctrl-Z`, `Ctrl-F` and `Ctrl-G`. They are listed in the Help sheet so you can read them, and a keyset can give them a second, bare spelling — which is how `vim-ish` reaches `u` and `/`.
- Press **`?`** from a navigable context to jump to the **Help** tab (mitmproxy-style cheat-sheet).

## Next Steps

- [Settings](/guide/settings/): the Preferences modal and every section in it
- [Themes](/guide/themes/): switch or create colour themes the same way
- [Configuration Reference](/reference/config/): the `hotkeys` key in `settings.json`
