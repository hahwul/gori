require "./workbench_controller"
require "../subtab_clone"
require "../jwt_view"
require "../../jwt"
require "../../decoder/codecs"

module Gori::Tui
  # One JWT workbench session (a sub-tab). On top of the shared DECODE side and ENCODE
  # PAYLOAD + SECRET (`WorkbenchSession`), the ENCODE lens adds a HEADER editor and the alg,
  # and the decode caches the generated ATTACKS. Mutable class.
  class JwtSession < WorkbenchSession(JwtView)
    property header : TextArea = TextArea.new("")
    # Cached beside `attacks` (which is empty for a JWE) so the ATTACKS empty-state can say
    # WHY without the view parsing the token on every frame — the pane is empty for the whole
    # time an operator is typing one in, which is exactly when a per-frame parse costs most.
    property? input_jwe : Bool = false
    property alg : String = "HS256"
    property attacks : Array(Jwt::Attack) = [] of Jwt::Attack
  end

  # The JWT tab: a hidden workbench for decoding, editing/re-signing, and generating
  # testing payloads (alg:none, weak-secret re-sign, header injection) from a token. The
  # shell is `WorkbenchController`'s, shared with the Cookie tab (^N new · ^W close · ^T
  # lens); `^A` cycles the alg.
  class JwtController < WorkbenchController(JwtSession)
    DECODE_PANES = [:input, :decoded, :attacks]
    ENCODE_PANES = [:header, :payload, :secret, :output]

    # Whether the last `set_alg` dropped the key field, so the status line can say so — a
    # silent clear would be its own surprise.
    @alg_cleared_key = false

    def tab : Symbol
      :jwt
    end

    def command_scope : Verb::Scope
      Verb::Scope::Jwt
    end

    private def make_session(input_text : String, name : String?) : JwtSession
      s = JwtSession.new(input_text, name)
      s.view.set_registry(@host.session.registry)
      recompute_decode(s)
      recompute_output(s)
      s
    end

    private def tool_label : String
      "JWT"
    end

    private def item_noun : String
      "token"
    end

    private def lens_verb : String
      "jwt.toggle-mode"
    end

    # The ⌕ picker searches the DECODED claims, not the opaque token the summary carries:
    # an operator remembers a token by something inside it (`admin`, an `iss`, a `kid`),
    # never by its base64. `decoded` holds that text in decode mode; header/payload hold it
    # in encode mode (the operator is drafting the claims) — both, so either direction is
    # findable by what it says.
    def subtab_search_extras : Array(String)
      @sessions.map { |s| search_extra("#{s.decoded} #{s.header.text} #{s.payload.text}") }
    end

    # The chip label's fallback: the token's alg (or "empty").
    private def session_summary(s : JwtSession) : String
      return "empty" if s.input.text.strip.empty?
      (a = Jwt.token_alg(s.input.text)) ? "jwt #{a}" : "jwt"
    end

    private def duplicate_at(idx : Int32) : Nil
      return unless src = @sessions[idx]?
      dup = make_session(src.input.text, SubtabClone.copy_name(src.view.name))
      dup.header.set_text(src.header.text)
      dup.payload.set_text(src.payload.text)
      dup.secret = src.secret
      dup.alg = src.alg
      recompute_output(dup)
      @sessions << dup
      @idx = @sessions.size - 1
    end

    # --- render ---
    # The shared shell (see `WorkbenchController#render_shell` for why it is not inherited).
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      render_shell(screen, rect, focus)
    end

    private def render_lens(screen : Screen, body : Rect, s : JwtSession, focused : Bool) : Nil
      if s.mode == :decode
        s.view.render_decode(screen, body,
          input: s.input, input_mode: s.input_mode, input_read: s.input_read,
          decoded: s.decoded, attacks: s.attacks, input_jwe: s.input_jwe?,
          pane: s.pane, focused: focused, lens_chord: lens_chord)
      else
        s.view.render_encode(screen, body,
          header: s.header, payload: s.payload, secret: s.secret, secret_cx: s.secret_cx,
          secret_pre: s.secret_pre, alg: s.alg, output: s.output, output_ok: s.output_ok?,
          pane: s.pane, focused: focused, lens_chord: lens_chord)
      end
    end

    # --- key handling ---
    # DECODED / OUTPUT and the ATTACKS list are read-only — a digit is navigation there; INPUT
    # is INS/READ; HEADER, PAYLOAD and SECRET type.
    private def readonly_pane?(pane : Symbol) : Bool
      {:decoded, :attacks, :output}.includes?(pane)
    end

    private def lens_editor(s : JwtSession, pane : Symbol) : TextArea?
      case pane
      when :header  then s.header
      when :payload then s.payload
      end
    end

    private def route_pane(ev : Termisu::Event::Key, c : Char?) : Bool
      case cur.pane
      when :input   then edit_input(ev, c)
      when :header  then edit_lens_editor(ev, c, cur.header); true
      when :payload then edit_lens_editor(ev, c, cur.payload); true
      when :secret  then edit_secret(ev, c); true
      when :decoded then handle_readonly(ev, :decoded)
      when :output  then handle_readonly(ev, :output)
      when :attacks then handle_attacks(ev)
      else               true
      end
    end

    # SECRET is the HMAC key or the PEM path the ENCODE lens signs under: re-sign on every edit.
    private def on_secret_edit(s : JwtSession) : Nil
      recompute_output(s)
    end

    # ---- ATTACKS list ----
    private def handle_attacks(ev : Termisu::Event::Key) : Bool
      return true if space_menu?(ev)
      s = cur
      key = ev.key
      case
      when key.up?, key.lower_k?
        s.view.attacks_at_top? ? cross_pane(s, -1) : s.view.attacks_move(-1)
      when key.down?, key.lower_j? then s.view.attacks_move(1)
      when key.enter?              then jwt_copy_attack
      when plain_char?(ev, ev.char || key.to_char)
        return false # y + Global breath → keymap
      end
      true
    end

    # --- focus ring ---
    private def panes(s : JwtSession) : Array(Symbol)
      s.mode == :decode ? DECODE_PANES : ENCODE_PANES
    end

    # --- mouse ---
    # The editor under (mx, my), its content rect, and the `TextReadState` that owns the
    # SELECTION there — nil for a plain always-editing pane (HEADER / PAYLOAD, and INPUT while
    # in INS, where the TextArea carries its own anchor). One derivation for both gestures,
    # matching `handle_click`'s layout call.
    #
    # The INPUT arm used to bail unless the pane was in INS, which left READ mode — the mode
    # whose whole purpose is select-and-copy, and which advertises "⇧arrows select · y copy" —
    # with no drag and no double-click at all, while the identical Decoder pane has both. The
    # press placed a caret there the whole time; only the two gestures that continue it were
    # missing.
    #
    # `my > card.y` on the top card of each lens: that border row is BUTTONS (the lens chip,
    # and INPUT's READ/INS chip), and both gestures here CONTINUE a press that
    # `handle_click` already answered as a button. Without it, pressing the lens chip and
    # twitching the mouse flipped the lens and then dragged a selection open in the pane the
    # flip had just revealed, and an impatient double-tap on the chip took a word out of a
    # pane nobody had clicked — `click_to_cursor` pins a row above the body to row 0 rather
    # than refusing it. The Repeater refuses a double-click on its own border badges for the
    # same reason (`chrome_hit` in `RepeaterController#handle_double_click`).
    private def editor_at(rect : Rect, mx : Int32, my : Int32) : {TextArea, Rect, TextReadState?}?
      body = body_rect_below_filter(rect)
      s = cur
      if s.mode == :decode
        input_c, _, _ = s.view.decode_layout(body)
        return nil unless input_c.contains?(mx, my) && my > input_c.y
        {s.input, input_c.inset(1, 1), s.input_mode == InputMode::Insert ? nil : s.input_read}
      else
        hdr_c, pay_c, _, _ = s.view.encode_layout(body)
        return {s.header, hdr_c.inset(1, 1), nil} if hdr_c.contains?(mx, my) && my > hdr_c.y
        return {s.payload, pay_c.inset(1, 1), nil} if pay_c.contains?(mx, my)
        nil
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      body = body_rect_below_filter(rect)
      s = cur
      if s.mode == :decode
        input_c, dec_c, atk_c = s.view.decode_layout(body)
        if input_c.contains?(mx, my)
          click_input_card(s, input_c, mx, my)
        elsif dec_c.contains?(mx, my)
          enter_pane(s, :decoded)
        elsif atk_c.contains?(mx, my)
          # Select-only, not select-then-open: ↵ on this list COPIES the payload to the
          # clipboard, and a second click quietly filling the clipboard is not what a click
          # means anywhere else here.
          enter_pane(s, :attacks)
          if row = s.view.attacks_gauge_row(atk_c, mx, my, s.attacks.size)
            s.view.select_attack_row(row, s.attacks.size)
          elsif row = s.view.attacks_row_at(atk_c, my, s.attacks.size)
            s.view.select_attack_row(row, s.attacks.size)
          end
        end
      else
        hdr_c, pay_c, sec_c, out_c = s.view.encode_layout(body)
        if hdr_c.contains?(mx, my)
          enter_pane(s, :header)
          # ` ^T:→DECODE ` on this card's border — the way back, and the same act as the chord.
          if s.view.lens_chip_hit(hdr_c, mx, my, :encode, lens_chord)
            toggle_mode
          else
            s.header.click_to_cursor(hdr_c.inset(1, 1), mx, my)
          end
        elsif pay_c.contains?(mx, my)
          enter_pane(s, :payload)
          s.payload.click_to_cursor(pay_c.inset(1, 1), mx, my)
        elsif sec_c.contains?(mx, my)
          enter_pane(s, :secret)
          # The ` ^A:<alg> ` badge on the card's own border — the Decoder's identical
          # ` ^X:<mode> ` chip has always been clickable, and this one was drawn and inert.
          cycle_alg if s.view.secret_alg_hit(sec_c, mx, my, s.alg)
        elsif out_c.contains?(mx, my)
          enter_pane(s, :output)
        end
      end
      true
    end

    # Pointer-aware: the card under the cursor scrolls, keyboard focus stays put. The same
    # lens layouts `handle_click` hit-tests with.
    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      s = cur
      body = body_rect_below_filter(rect)
      pane =
        if s.mode == :decode
          input_c, dec_c, atk_c = s.view.decode_layout(body)
          case
          when input_c.contains?(mx, my) then :input
          when dec_c.contains?(mx, my)   then :decoded
          when atk_c.contains?(mx, my)   then :attacks
          else                                s.pane
          end
        else
          hdr_c, pay_c, _, out_c = s.view.encode_layout(body)
          case
          when hdr_c.contains?(mx, my) then :header
          when pay_c.contains?(mx, my) then :payload
          when out_c.contains?(mx, my) then :output
          else                              s.pane
          end
        end
      wheel_pane(s, pane, step)
      true
    end

    private def wheel_pane(s : JwtSession, pane : Symbol, step : Int32) : Nil
      case pane
      when :decoded then s.view.scroll_decoded(step)
      when :output  then s.view.scroll_output(step)
      when :attacks then s.view.attacks_move(step)
      when :input   then s.input.scroll_view(step)
      when :header  then s.header.scroll_view(step)
      when :payload then s.payload.scroll_view(step)
      end
    end

    def set_preedit(text : String) : Bool
      s = cur
      case s.pane
      when :input   then s.input.set_preedit(text) if s.input_mode == InputMode::Insert
      when :header  then s.header.set_preedit(text)
      when :payload then s.payload.set_preedit(text)
      when :secret  then s.secret_pre = text
      end
      true
    end

    # --- verbs / actions ---
    def toggle_mode : Nil
      s = cur
      if s.mode == :decode
        s.mode = :encode
        s.pane = :header
      else
        s.mode = :decode
        s.pane = :input
      end
      @host.status(s.mode == :encode ? "ENCODE lens" : "DECODE lens")
    end

    def cycle_alg : Nil
      s = cur
      i = Jwt::ALGS.index(s.alg) || 0
      set_alg(s, Jwt::ALGS[(i + 1) % Jwt::ALGS.size])
      recompute_output(s)
      @host.status("alg = #{s.alg}#{@alg_cleared_key ? " · key cleared" : ""}")
    end

    # Set the algorithm, and DROP the key field when the change crosses the HMAC/asymmetric
    # boundary. That one field holds two different things — a literal HMAC secret, or a PEM
    # key gori resolves — and which one it is comes from the alg alone. Carried across the
    # boundary in silence, a typed `./private.pem` became the fourteen-byte HMAC secret
    # `./private.pem` and OUTPUT showed a token signed with a filename, with no error: the
    # same class the CLI avoids by having `--secret` and `--key` be separate flags. There is
    # only one field here, so the boundary is where its content stops being meaningful.
    private def set_alg(s : JwtSession, alg : String) : Nil
      @alg_cleared_key = Jwt::Asym.alg?(s.alg) != Jwt::Asym.alg?(alg) && !s.secret.empty?
      s.alg = alg
      return unless @alg_cleared_key
      s.secret = ""
      s.secret_cx = 0
      s.secret_pre = ""
    end

    # Seed the ENCODE editors from the INPUT token's decoded claims + switch to ENCODE.
    def load_decoded : Nil
      s = cur
      token = s.input.text.strip
      if token.empty?
        @host.status("INPUT is empty — nothing to load")
        return
      end
      h = Jwt.header_json(token)
      p = Jwt.payload_json(token)
      if h.empty? && p.empty?
        @host.status("INPUT is not a decodable JWT")
        return
      end
      s.header.set_text(h)
      s.payload.set_text(p)
      # Adopting the token's alg can cross the same boundary `cycle_alg` guards — and here the
      # operator did not even press a key for it, so a carried-over key would be reinterpreted
      # by a token they merely loaded.
      if (a = Jwt.token_alg(token)) && Jwt::ALGS.includes?(a)
        set_alg(s, a)
      end
      s.mode = :encode
      s.pane = :header
      recompute_output(s)
      @host.status("loaded decoded claims into the editor")
    end

    # Clearing drops the token, both ENCODE editors and the SECRET, and `TextArea#set_text`
    # empties each editor's undo stack with them — so it asks first, the way `notes_clear`
    # does. A session with nothing in it has nothing to lose and clears without the prompt.
    def clear_all : Nil
      s = cur
      return clear_session(s) if session_blank?(s)
      @host.confirm("CLEAR SESSION", "Clear this session's token, editors and secret?\nThis can't be undone.",
        confirm_label: "clear", danger: true) { clear_session(s) }
    end

    private def session_blank?(s : JwtSession) : Bool
      s.input.text.empty? && s.header.text.empty? && s.payload.text.empty? && s.secret.empty?
    end

    private def clear_session(s : JwtSession) : Nil
      s.input.set_text("")
      s.header.set_text("")
      s.payload.set_text("")
      s.secret = ""
      s.secret_cx = 0
      recompute_decode(s)
      recompute_output(s)
      @host.status("cleared")
    end

    # Copy the selected ATTACK's token.
    def jwt_copy_attack : Nil
      s = cur
      if a = s.attacks[s.view.attacks_selected]?
        do_copy(a.token, a.name)
      else
        @host.status("no attack selected")
      end
    end

    # The unified Copy verb's text (see `WorkbenchController#copy_pane`). EVERY editable pane
    # consults its band: in INS on INPUT it used to copy `s.input.text`, the WHOLE token, while
    # `selection_active?` was reporting the ⇧arrow band as live — the same "claims a selection,
    # copies something else" split `RepeaterView#pane_selection?` documents — and HEADER and
    # PAYLOAD were never asked at all.
    #
    # NOT the same as `selection_text`, which is the "Send selection to" payload and
    # deliberately answers "" on the ENCODE panes — that flow lives in the space menu, which
    # cannot be opened from a pane where space types a space.
    def pane_copy_text : String
      s = cur
      case s.pane
      when :input   then input_copy_text(s)
      when :header  then band_or_all(s.header)
      when :payload then band_or_all(s.payload)
      when :secret  then s.secret
      when :decoded then s.decoded
      when :output  then s.output_ok? ? s.output : ""
      when :attacks then (a = s.attacks[s.view.attacks_selected]?) ? a.token : ""
      else               ""
      end
    end

    def selection_text : String
      s = cur
      case s.pane
      when :input   then input_selection_text(s)
      when :decoded then s.decoded
      when :output  then s.output_ok? ? s.output : ""
      when :attacks then (a = s.attacks[s.view.attacks_selected]?) ? a.token : ""
      else               ""
      end
    end

    def body_hint(focus : Symbol) : String
      s = cur
      reg = @host.session.registry
      ov = Hotkeys.rebindable_overrides(reg)
      y = Hotkeys.binding_label(reg, "jwt.copy", "y", ov)
      # The lens switch was `^E` — a letter `Hotkeys::CLAIMED_CTRL_LETTERS` reserves for the
      # shell's open-in-$EDITOR. It worked (the shell's ^E branch has no `:jwt` arm and falls
      # through) but could never be a registered chord, so it was unbindable AND it spent the
      # key that would one day give this tab's INPUT pane an external editor. `^T` is the
      # Repeater's letter for the same gesture (`repeater.toggle-decoded`: switch which
      # representation the pane is showing), and free here. Read from the keymap, so a rebind
      # shows up in the footer instead of the footer lying about it — and in the top card's
      # ` ^T:→ENCODE ` chip, which resolves the same chord through the same helper.
      lens = lens_chord(reg, ov)
      case s.pane
      when :input
        if s.input_mode == InputMode::Insert
          # The READ arm below advertises the band and `y`; INSERT kept the band and named
          # neither it nor the key that copies it. `y` is a literal character while typing —
          # and typing it over the band REPLACES it — so `^Y` is the copy this mode has.
          keys("type a JWT · ⇧arrows select · ^Y copy · esc read · ↓ decoded · #{lens} encode · {jwt.clear} clear · ^N new · ↑ sub-tabs")
        else
          keys("{editor.insert}/↵ edit · ⇧arrows select · #{y} copy · space cmds · ↓ decoded · #{lens} encode · ^N new · esc sub-tabs")
        end
      when :decoded
        "↑/↓ scroll · #{y} copy · space cmds · ↑-top input · ↓ attacks · #{lens} encode · esc sub-tabs"
      when :attacks
        "↑/↓ pick · ↵/#{y} copy token · space cmds · ↑-top decoded · #{lens} encode · esc sub-tabs"
      when :header, :payload
        # The ENCODE lens has no READ mode at all — its three panes always capture keys — so
        # `^Y` is the ONLY copy here, and `space cmds` was a lie the moment it was written:
        # `edit_lens_editor`/`edit_secret` insert a literal space (`handle_body_key` only defers
        # ctrl/alt chords). Naming a menu that types a space instead of opening cost these
        # strips the one token that had room to say which key copies.
        keys("type JSON · ⇧arrows select · ^Y copy · ↑/↓ move+cross · {jwt.cycle-alg} alg · #{lens} decode · esc sub-tabs")
      when :secret
        # Same trade as HEADER/PAYLOAD above, minus `⇧arrows select`: SECRET is a plain String
        # + caret index (WorkbenchSession#secret_cx), not a TextArea, so it has no band to grow.
        # `^Y` still copies the whole field.
        keys("type #{Jwt::Asym.alg?(s.alg) ? "PEM key path" : "secret"} · ^Y copy · {jwt.cycle-alg} alg (#{s.alg}) · ↑/↓ cross · #{lens} decode · esc sub-tabs")
      when :output
        keys("↑/↓ scroll · #{y} copy token · space cmds · {jwt.cycle-alg} alg · #{lens} decode · esc sub-tabs")
      else
        ""
      end
    end

    # --- recompute ---
    private def recompute_decode(s : JwtSession) : Nil
      token = s.input.text.strip
      s.decoded = decode_text(token)
      s.attacks = Jwt.attacks(token)
      s.input_jwe = Jwt::Jwe.jwe?(token)
      s.view.reset_decoded_scroll
    end

    private def decode_text(token : String) : String
      return "" if token.empty?
      Decoder::Codecs.jwt_decode(token.to_slice)
    rescue ex
      "// #{ex.message}"
    end

    private def recompute_output(s : JwtSession) : Nil
      if s.header.text.strip.empty? && s.payload.text.strip.empty?
        s.output = ""
        s.output_ok = true
      else
        begin
          s.output = Jwt.encode(s.header.text, s.payload.text, s.alg, s.secret)
          s.output_ok = true
        rescue ex : Jwt::ForgeError
          s.output = ex.message || "invalid input"
          s.output_ok = false
        end
      end
      s.view.reset_output_scroll
    end
  end
end
