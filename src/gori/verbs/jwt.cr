require "../verb"

module Gori
  module Verbs
    # The JWT tab's space-menu / palette actions. The body captures every printable key
    # (the token text, JSON claims, the secret), so these single-letter mnemonics never
    # collide — they fire only from the space menu (reachable from the sub-tab strip) and
    # the command palette. Mnemonics are unique within COMMON ∪ any one section.
    def self.register_jwt(r : Verb::Registry) : Nil
      in_jwt = ->(ctx : Verb::ExecContext) { ctx.current_tab == :jwt }

      # Session management + the two lens toggles are COMMON (reachable from every pane).
      r.register Verb::Definition.new(
        "jwt.new", "New session", "Open a fresh blank JWT session sub-tab",
        Verb::Scope::Jwt, available: in_jwt, mnemonic: 'n') { |ctx| ctx.jwt_new; nil }
      r.register Verb::Definition.new(
        "jwt.close", "Close session", "Close the active JWT session (keeps at least one)",
        Verb::Scope::Jwt, available: in_jwt, mnemonic: 'w') { |ctx| ctx.jwt_close; nil }
      r.register Verb::Definition.new(
        "jwt.toggle-mode", "Toggle decode/encode", "Flip between the DECODE and ENCODE lenses",
        Verb::Scope::Jwt, available: in_jwt, mnemonic: 'e') { |ctx| ctx.jwt_toggle_mode; nil }
      r.register Verb::Definition.new(
        "jwt.cycle-alg", "Cycle signing alg", "Cycle the signing algorithm: HS256 / HS384 / HS512 / none",
        Verb::Scope::Jwt, available: in_jwt, mnemonic: 'a') { |ctx| ctx.jwt_cycle_alg; nil }
      r.register Verb::Definition.new(
        "jwt.load-decoded", "Load decoded claims", "Seed the ENCODE editors from the INPUT token's header + payload",
        Verb::Scope::Jwt, available: in_jwt, mnemonic: 'l') { |ctx| ctx.jwt_load_decoded; nil }
      r.register Verb::Definition.new(
        "jwt.clear", "Clear session", "Clear the token, editors, and secret of the active session",
        Verb::Scope::Jwt, available: in_jwt, mnemonic: 'k') { |ctx| ctx.jwt_clear; nil }

      # The single smart Copy (selection if any, else the focused pane) — chord 'y'.
      in_jwt_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :jwt && ctx.jwt_read_mode? }
      r.register Verb::Definition.new(
        "jwt.copy", "Copy", "Copy the selection, or the whole focused pane if nothing is selected",
        Verb::Scope::Jwt, [Verb::Chord.new("y")],
        available: in_jwt_read, mnemonic: 'y') { |ctx| ctx.jwt_copy; nil }

      # Copy the re-signed OUTPUT token — tagged :output (the ENCODE result pane).
      r.register Verb::Definition.new(
        "jwt.copy-token", "Copy re-signed token", "Copy the OUTPUT token to the clipboard",
        Verb::Scope::Jwt, available: in_jwt, mnemonic: 't', section: :output) { |ctx| ctx.jwt_copy_token; nil }

      # Copy the selected ATTACK payload — tagged :attacks (the payload list pane).
      r.register Verb::Definition.new(
        "jwt.copy-attack", "Copy attack token", "Copy the selected testing payload to the clipboard",
        Verb::Scope::Jwt, available: in_jwt, mnemonic: 'c', section: :attacks) { |ctx| ctx.jwt_copy_attack; nil }

      # Sub-tab chip rename + content clone — tagged :subtab (mirrors Decoder).
      r.register Verb::Definition.new(
        "jwt.rename-subtab", "Rename subtab", "Rename the active session's sub-tab chip",
        Verb::Scope::Jwt, available: in_jwt, mnemonic: 'r', section: :subtab) { |ctx| ctx.jwt_rename_subtab; nil }
      r.register Verb::Definition.new(
        "jwt.duplicate-subtab", "Duplicate subtab", "Open a new session with the same token + claims",
        Verb::Scope::Jwt, available: in_jwt, mnemonic: 'd', section: :subtab) { |ctx| ctx.jwt_duplicate_subtab; nil }

      # Search + filter across sessions — tagged :tab (like decoder.find-subtab), so
      # jumping never needs Ctrl+digit. Gated on ≥2 open sessions.
      has_many = ->(ctx : Verb::ExecContext) { ctx.current_tab == :jwt && ctx.subtab_search_count >= 2 }
      r.register Verb::Definition.new(
        "jwt.find-subtab", "Search sub-tabs", "Filter the open JWT sessions and jump to one",
        Verb::Scope::Jwt, available: has_many, mnemonic: 'f', section: :tab) { |ctx| ctx.subtab_search_open; nil }
      r.register Verb::Definition.new(
        "jwt.filter-subtabs", "Filter sub-tabs", "Filter the JWT sub-tab strip by name / token",
        Verb::Scope::Jwt, available: has_many, mnemonic: '/', section: :tab) { |ctx| ctx.subtab_filter_open; nil }
    end
  end
end
