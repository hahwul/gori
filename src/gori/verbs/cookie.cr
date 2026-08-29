require "../verb"

module Gori
  module Verbs
    # The Cookie tab's space-menu / palette actions. The body captures every printable key
    # (the cookie text, the payload JSON, the secret, the salt), so these single-letter
    # mnemonics never collide — they fire only from the space menu (reachable from the sub-tab
    # strip) and the command palette. Mnemonics are unique within COMMON ∪ any one section.
    # Modelled on register_jwt.
    def self.register_cookie(r : Verb::Registry) : Nil
      in_cookie = ->(ctx : Verb::ExecContext) { ctx.current_tab == :cookie }

      # Session management + the lens/format toggles are COMMON (reachable from every pane).
      r.register Verb::Definition.new(
        "cookie.new", "New session", "Open a fresh blank Cookie session sub-tab",
        Verb::Scope::Cookie, available: in_cookie, mnemonic: 'n') { |ctx| ctx.cookie_new; nil }
      r.register Verb::Definition.new(
        "cookie.close", "Close session", "Close the active Cookie session (keeps at least one)",
        Verb::Scope::Cookie, available: in_cookie, mnemonic: 'w') { |ctx| ctx.cookie_close; nil }
      r.register Verb::Definition.new(
        "cookie.toggle-mode", "Toggle decode/forge", "Flip between the DECODE and FORGE lenses",
        Verb::Scope::Cookie, [Verb::Chord.new("t", ctrl: true)],
        available: in_cookie, mnemonic: 'e') { |ctx| ctx.cookie_toggle_mode; nil }
      r.register Verb::Definition.new(
        "cookie.cycle-format", "Cycle format", "Cycle the cookie format: auto / flask / rack / django",
        Verb::Scope::Cookie, [Verb::Chord.new("a", ctrl: true)],
        available: in_cookie, mnemonic: 'a') { |ctx| ctx.cookie_cycle_format; nil }
      r.register Verb::Definition.new(
        "cookie.cycle-algorithm", "Cycle Django algorithm", "Cycle the Django HMAC algorithm: sha256 / sha1",
        Verb::Scope::Cookie, available: in_cookie, mnemonic: 'g') { |ctx| ctx.cookie_cycle_algorithm; nil }
      r.register Verb::Definition.new(
        "cookie.cycle-salt", "Toggle Django salt", "Flip the Django salt between the session-backend salt and the generic signing salt",
        Verb::Scope::Cookie, available: in_cookie, mnemonic: 's') { |ctx| ctx.cookie_cycle_salt; nil }
      r.register Verb::Definition.new(
        "cookie.load-decoded", "Load decoded payload", "Seed the FORGE payload editor from the INPUT cookie's parts",
        Verb::Scope::Cookie, available: in_cookie, mnemonic: 'l') { |ctx| ctx.cookie_load_decoded; nil }
      r.register Verb::Definition.new(
        "cookie.clear", "Clear session", "Clear the cookie, payload, secret, and salt of the active session",
        Verb::Scope::Cookie, [Verb::Chord.new("l", ctrl: true)],
        available: in_cookie, mnemonic: 'k') { |ctx| ctx.cookie_clear; nil }

      # Crack: reachable as `c` from a READ pane (INPUT-read / DECODED), where a bare letter
      # falls through to the keymap; in the editable panes `c` is a literal character. Also in
      # the space menu + palette for the panes that capture it.
      in_cookie_read = ->(ctx : Verb::ExecContext) { ctx.current_tab == :cookie && ctx.cookie_read_mode? }
      r.register Verb::Definition.new(
        "cookie.crack", "Crack secret", "Brute-force the signing secret over the SECRET field (a wordlist path or comma list)",
        Verb::Scope::Cookie, [Verb::Chord.new("c")],
        available: in_cookie_read, mnemonic: 'c') { |ctx| ctx.cookie_crack; nil }

      # The single smart Copy (selection if any, else the focused pane) — chord 'y' / '^Y'.
      in_cookie_copy = ->(ctx : Verb::ExecContext) do
        ctx.current_tab == :cookie && (ctx.cookie_read_mode? || ctx.editor_focused?)
      end
      r.register Verb::Definition.new(
        "cookie.copy", "Copy", "Copy the selection, or the whole focused pane if nothing is selected",
        Verb::Scope::Cookie, [Verb::Chord.new("y"), Verb::Chord.new("y", ctrl: true)],
        available: in_cookie_copy, mnemonic: 'y') { |ctx| ctx.cookie_copy; nil }

      # Copy the forged OUTPUT cookie — tagged :output (the FORGE result pane).
      r.register Verb::Definition.new(
        "cookie.copy-cookie", "Copy forged cookie", "Copy the OUTPUT cookie to the clipboard",
        Verb::Scope::Cookie, available: in_cookie, mnemonic: 't', section: :output) { |ctx| ctx.cookie_copy_output; nil }

      # Sub-tab chip rename + content clone — tagged :subtab (mirrors JWT/Decoder).
      r.register Verb::Definition.new(
        "cookie.rename-subtab", "Rename subtab", "Rename the active session's sub-tab chip",
        Verb::Scope::Cookie, available: in_cookie, mnemonic: 'r', section: :subtab) { |ctx| ctx.cookie_rename_subtab; nil }
      r.register Verb::Definition.new(
        "cookie.duplicate-subtab", "Duplicate subtab", "Open a new session with the same cookie + payload",
        Verb::Scope::Cookie, available: in_cookie, mnemonic: 'd', section: :subtab) { |ctx| ctx.cookie_duplicate_subtab; nil }

      # Search + filter across sessions — tagged :tab (like jwt.find-subtab), so jumping never
      # needs Ctrl+digit. The two thresholds differ and must not share a lambda (see the JWT note).
      has_any = ->(ctx : Verb::ExecContext) { ctx.current_tab == :cookie && ctx.subtab_search_count >= 1 }
      has_many = ->(ctx : Verb::ExecContext) { ctx.current_tab == :cookie && ctx.subtab_search_count >= 2 }
      r.register Verb::Definition.new(
        "cookie.find-subtab", "Search sub-tabs", "Filter the open Cookie sessions and jump to one",
        Verb::Scope::Cookie, available: has_any, mnemonic: 'f', section: :tab) { |ctx| ctx.subtab_search_open; nil }
      r.register Verb::Definition.new(
        "cookie.filter-subtabs", "Filter sub-tabs", "Filter the Cookie sub-tab strip by name / cookie",
        Verb::Scope::Cookie, available: has_many, mnemonic: '/', section: :tab) { |ctx| ctx.subtab_filter_open; nil }

      # Read-pane selection verbs (INPUT-read, DECODED, OUTPUT). Tagged :input for select-line
      # (the cookie pane is the one with a fine selection); send-to stays COMMON.
      r.register Verb::Definition.new(
        "cookie.select-line", "Select line", "Select the entire current line",
        Verb::Scope::Cookie, [Verb::Chord.new("x")],
        available: in_cookie_read, mnemonic: 'x', section: :input) { |ctx| ctx.read_select_line; nil }
      in_sel = ->(ctx : Verb::ExecContext) { ctx.current_tab == :cookie && ctx.read_selection_active? }
      r.register Verb::Definition.new(
        "cookie.clear-selection", "Clear selection", "Clear the text selection",
        Verb::Scope::Cookie, available: in_sel, mnemonic: 'v', section: :input) { |ctx| ctx.read_clear_selection; nil }
      r.register Verb::Definition.new(
        "cookie.send-to", "Send selection to…", "Send the selected text to another tool (Decoder, JWT, …)",
        Verb::Scope::Cookie, available: in_sel, mnemonic: 'S') { |ctx| ctx.send_to_open; nil }
    end
  end
end
