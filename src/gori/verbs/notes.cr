require "../verb"

module Gori
  module Verbs
    # The Notes tab's space-menu / palette actions. The body captures every
    # printable key (literal text), so these single-letter mnemonics never collide —
    # they fire only from the bottom-right space menu (reachable from the sub-tab
    # strip) and the command palette. Mnemonics are unique within the Notes scope.
    def self.register_notes(r : Verb::Registry) : Nil
      in_notes = ->(ctx : Verb::ExecContext) { ctx.current_tab == :notes }

      r.register Verb::Definition.new(
        "notes.new", "New note", "Open a fresh blank note sub-tab",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'n') { |ctx| ctx.notes_new; nil }

      r.register Verb::Definition.new(
        "notes.close", "Close note", "Close the active note sub-tab (keeps at least one)",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'w') { |ctx| ctx.notes_close; nil }

      # Content-only clone (new note id; entity_links are not copied). Tagged :subtab so
      # it fronts the strip's Space menu; 'd' is free in COMMON ∪ :subtab.
      r.register Verb::Definition.new(
        "notes.duplicate-subtab", "Duplicate subtab", "Open a new note sub-tab with the same text",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'd', section: :subtab) { |ctx| ctx.notes_duplicate_subtab; nil }

      # Search-and-jump across note sub-tabs (section :tab, tab-bar space menu — like
      # repeater.find-subtab). A jump path that doesn't need Ctrl+digit. 's' is free in
      # Notes COMMON ∪ :tab.
      r.register Verb::Definition.new(
        "notes.find-subtab", "Search sub-tabs", "Filter the open notes and jump to one",
        Verb::Scope::Notes,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :notes && ctx.subtab_search_count >= 2 },
        mnemonic: 's', section: :tab) { |ctx| ctx.subtab_search_open; nil }

      # Inline `/` filter bar over the note sub-tab strip (issue #121) — narrows chips by
      # name / free-text over the body. '/' is the shared filter idiom (unique in :tab).
      r.register Verb::Definition.new(
        "notes.filter-subtabs", "Filter sub-tabs", "Filter the note sub-tab strip by name / text",
        Verb::Scope::Notes,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :notes && ctx.subtab_search_count >= 2 },
        mnemonic: '/', section: :tab) { |ctx| ctx.subtab_filter_open; nil }

      # The single smart Copy (see repeater.copy in verbs/history.cr) — copy-all is gone.
      # `y` in READ, `^Y` in INS — one verb. See repeater.copy in verbs/history.cr for why
      # Copy is available while typing at all (an INS selection had no way to be copied).
      in_notes_copy = ->(ctx : Verb::ExecContext) do
        ctx.current_tab == :notes && (ctx.notes_read_mode? || ctx.editor_focused?)
      end
      r.register Verb::Definition.new(
        "notes.copy", "Copy", "Copy the selected text, or the whole current note if nothing is selected, to the clipboard",
        Verb::Scope::Notes, [Verb::Chord.new("y"), Verb::Chord.new("y", ctrl: true)],
        available: in_notes_copy, mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      r.register Verb::Definition.new(
        "notes.clear", "Clear note", "Clear the current note's text",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'c') { |ctx| ctx.notes_clear; nil }

      # Export the note as Markdown. Mnemonic 'E', not 'e' or 'x': 'e' is Edit-in-$EDITOR
      # and 'x' is read_edit.cr's Select line, both already in this scope. A capital follows
      # the precedent 'S' (Send selection to) sets right next to it. No chord either — the
      # NO chord, unlike `issues.export-key` / `sequence.export` which both bind ⇧E — and that
      # is not drift. Those two surfaces are LISTS; this one is a full-text editor, so ⇧E is
      # the printable character `E` and would be typed into the note rather than exporting it.
      # The space menu and the palette are the only ways in, by construction.
      r.register Verb::Definition.new(
        "notes.export", "Export note…", "Write the current note's text to a Markdown file",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'E') { |ctx| ctx.notes_export; nil }

      r.register Verb::Definition.new(
        "notes.edit", "Edit in $EDITOR", "Open the current note in the external editor",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'e') { |ctx| ctx.notes_edit; nil }

      r.register Verb::Definition.new(
        "notes.goto", "Go to line", "Jump the cursor to a line number",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'g') { |ctx| ctx.notes_goto; nil }

      r.register Verb::Definition.new(
        "notes.find", "Find in note", "Search for text in the current note",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'f') { |ctx| ctx.notes_find; nil }

      r.register Verb::Definition.new(
        "notes.links", "Manage links", "View/add/remove related History/Repeater/Fuzzer/Miner URLs",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'l') { |ctx| ctx.notes_links; nil }
    end
  end
end
