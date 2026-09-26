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
- **A pane's own key answers only in that pane.** The Repeater's `p` (pretty bodies) and `⇧D` (diff) act in the response pane, and the Fuzzer's `m` (matched only) and `v` (distribution sidebar) in RESULTS. In the request and template panes the space menu uses `p`, `D` and `v` for other actions (pretty-print the request, the decoder chain, clear the selection), so there the bare key does nothing, rather than something the menu did not teach.
- **Copy is the worked example of that rule.** `y` copies in READ, and `Ctrl-Y` copies in **INS as well**, in every text box. In INS a bare `y` is a literal character, and typing it over a `Shift`+arrows selection *replaces* the selection, so the copy reflex needs a chord that survives typing. Both are the same verb (`*.copy`), so a rebind moves the READ letter and **`Ctrl-Y` stays where it is**: it is pinned, in every scope, including through an explicit unbind. Unbinding `y` is a statement about READ mode, and it must not quietly leave a text pane with no way at all to copy what you just selected.
- **Every list that holds something worth copying binds `y`.** A pane that shows bytes, a row, or a line of record and answers nothing to `y` is a gap, not a design: the Intercept queue, the Evidence archive, the Project ACTIVITY feed and the OAST callback detail each had one and each now answers the letter. Where two copies live in one place and mean opposite things — OAST's list copies the payload gori *sent*, its detail copies what came *back* — only one can hold the chord (a scope has no focus dimension in the keymap), and the other keeps its space-menu letter.
- **`/` filters the list you are looking at.** Every list long enough to scroll answers it, including the three rule lists that did not: Colormarker, Match & Replace and the Probe **RULES** sub-tab (~40 built-in rules across three sections). The bar is a **lens** — it hides rows, it never disables one — and `Esc` clears it. The one thing it changes is reordering: on the two lists where order decides which rule wins, a move is refused while a query is held, because a filtered list is not the order the rule engine holds.
- **`f` has two tiers and one exception.** It is **freeze** in every evidence context (an Issue's RELATED card, the evidence viewer) and **find** on the sub-tab strip — a different tier, which cannot collide. History's follow and the Comparer's fold-unchanged are `Space` menu entries instead; both are session-rare toggles, which is what L3 is for. The exception is the **Intercept queue**, where `f` forwards the held request and `⇧F` forwards them all: that is the tab's own loop key and its `f`/`⇧F` family is internally coherent, so it is documented rather than moved — the same call `Ctrl-R` gets for History → Repeater.
- **`x` selects a line; `t` flips a row's flag.** `x` means "select this line" in fourteen scopes, and it was "enable/disable this rule" in four (Colormarker, Match & Replace, the Probe **RULES** list and the OAST providers). Those four now answer `t`, which is what `t` already means as **mark** in History, Issues, the Sitemap and the Intercept queue — a rule list has no marks, so nothing collides, and the Rewriter's toggle stops being a hand-rolled controller key and becomes an ordinary rebindable chord.
- **`s` goes to the source, or flips the scope lens.** Those are its only two meanings. `s` opens the tab a row lives in — the Evidence archive, an Issue's RELATED card, and the Probe list and detail — and everywhere it is not one of those, it is the Global scope lens. What it stopped meaning: swap A ⇄ B on the Comparer and the Diff (now **`w`**), and global ⇄ project on the Colormarker and Match & Replace rule lists (now `Space` menu entries, so the lens is no longer shadowed there). One shadow is left and named: the Project **ACTIVITY** feed's `s` cycles the source chip, because that pane's `/` bar is a free-text query and does not parse `source:` / `level:` / `actor:` to fold the three chips into.
- The space menu is **not** an INS fallback: text editors swallow keys upstream, so `Space` stays a literal character there. An action that has to be reachable while typing needs a Ctrl chord, and a mnemonic alone is not enough. (This is why `Ctrl-Q`, not the space menu alone, carries the Repeater/Fuzzer decoder-chain editor after it gave `Ctrl-Y` up to Copy.)
- **History → Repeater** and **Repeater send** stay on **`Ctrl-R`** (same muscle memory). Do not move History→Repeater to bare `r`.
- **`r` sends to the Repeater; `Ctrl-R` runs.** Bare `r` is "send this row to the Repeater" in the five scopes that have a flow to send, and nothing elsewhere: the Diff's Run moved to `Ctrl-R` (which already owns Run in nine scopes), OAST's Resume listener moved to `Shift-R`, and the Project ACTIVITY feed's Refresh is a `Space` menu entry — a feed with a refresh key probably wants none at all, since it already re-reads on entry, on a peer's write and on the poll. The sub-tab strip's `r` = rename is a different tier and is unaffected.
- Match & Replace and Notifications ship keyless (palette / badge); rebind them if you want a Global chord.

## One bare letter, one question {#grammar}

Bare letters are settled per **question**, not per tab. An action takes one of these only if it
answers that letter's question; anything else starts at L3 (the space menu).

| Key | Means |
|-----|-------|
| `Enter` | show this row in place |
| `o` | open this row's own detail (`Enter`'s alias; on the Sitemap `Enter` expands, so `o` is the only one) |
| `s` | go to the tab this row lives in — else the scope lens |
| `d` | delete / dismiss the selected row |
| `y` | copy |
| `t` | flip this row's flag (mark, or a rule's on/off) |
| `a` | add a row here |
| `e` | edit the selected row |
| `/` | filter this list |
| `f` | freeze (evidence) · find (the sub-tab strip) |
| `r` | send this to the Repeater |
| `Ctrl-R` | run |
| `w` | swap A ⇄ B |
| `x` | select this line |
| `Shift-X` | clear this tab (asks first) |
| `Space` | this tab's command menu |

Three exceptions are deliberate, each a tab's own loop key: **Intercept** `f` forwards (and
`Shift-F` forwards all), **History → Repeater** and **Repeater send** stay on `Ctrl-R`, and the
Project **ACTIVITY** feed's `s` cycles the source chip.

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

Two actions may share a key only if they fire in **different** places. That's by design (`s` is "scope lens" almost everywhere but "go to source" on Probe, `c` is "toggle capture" everywhere except the Intercept queue where it cycles the catch direction). The editor blocks only a **same-place** collision, because there the keymap could keep just one of them.

## The Digit Family {#digits}

The tab bar is **nine numbered slots**, and the numbers are the primary way to move:

| Key | Action |
|-----|--------|
| `1`–`9` | Jump to slot N on the tab bar |
| `0` | **Go to tab…** — a type-to-filter list of all 21 tabs, each with a line on what it is for |
| `⇧1`–`⇧9` | Jump to sub-tab N of the active tab |
| `⇧0` | **Find sub-tab…** — the same picker `f` opens from the strip |

<figure class="tui-shot">
  <img src="/images/tui/tab-goto.svg" alt="gori Go to tab card: a filter bar over the whole tab catalog, the nine tabs on the bar wearing the digits 1 to 9 and everything else wearing none, each row followed by a line saying what that tab is for">
  <figcaption><code>0</code> opens the whole catalog. The nine on the bar wear the digit that reaches them; the rest wear none — that is the only difference being off the bar makes.</figcaption>
</figure>

These work from **everywhere** — the tab bar, the sub-tab strip, a list body, a drill-in
detail, a read-only pane — with one exception: while a field is taking text (an editor in
INS, a `/` query bar or search, a line prompt, a picker's filter, the CVSS scorer, the
Decoder's CHAIN field), a digit is a character. It is the same rule `Space` follows: where
`Space` types a space, `3` types a 3 — which is what makes `base64`, `sha256` and `rot13`
typeable into a conversion chain.

The bar paints the numbers by default (**Preferences → Layout → Tab numbers**, `settings:layout`).
The pill just past the last tab reads `0:Tabs` — the key, and what it opens. It sits two
columns after the ninth slot rather than pinned to the right edge, so the order `→` walks and
the order you read are the same one; only when the strip stops fitting beside it does it pin
right and let the tabs scroll. It is there whatever your layout is: `0` reaches the whole
catalog, the nine on the bar included, so there is nothing for it to count and no layout that
makes it disappear. The run to the right of it is left free on purpose — a place for a readout
that is not a tab.

### Nine slots, and the tenth tab

`settings:tabs` refuses a tenth tab and says so — `⇧K` a row up across the seam instead, which
trades it onto the bar and the last slot off. A layout saved by an older
build (the bar used to be unbounded) is truncated to its **first nine, in your own order**,
and gori names the folded tabs once on the launch that does it.

One tab can still ride past the ninth slot: an off-bar tab you jumped to with `0` sits at the
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

### Moving inside the menu {#menu-nav}

`↑`/`↓` or `j`/`k` move the selection, `←`/`→` or `h`/`l` change column, and `↵` runs the
highlighted row. No row is ever lettered `h`, `j`, `k` or `l`, at either level, so those four
always move, as they do on every list in the app, and a reflex `j` can never run an action.
gori refuses to start if a row breaks this.

What moved when the rule came in: **Link…** and **Manage links** are `L` on every tab (they were
`k` or `l`), **Add host to scope** is `H` (was `h`), and the Activity feed's **Filter by level**
is `v` in the menu (its bare key is still `l`). The Discover tab's next and previous run and the
Fuzzer's **Add List payload set** moved too, and have since left the menu for the
[palette](#palette-only).

### Finding a tab's action by name {#palette-search}

To find an action by name instead, type it into the palette (`Ctrl-P`). Once you type a query,
the palette searches the actions of the pane you opened it from as well as the app-wide
commands. It uses the same set `Space` would show there, plus the actions that have no menu
letter. The pane's matches come first under `THIS TAB`, then the app commands under `APP`.
Each tab row shows its fast path on the right: its key if it has one, else its menu letter
(`␣ t` means `Space`, then `t`; `␣ > c` is a row inside [Send flow to…](#send-flow-to)). If you have rows marked, the title reads
`COMMANDS · 3 MARKED`, just like the space menu, so you know a batch action acts on all of
them. With the query empty, the palette lists only the app commands, as it always has.

Opened over a History flow detail, the palette searches the detail's actions. `Esc` from the
palette returns you to that detail, and an action you pick runs against the flow on screen.

### Actions only the palette lists {#palette-only}

The space menu is for what you press often; the palette is for the long tail. An action that
only repeats a key you already have, for an editing or navigation convenience, or that you use
about once a session to configure something, has no menu row. Type its name into `Ctrl-P` from
the tab it belongs to and it is listed under `THIS TAB`. Its key, where it has one, works
exactly as before, and Help names the route: the key, or `^P → <name>` for an action with none.

| Tab | Action | Key |
|-----|--------|-----|
| Repeater | Mark word · Edit decoder chain · Pretty-print request | `Ctrl-K` · `Ctrl-Q` · `Ctrl-U` |
| Repeater | Minimize request · Use as refresh for slot… | palette |
| Fuzzer | Mark word · Edit decoder chain · Pretty-print template | `Ctrl-K` · `Ctrl-Q` · `Ctrl-U` |
| Fuzzer | Add List payload set · Save results | `Ctrl-L` · `⇧S` |
| Fuzzer | Run history | palette |
| History | gRPC: reflect schema | palette |
| JWT · Cookie | Toggle decode/encode (decode/forge) · Cycle signing alg (format) | `Ctrl-T` · `Ctrl-A` |
| Comparer | Next change · Previous change | `⇧N` · `⇧P` |
| Decoder | Save chain by name · Load a saved chain · Cycle output mode | `Ctrl-S` · `Ctrl-O` · `Ctrl-X` |
| Issue detail | Edit title/severity · Retest… | `t` · `⇧R` |
| Issue detail | Raise severity · Lower severity | palette (**Set severity** keeps `Space` `s`) |
| Rewriter · Colormarker | Move up · Move down | `⇧K` · `⇧J` |
| Rewriter · Colormarker | Reload rules | palette |
| Discover | Previous run · Next run | palette |
| Sequencer | Export report (JSON)… | palette (**Export report** keeps `Space` `E`) |
| Project | Refresh feed (ACTIVITY) · Change prefix (ENV) | palette |
| Notes | Go to line | palette |

### One menu per tab, whatever has focus

Nine tabs carry a **sub-tab strip** — Repeater, Fuzzer, Miner, Sequencer, Decoder, JWT,
Cookie, Comparer and Notes. The strip's own actions used to be a context section like any
other: they appeared *only* while the strip had focus, so from a body pane you had to walk
focus up a level before `Space` would even offer "close this sub-tab".

They are now their own `SUB-TABS` bucket, and it is in the menu from **every** level of a tab
that has a strip — the body panes, the strip itself and the tab bar. With `⇧1`–`⇧9` dropping
you anywhere, what `Space` offers must not depend on which row the cursor happens to be on.

In a body pane the bucket is **one row**, `T` **Sub-tabs…**, which opens a card with the whole
bucket on the letters below, so it no longer fills half the card: `Space` `T` `w` closes the
sub-tab from the request editor. With the strip or the tab bar focused, the strip *is* the
context, so the bucket is drawn in full at the top level and there is no Sub-tabs… row. The
letters are the same either way: `n` from the strip is `T` `n` from a pane. **Paste cURL**
(`U`, Repeater) also keeps its own row in the panes, and `Ctrl-N` / `Ctrl-W` work everywhere.

### The same nine letters on all nine strips

The bucket is one table to learn, not nine. A tab that does not have an action simply omits
the row; it never spends that letter on something else.

| Key | Action | Direct chord |
|-----|--------|--------------|
| `n` | New sub-tab | `Ctrl-N` |
| `w` | Close sub-tab (or every marked one) | `Ctrl-W` |
| `d` | Duplicate sub-tab | |
| `e` | Rename sub-tab | `r` on the strip |
| `t` | Mark or unmark the active sub-tab | `t` on the strip |
| `f` | Search sub-tabs — the `⌕` picker | `f` on the strip, `⇧0` anywhere |
| `/` | Filter the strip (name / host / method / tag) | |
| `T` | Mark every sub-tab the filter shows | |
| `N` | Clear the sub-tab marks | `Esc` on the strip |
| `g` | Tag sub-tab (Repeater) | |

`Ctrl-N` and `Ctrl-W` are shown beside their rows, and they work from any pane on all nine
tabs — the menu teaches the faster key rather than hiding it. (Miner and Sequencer seed
their sessions from a run, so they have no `n`.)

`T` used to mark every sub-tab from a pane; it is `T` `T` now, so the old reflex lands in the
right card. The menu's `t` is the strip's own `t`, marking the sub-tab you are on, so the
Repeater's Tag moved to `g`, a letter no strip key answers.

The nine letters are **reserved in the COMMON rows** of those tabs, which share the card with
the expanded bucket on the strip, and gori refuses to start if a COMMON row breaks it. A pane's
own rows no longer compete with them, since from a pane the bucket is one level down; only `T`,
the Sub-tabs… row, stays taken there. Earlier, while every pane still drew the whole bucket, pane
actions gave the nine up: Mark word in the Repeater/Fuzzer editors and the JWT and Cookie lens
toggles (now [palette-only](#palette-only) on `Ctrl-K` and `Ctrl-T`), JWT and Cookie's copy
OUTPUT (`C`) and Notes' `$EDITOR` (`o`). They keep those letters for now.

### One intent, one letter

An action that recurs across tabs has the same menu letter on every tab that has it. The
letter comes from one table in the source (`Verb::Lexicon`), not from each row, so two tabs
cannot drift apart on it:

| Key | Action |
|-----|--------|
| `/` | Filter this list |
| `d` | Delete or dismiss the selected row |
| `x` · `v` | Select the line · clear the selection |
| `y` · `Y` · `S` | Copy · Copy as… · Send selection to… |
| `t` · `T` · `N` | Mark · mark all · clear marks (on a rule list, `t` enables/disables) |
| `o` | Open the selected row (the `↵` alias) |
| `a` · `e` | Add · edit; on most tabs `a` also files an issue |
| `r` · `s` | Run, send or reload (the menu echo of `Ctrl-R`) · stop |
| `E` | Export |
| `K` | Clear the workbench input (asks first) |
| `I` | Insert a `§` marker |
| `L` · `H` | Link… (attach to an issue or note, or manage links) · add the host to scope |
| `X` | Wipe the tab (asks first), and nothing else |

`/` `d` `x` `y` `Y` `S` `t` `T` `N` and `X` are **reserved**: on a tab that has the action, no
other row wears the letter. The rest are the action's wherever it exists and free for a tab-local row where it
does not. Rewriter and Colormarker's **Enable/disable everywhere** is `T` for this reason: `X`
wipes.

### Send flow to… {#send-flow-to}

Handing the selected flow to another tool is one row, **`>` Send flow to…**, which opens a
second card. Inside it every tool has the same letter on every tab:

| Key | Sends the flow to |
|-----|-------------------|
| `r` | Repeater |
| `f` | Fuzzer |
| `c` | Comparer |
| `m` | Miner (the Params tab's Mine parameters too) |
| `s` | Sequencer |
| `a` | Authorize |
| `D` | Discover |
| `b` | the browser (Open response in browser) |

So `Space` `>` `c` sends to the Comparer from History, the Sitemap, a Repeater tab or a Fuzzer
result alike. A tab lists only the tools it can send to. The letters match the
**Send selection to…** card (`S`): Sequencer is `s` in both, and Decoder keeps the `d` it
already had there, which is why Discover is `D`.

- **`>` on its own opens the card too**, on every tab that has it: `>` `f` sends to the Fuzzer
  without the `Space`, and a dropped `Space` still lands in the same card. No tab binds `>` to
  anything else.
- **Send to Repeater keeps its own letter too**: `r` on History, the detail, the Sitemap, Probe,
  Evidence and an issue, `R` on the Fuzzer and the Miner, where `r` runs the tab.
- The `>` row is drawn whenever the tab has a send, even when nothing is selected. The card then
  says **nothing here right now**, so `Space` `>` `r` typed quickly never reaches the pane
  underneath.
- `Esc` or `Backspace` goes back one level, and `Esc` again closes. Any other key closes the
  whole menu, as at the first level.
- The title reads `SPACE › SEND FLOW TO`, with `· 3 MARKED` when rows are marked.
- Direct keys are unchanged: `Ctrl-R` / `r` to the Repeater and `⇧I` to the Fuzzer still work.

What moved: on History these were `c` `z` `m` `q` `u` `d` `⇧B`, and **Delete took `d`**, its own
bare key, now that Discover left it. The detail's Delete is `d` too.

### Display… and Protocol… {#display-protocol}

The toggles are two more cards. **`Z` Display…** holds what changes how a pane *draws* what it
holds, and **`P` Protocol…** holds what changes what a Repeater or Fuzzer request *sends*. An
action that rewrites the request itself, such as pretty-print request (`Ctrl-U`), is not a toggle
and stays out of both cards.

| Display… | | Protocol… | |
|-----|---|-----|---|
| `x` | Hex (History detail, both Repeater panes) | `2` | HTTP/2 |
| `p` · `u` · `b` | Pretty · Unicode escapes · whitespace | `s` | SNI override |
| `d` · `e` | Response diff · envelope/decoded | `c` | Auto Content-Length |
| `s` · `f` · `c` | Static assets · follow · Columns… | `w` | Reuse Sec-WebSocket-Key |
| `g` · `q` · `J` | Fold ids · fold queries · JS references | `r` · `f` | gRPC reframe · gRPC field editor |
| `m` · `v` | Fuzzer: matched only · distribution | `t` | TLS fingerprint |
| `t` · `z` | Comparer: requests/responses · fold unchanged | | |
| `a` | Show all: Probe's closed issues, the Params tab's standard headers | | |

Both cards are **sticky**. After a row runs, the card comes back at the same row, so you can
flip two or three settings in one visit, and each row shows its state: `●` on, `○` off, or a
value such as the TLS preset's name. `Esc` closes the card. It does not come back when a row
opened something of its own, such as the SNI field, the gRPC field list, the request hex editor
or the column editor, or when the row moved focus.

- Display… is `Z`, not `V`: under the `vim` keyset `⇧V` selects a line in every pane that has
  these toggles, so a dropped `Space` would select instead of opening the card.
- The Fuzzer's **Cycle sort** stays a direct row (`Space` `o`), because it is the one you press
  most while reading results.
- Direct keys are unchanged: `Ctrl-X` hex (in the Repeater, the pane that has focus: the
  request's hex edit or the response's hex dump, and both rows show it), `p` pretty, `u` Unicode, `b` whitespace, `⇧D` diff,
  `Ctrl-T` envelope, `a` show all, `Ctrl-V` HTTP/2, `Ctrl-S` SNI, `Ctrl-L` auto Content-Length.

What moved: hex was `e` in the History detail, `x` in the Repeater request pane and `h` in its
response pane, and is now `Z` `x` in all three. Probe's **Show closed** and the Params tab's
**All headers** were `Space` `a` and are `Z` `a`, and Mine parameters on Params was `Space` `m` and
is `>` `m`; their bare `a` and `m` still work. Save results on the Fuzzer gave up `P` (it is
`⇧S`, and [palette-only](#palette-only)). The History detail's **Copy flow** row is gone: `Space` `Y` (Copy as…)
on the REQUEST pane has **Raw request**, the same text.

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
- **A rule list's enable/disable** (Colormarker, Probe rules, OAST providers, Rewriter), which is `t` on all four. It turns a rule on and off; it is not a selection, so no keyset moves it.
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

so the card teaches both halves rather than making you guess which one it means. The nine `SUB-TABS` letters (`n` `w` `d` `e` `t` `f` `/` `T` `N`, inside **Sub-tabs…** from a pane) likewise mean the same thing on all nine strips whichever keyset you pick. The two namespaces cannot collide: the menu is modal, and a keyset only ever writes to the keymap.

That includes `/`, which is a `SUB-TABS` letter *and* `vim-ish`'s find key. They are different tiers — the menu letter acts on the strip while the card is up, the chord searches the text pane you are standing in. The one deliberate pane-key overlap is `u` in the Repeater's read-only response: it toggles display-only JSON Unicode decoding. The request editor is still in the Editor scope, where `u` means undo. `validate_chords!` checks same-scope collisions at boot; the cross-scope exception is pinned in `spec/verb/keyset_spec.cr`.

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
- Where the **sub-tab strip** already binds a letter for an action, the menu spells that action with the same letter where it can: `f` lists and searches the sub-tabs and `⇧T` marks the whole strip. Marking a single chip is the strip's own `t`, which has no menu row. Rename is the one it cannot match — the strip binds `r`, and `r` is `Run`/`Send` (the menu echo of `Ctrl-R`) in the Repeater, Fuzzer, Miner and Sequencer, where a rename does not get to displace it. One action must not have two spellings across the nine strips, so rename is **`e` on all of them** and the strip's `r` stays a raw chord. See [the space menu](#space-menu) for the whole table.
- The editor actions are rebindable individually, and as a set via [Editor keysets](#editor-keysets). What the rebind editor will not move is the handful whose chord a hardcoded guard answers first: `Esc` (back to READ), `Ctrl-Z`, `Ctrl-F` and `Ctrl-G`. They are listed in the Help sheet so you can read them, and a keyset can give them a second, bare spelling — which is how `vim-ish` reaches `u` and `/`.
- Press **`?`** from a navigable context to jump to the **Help** tab (mitmproxy-style cheat-sheet).

## Next Steps

- [Settings](/guide/settings/): the Preferences modal and every section in it
- [Themes](/guide/themes/): switch or create colour themes the same way
- [Configuration Reference](/reference/config/): the `hotkeys` key in `settings.json`
