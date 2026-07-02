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

      r.register Verb::Definition.new(
        "notes.copy", "Copy note", "Copy the entire current note to the clipboard",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'y') { |ctx| ctx.notes_copy; nil }

      r.register Verb::Definition.new(
        "notes.clear", "Clear note", "Clear the current note's text",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'l') { |ctx| ctx.notes_clear; nil }

      r.register Verb::Definition.new(
        "notes.edit", "Edit in $EDITOR", "Open the current note in the external editor",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'e') { |ctx| ctx.notes_edit; nil }

      r.register Verb::Definition.new(
        "notes.goto", "Go to line", "Jump the cursor to a line number",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'g') { |ctx| ctx.notes_goto; nil }

      r.register Verb::Definition.new(
        "notes.find", "Find in note", "Search for text in the current note",
        Verb::Scope::Notes, available: in_notes, mnemonic: 'f') { |ctx| ctx.notes_find; nil }
    end
  end
end