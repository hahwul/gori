require "../verb"

module Gori
  module Verbs
    # `Verb::Scope::Editor` — the keys a TEXT EDITOR pane owns, wherever it is.
    #
    # These nine verbs used to be nine controllers' worth of hand-rolled arms
    # (`when c == 'i' then view.enter_request_insert!` × 11 panes — KEY_AUDIT §1.4/§2e).
    # They were hand-rolled because `Keymap#lookup` is keyed by `Scope` alone: the Repeater
    # binds one scope across a request EDITOR and a read-only RESPONSE, so "↵ enters INSERT
    # here, ↵ sends there" was not a thing two chords could say. `Scope::Editor` is that
    # missing focus dimension — `Runner#scope_chain` puts it AHEAD of the tab's own scope
    # while an editor pane holds focus, and drops it the moment focus leaves. So `↵` resolves
    # to `editor.insert` in the request pane and falls through to `repeater.send` in the
    # response pane, with no controller arm in either.
    #
    # Being a real scope is what makes them REBINDABLE and what lets a KEYSET
    # (`Verb::Keyset`) respell them as a bundle: a vim-shaped operator moves `x`→`V`,
    # `^Z`→`u`, `^F`→`/` by picking a keyset, not by rebinding eleven panes one at a time.
    #
    # What is deliberately NOT here:
    #   • COPY and SELECT LINE. Both are already per-tab verbs (`repeater.copy`,
    #     `notes.select-line`, … in read_edit.cr) whose bare `y`/`x` were only ever DEAD
    #     because a controller arm shadowed them. Deleting the arms makes the existing verbs
    #     live; moving them into Editor as well would put two verbs on one letter with the
    #     Editor one always winning, which is the shadowing this file exists to end.
    #   • Anything that EDITS. There is no delete-line / open-line / join here, because there
    #     is no delete-line / open-line / join in gori's editors to bind — a READ-mode pane is
    #     a `ReadPane` (a caret, a selection and a copy), not a modal text editor. A keyset
    #     names keys for operations that exist; it does not grow new ones.
    def self.register_editor(r : Verb::Registry) : Nil
      # READ mode is the only place a BARE letter can reach the keymap at all: in INS every
      # editor ladder claims printables upstream of dispatch (that is what INS is). So the
      # bare-key verbs gate on it, and the modified ones (`^Z`/`^F`/`^G`) gate on the pane.
      in_editor = ->(ctx : Verb::ExecContext) { ctx.editor_pane? }
      in_read = ->(ctx : Verb::ExecContext) { ctx.editor_read_mode? }
      in_insert = ->(ctx : Verb::ExecContext) { ctx.editor_pane? && !ctx.editor_read_mode? }

      r.register Verb::Definition.new(
        "editor.insert", "Insert", "Start typing at the caret (INSERT mode)",
        Verb::Scope::Editor, [Verb::Chord.new("i")],
        available: in_read, mnemonic: 'i') { |ctx| ctx.editor_enter_insert; nil }
      # `↵` as a SEPARATE hidden verb rather than a second chord on `editor.insert`: a verb
      # carrying two chords is not rebindable (`Hotkeys.rebindable?` — the extra chord is
      # assumed to be a structural nav alias it must not let a single-chord rebind collapse),
      # and `↵` here IS exactly such an alias. Splitting it keeps the `i` row in the hotkey
      # editor and keeps `↵` where every pane has always had it. Same shape as `body.open`'s
      # enter/right/l family.
      r.register Verb::Definition.new(
        "editor.insert-enter", "Insert (↵)", "Start typing at the caret (INSERT mode)",
        Verb::Scope::Editor, [Verb::Chord.new("enter")],
        hidden: true, available: in_read) { |ctx| ctx.editor_enter_insert; nil }
      # Keyless by default: helix-shaped editing has no separate append, and gori's READ mode
      # is a caret with no operator-pending grammar to hang one off. The `vim` keyset gives it
      # `a`, which is the whole reason it is registered — one column right, then INSERT, both
      # motions the editors already have.
      r.register Verb::Definition.new(
        "editor.append", "Append", "Start typing one column to the right of the caret (INSERT mode)",
        Verb::Scope::Editor,
        available: in_read, mnemonic: 'a') { |ctx| ctx.editor_append_insert; nil }
      # Registered for the Help sheet and the space menu, NOT for dispatch — every INS ladder
      # answers `escape` itself, upstream of the keymap, so this chord can never fire. It is in
      # `Hotkeys::FIXED_IDS` for that reason, exactly like `view.reveal-ws`'s guard-claimed ^B.
      # The alternative was leaving the one key that gets you OUT of an editor undocumented in
      # the registry, which is where Help and the palette read from.
      r.register Verb::Definition.new(
        "editor.exit-insert", "Back to READ", "Leave INSERT mode; the bare letters become commands again",
        Verb::Scope::Editor, [Verb::Chord.new("escape")],
        available: in_insert, mnemonic: 'e') { |ctx| ctx.editor_exit_insert; nil }
      # `^Z` reaches the keymap in READ only: the nine INS ladders claim it (Hotkeys'
      # CLAIMED_CTRL_LETTERS carries `z` for exactly that), so INS undo is theirs and always
      # will be. What this buys is undo from READ, where nothing offered it, and a row a keyset
      # can respell — the `vim` keyset puts it on `u`.
      r.register Verb::Definition.new(
        "editor.undo", "Undo", "Undo the last edit in this pane",
        Verb::Scope::Editor, [Verb::Chord.new("z", ctrl: true)],
        available: in_read, mnemonic: 'u') { |ctx| ctx.editor_undo; nil }
      # Keyless by default. gori's READ panes have no bare top/bottom key today — Home/End are
      # LINE edges and ⌃Home/⌃End are the buffer ones — so `helix` adds nothing here; `vim`
      # spells them `g` and `⇧G`. `gg` is not expressible (see the keyset table), so `g` alone
      # is the top.
      r.register Verb::Definition.new(
        "editor.top", "Top of pane", "Move the caret to the first line",
        Verb::Scope::Editor,
        available: in_read, mnemonic: 'g') { |ctx| ctx.editor_to_top; nil }
      r.register Verb::Definition.new(
        "editor.bottom", "Bottom of pane", "Move the caret to the last line",
        Verb::Scope::Editor,
        available: in_read, mnemonic: 'G') { |ctx| ctx.editor_to_bottom; nil }
      # ^G / ^F: the shell's two bottom prompts. Their Ctrl form is answered by a hardcoded
      # guard in `Runner#handle_key` before the keymap is read — that is not changing, and it
      # is why these gate on the whole PANE rather than on READ (a find from inside INS is the
      # normal case). Registering them anyway gives the keyset somewhere to hang a second,
      # BARE spelling: `vim` puts find on `/`, which reaches the keymap because nothing claims
      # it in an editor pane. A user rebind works the same way and is additive in the same way
      # — the Ctrl form keeps answering whatever else is bound.
      r.register Verb::Definition.new(
        "editor.goto-line", "Go to line", "Jump the caret to a line number",
        Verb::Scope::Editor, [Verb::Chord.new("g", ctrl: true)],
        available: in_editor, mnemonic: 'l') { |ctx| ctx.editor_goto_line; nil }
      r.register Verb::Definition.new(
        "editor.find", "Find in pane", "Search this pane's text",
        Verb::Scope::Editor, [Verb::Chord.new("f", ctrl: true)],
        available: in_editor, mnemonic: 'f') { |ctx| ctx.editor_find; nil }

      # `Scope::Repeater`, not Editor — but registered HERE because it is the other half of
      # the split above, and it only became expressible as a chord when the split landed.
      #
      # `↵` on the RESPONSE pane re-sends: the reflex of "I am looking at the answer, give me
      # another one". It was a controller arm (`repeater_controller.cr`'s
      # `handle_repeater_response`) for as long as the keymap had no focus dimension — the
      # REQUEST pane one row up reads the same `↵` as "start typing", and one Scope::Repeater
      # could not hold both meanings. It can now: the request pane puts Editor at the head of
      # the chain (`editor.insert-enter` above) and the read-only response does not, so the
      # gate here is simply "a Repeater READ pane that is not an editor".
      #
      # Hidden + separate from `repeater.send` rather than a second chord on it, for the reason
      # `editor.insert-enter` is separate from `editor.insert`: two chords on one verb is the
      # shape `Hotkeys.rebindable?` reads as a structural nav alias and refuses to rebind, and
      # ^R Send is very much worth keeping rebindable.
      in_repeater_response = ->(ctx : Verb::ExecContext) do
        ctx.current_tab == :repeater && ctx.repeater_read_mode? && !ctx.editor_pane?
      end
      r.register Verb::Definition.new(
        "repeater.send-enter", "Send repeater (↵)", "Resend the request byte-exact and diff the response",
        Verb::Scope::Repeater, [Verb::Chord.new("enter")],
        hidden: true, available: in_repeater_response) { |ctx| ctx.repeater_send; nil }
    end
  end
end
