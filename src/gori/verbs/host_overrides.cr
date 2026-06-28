require "../verb"

module Gori
  module Verbs
    # The Project tab's HOST OVERRIDES pane actions — a DISTINCT scope from the SCOPE
    # rule list right above it, so a/e/d and the space menu act on the override list,
    # never the scope rules. Mirrors the scope.*-rule block: the pane is navigable (not
    # a text editor), so the a/e/d direct chords double as the space-menu mnemonics
    # (menu_key derives from the plain chord). edit/delete are gated on an entry existing.
    def self.register_host_overrides(r : Verb::Registry) : Nil
      have_entry = ->(ctx : Verb::ExecContext) { ctx.hostov_entry_selected? }

      r.register Verb::Definition.new(
        "hostoverride.add-entry", "Add host override", "Open the inline row to add an IP→host override",
        Verb::Scope::HostOverrides, [Verb::Chord.new("a")]) { |ctx| ctx.hostov_add_entry; nil }

      r.register Verb::Definition.new(
        "hostoverride.edit-entry", "Edit host override", "Edit the selected host override in place",
        Verb::Scope::HostOverrides, [Verb::Chord.new("e")], available: have_entry) { |ctx| ctx.hostov_edit_entry; nil }

      r.register Verb::Definition.new(
        "hostoverride.delete-entry", "Delete host override", "Remove the selected host override",
        Verb::Scope::HostOverrides, [Verb::Chord.new("d")], available: have_entry) { |ctx| ctx.hostov_delete_entry; nil }
    end
  end
end
