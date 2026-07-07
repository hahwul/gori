require "../verb"

module Gori
  module Verbs
    # The Project tab's ENVIRONMENT pane actions — a DISTINCT scope from the SCOPE
    # rule list + HOST OVERRIDES panes stacked above it, so a/e/d and the space menu
    # act on the env-var list, never those. Mirrors the hostoverride.* block: the pane
    # is navigable (not a text editor), so the a/e/d direct chords double as the space-
    # menu mnemonics (menu_key derives from the plain chord); edit/delete are gated on a
    # var existing. The prefix sigil is a GLOBAL setting (not per-project), so it has no
    # direct chord — change-prefix is reachable ONLY via the space menu (mnemonic 'p'),
    # keeping it out of the way of everyday add/edit and clear that it's app-wide.
    def self.register_env(r : Verb::Registry) : Nil
      have_var = ->(ctx : Verb::ExecContext) { ctx.env_var_selected? }

      r.register Verb::Definition.new(
        "env.add-var", "Add env var", "Open the inline row to add a $KEY environment variable",
        Verb::Scope::Env, [Verb::Chord.new("a")]) { |ctx| ctx.env_add_var; nil }

      r.register Verb::Definition.new(
        "env.edit-var", "Edit env var", "Edit the selected environment variable in place",
        Verb::Scope::Env, [Verb::Chord.new("e")], available: have_var) { |ctx| ctx.env_edit_var; nil }

      r.register Verb::Definition.new(
        "env.delete-var", "Delete env var", "Remove the selected environment variable",
        Verb::Scope::Env, [Verb::Chord.new("d")], available: have_var) { |ctx| ctx.env_delete_var; nil }

      r.register Verb::Definition.new(
        "env.edit-prefix", "Change prefix", "Edit the token prefix used for $KEY substitution (applies globally)",
        Verb::Scope::Env, mnemonic: 'p') { |ctx| ctx.env_edit_prefix; nil }
    end
  end
end
