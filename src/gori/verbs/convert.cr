require "../verb"

module Gori
  module Verbs
    # The Convert tab's space-menu / palette actions. The body itself captures every
    # printable key (literal text), so these single-letter mnemonics never collide —
    # they fire only from the bottom-right space menu (reachable from the sub-tab
    # strip) and the command palette. Mnemonics are unique within the Convert scope.
    def self.register_convert(r : Verb::Registry) : Nil
      in_convert = ->(ctx : Verb::ExecContext) { ctx.current_tab == :convert }

      r.register Verb::Definition.new(
        "convert.new", "New conversion", "Open a fresh blank conversion sub-tab",
        Verb::Scope::Convert, available: in_convert, mnemonic: 'n') { |ctx| ctx.convert_new; nil }

      r.register Verb::Definition.new(
        "convert.close", "Close conversion", "Close the active conversion sub-tab (keeps at least one)",
        Verb::Scope::Convert, available: in_convert, mnemonic: 'w') { |ctx| ctx.convert_close; nil }

      r.register Verb::Definition.new(
        "convert.clear", "Clear input + chain", "Clear the current input and chain spec",
        Verb::Scope::Convert, available: in_convert, mnemonic: 'l') { |ctx| ctx.convert_clear; nil }

      in_convert_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :convert && ctx.convert_read_mode? }
      r.register Verb::Definition.new(
        "convert.copy", "Copy selection", "Copy the selected text (or current line) from INPUT/OUTPUT",
        Verb::Scope::Convert, [Verb::Chord.new("y")],
        available: in_convert_read, mnemonic: 'y') { |ctx| ctx.convert_copy_selection; nil }

      r.register Verb::Definition.new(
        "convert.copy-all", "Copy output", "Copy the entire current output to the clipboard",
        Verb::Scope::Convert, available: in_convert, mnemonic: 'O') { |ctx| ctx.convert_copy; nil }

      r.register Verb::Definition.new(
        "convert.mode", "Cycle output mode", "Cycle the output display: text / hex / base64",
        Verb::Scope::Convert, available: in_convert, mnemonic: 'm') { |ctx| ctx.convert_cycle_mode; nil }

      r.register Verb::Definition.new(
        "convert.save", "Save chain by name", "Save the current chain spec under a name",
        Verb::Scope::Convert, available: in_convert, mnemonic: 's') { |ctx| ctx.convert_save; nil }

      r.register Verb::Definition.new(
        "convert.load", "Load a saved chain", "Load a previously saved chain spec by name",
        Verb::Scope::Convert, available: in_convert, mnemonic: 'o') { |ctx| ctx.convert_load; nil }
    end
  end
end
