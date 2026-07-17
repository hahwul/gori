require "../tab_controller"
require "../jwt_view"
require "../text_area"
require "../input_mode"
require "../text_read_state"
require "../clipboard"
require "../subtab_clone"
require "../../jwt"
require "../../decoder/codecs"

module Gori::Tui
  # One JWT workbench session (a sub-tab). Carries the two lenses' buffers: the DECODE
  # side (raw token INPUT + the cached decode/attacks derived from it) and the ENCODE
  # side (HEADER/PAYLOAD JSON editors + SECRET + alg → the cached OUTPUT token). `mode`
  # picks the visible lens; `pane` is the focus ring position within it. Mutable class.
  class JwtSession
    property view : JwtView
    property input : TextArea
    property input_mode : InputMode = InputMode::Read
    property input_read : TextReadState = TextReadState.new
    property header : TextArea
    property payload : TextArea
    property secret : String = ""
    property secret_cx : Int32 = 0
    property secret_pre : String = ""
    property alg : String = "HS256"
    property mode : Symbol = :decode # :decode | :encode
    property pane : Symbol = :input
    # Cached results (recomputed on edit, never on the render hot path).
    property decoded : String = ""
    property attacks : Array(Jwt::Attack) = [] of Jwt::Attack
    property output : String = ""
    property? output_ok : Bool = true

    def initialize(input_text : String, name : String?)
      @view = JwtView.new
      @view.name = name
      @input = TextArea.new(input_text)
      @input.follow_x = true
      @header = TextArea.new("")
      @payload = TextArea.new("")
    end
  end

  # The JWT tab: a hidden workbench for decoding, editing/re-signing, and generating
  # testing payloads (alg:none, weak-secret re-sign, header injection) from a token.
  # Body consumes every printable key (like Decoder/Notes), so command_scope is the JWT
  # scope and handle_body_key always returns true; the JWT verbs' mnemonics never collide
  # with literal text — they're reached from the space menu + palette. A runner-owned
  # sub-tab strip appears from the first session (^N new · ^W close · ^E lens · ^A alg).
  class JwtController < TabController
    DECODE_PANES = [:input, :decoded, :attacks]
    ENCODE_PANES = [:header, :payload, :secret, :output]

    @sessions : Array(JwtSession)

    def initialize(host : Host)
      super(host)
      @sessions = [make_session("", nil)]
      @idx = 0
    end

    def tab : Symbol
      :jwt
    end

    def command_scope : Verb::Scope
      Verb::Scope::Jwt
    end

    # The focused pane, so section-tagged verbs (jwt.copy-token on :output, jwt.copy-attack
    # on :attacks, jwt.select-line on :input) surface in the space menu's CONTEXT group.
    # Without this the default :common hides every pane-scoped verb (mirrors DecoderController).
    def command_section : Symbol
      cur.pane
    end

    # INS editors (input-insert / header / payload / secret) show the EDITOR badge;
    # everything else is navigable body.
    def body_badge : Symbol
      s = cur
      editing = case s.pane
                when :input            then s.input_mode == InputMode::Insert
                when :header, :payload, :secret then true
                else                        false
                end
      editing ? :editor : :body
    end

    private def cur : JwtSession
      @sessions[@idx]
    end

    private def make_session(input_text : String, name : String?) : JwtSession
      s = JwtSession.new(input_text, name)
      recompute_decode(s)
      recompute_encode(s)
      s
    end

    # --- sub-tab strip (runner-owned chrome; shown from the first session) ---
    def subtab_labels : Array(String)
      @sessions.map_with_index { |s, i| "#{i + 1}:#{session_label(s)}" }
    end

    def subtab_index : Int32
      @idx
    end

    def subtab_strip_shown? : Bool
      true
    end

    def subtab_filter_enabled? : Bool
      true
    end

    def filter_fields : Array(String)
      %w(name)
    end

    def filter_subjects : Array(Repeater::SubtabFilter::Subject)
      @sessions.map do |s|
        Repeater::SubtabFilter::Subject.new(s.view.name, s.input.text, "", "", [] of String)
      end
    end

    # The chip label: the custom name, else the token's alg (or "empty"), capped ~18 cols.
    private def session_label(s : JwtSession) : String
      raw = (n = s.view.name) ? n : token_summary(s)
      raw.size > 18 ? raw[0, 17] + "…" : raw
    end

    private def token_summary(s : JwtSession) : String
      return "empty" if s.input.text.strip.empty?
      (a = Jwt.token_alg(s.input.text)) ? "jwt #{a}" : "jwt"
    end

    def move_subtab(dir : Int32) : Nil
      if t = step_visible(@idx, dir)
        switch_to(t)
      end
    end

    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @sessions.size
      clear_subtab_filter if (h = subtab_hidden) && h.includes?(idx)
      switch_to(idx) if idx != @idx
    end

    private def switch_to(idx : Int32) : Nil
      @idx = idx
    end

    # --- session lifecycle ---
    def jwt_new : Nil
      @sessions << make_session("", nil)
      @idx = @sessions.size - 1
      @host.request_focus(:body)
      @host.status("new JWT session (#{@sessions.size} open)")
    end

    # Seed a NEW session from an externally-supplied token (the "Send selection to → JWT"
    # flow) and jump into it. Mirrors DecoderController#decoder_from_text.
    def jwt_from_text(text : String, name : String? = nil) : Nil
      s = make_session(text.strip, name)
      @sessions << s
      @idx = @sessions.size - 1
      @host.goto_tab(:jwt)
      @host.status("sent selection to JWT (#{text.bytesize}b)")
    end

    def jwt_duplicate : Nil
      s = cur
      name = SubtabClone.copy_name(s.view.name)
      dup = make_session(s.input.text, name)
      dup.header.set_text(s.header.text)
      dup.payload.set_text(s.payload.text)
      dup.secret = s.secret
      dup.alg = s.alg
      recompute_encode(dup)
      @sessions << dup
      @idx = @sessions.size - 1
      @host.request_focus(:body)
      @host.status("duplicated JWT session (#{@sessions.size} open)")
    end

    def jwt_close : Nil
      if @sessions.size <= 1
        @sessions[0] = make_session("", nil)
        @idx = 0
      else
        @sessions.delete_at(@idx)
        @idx = @idx.clamp(0, @sessions.size - 1)
      end
      @host.status(@sessions.size == 1 ? "session closed" : "session closed (#{@sessions.size} open)")
    end

    def view_at(idx : Int32) : JwtView?
      (0 <= idx < @sessions.size) ? @sessions[idx].view : nil
    end

    def apply_rename(view : JwtView, name : String) : Nil
      clean = name.strip
      view.name = clean.empty? ? nil : clean
    end

    # --- render ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      labels = subtab_labels
      s = cur
      shell = BodyChrome.shell_focused(focus, multi_pane: true)
      subtabs_focused = focus == :subtabs
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused, labels, @idx, @subtab_start, subtab_hidden) do |content|
        render_with_filter(screen, content, subtabs_focused) do |body|
          if s.mode == :decode
            s.view.render_decode(screen, body,
              input: s.input, input_mode: s.input_mode, input_read: s.input_read,
              decoded: s.decoded, attacks: s.attacks, pane: s.pane, focused: body_focused)
          else
            s.view.render_encode(screen, body,
              header: s.header, payload: s.payload, secret: s.secret, secret_cx: s.secret_cx,
              secret_pre: s.secret_pre, alg: s.alg, output: s.output, output_ok: s.output_ok?,
              pane: s.pane, focused: body_focused)
          end
        end
      end
    end

    # --- key handling ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p?
        commit
        @host.open_palette
      elsif ev.ctrl? && c && '1' <= c <= '9'
        jump_subtab(c.to_i - 1)
      elsif ev.ctrl? && key.lower_n?
        jwt_new
      elsif ev.ctrl? && key.lower_w?
        jwt_close
      elsif ev.ctrl? && key.lower_l?
        clear_all
      elsif ev.ctrl? && key.lower_e?
        toggle_mode
      elsif ev.ctrl? && key.lower_a?
        cycle_alg
      elsif ev.ctrl? && key.lower_y?
        jwt_copy
      elsif key.escape?
        handle_escape
      else
        return route_pane(ev, c)
      end
      true
    end

    private def handle_escape : Nil
      s = cur
      if s.pane == :input && s.input_mode == InputMode::Insert
        s.input_mode = InputMode::Read
        s.input_read.sync_from(s.input)
      else
        commit
        @host.request_focus(:subtabs)
      end
    end

    private def route_pane(ev : Termisu::Event::Key, c : Char?) : Bool
      case cur.pane
      when :input   then edit_input(ev, c)
      when :header  then edit_json(ev, c, cur.header); true
      when :payload then edit_json(ev, c, cur.payload); true
      when :secret  then edit_secret(ev, c); true
      when :decoded then handle_readonly(ev, :decoded)
      when :output  then handle_readonly(ev, :output)
      when :attacks then handle_attacks(ev)
      else               true
      end
    end

    # ---- INPUT editor (INS/READ, like the Decoder input) ----
    private def edit_input(ev : Termisu::Event::Key, c : Char?) : Bool
      s = cur
      return handle_input_read(ev, c) unless s.input_mode == InputMode::Insert
      key = ev.key
      case
      when ev.ctrl_z?    then s.input.undo; recompute_decode(s)
      when key.enter?    then s.input.insert_newline; recompute_decode(s)
      when key.backspace? then s.input.backspace; recompute_decode(s)
      when key.up?
        s.input.at_top? ? cross_pane(s, -1) : s.input.move(-1, 0)
      when key.down?
        s.input.at_bottom? ? cross_pane(s, 1) : s.input.move(1, 0)
      when key.left?   then s.input.move(0, -1)
      when key.right?  then s.input.move(0, 1)
      when key.home?   then s.input.home
      when key.end?    then s.input.end_of_line
      when key.delete? then s.input.delete; recompute_decode(s)
      else
        if c && !ev.ctrl? && !ev.alt?
          s.input.insert(c)
          s.input.set_preedit("")
          recompute_decode(s)
        end
      end
      true
    end

    private def handle_input_read(ev : Termisu::Event::Key, c : Char?) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
      s = cur
      key = ev.key
      selecting = ev.shift?
      case
      when key.enter?, c == 'i' then s.input_mode = InputMode::Insert
      when key.up?
        s.input.at_top? ? cross_pane(s, -1) : s.input_read.move(s.input, -1, 0, selecting: selecting)
      when key.down?
        s.input.at_bottom? ? cross_pane(s, 1) : s.input_read.move(s.input, 1, 0, selecting: selecting)
      when key.left?  then s.input_read.move(s.input, 0, -1, selecting: selecting)
      when key.right? then s.input_read.move(s.input, 0, 1, selecting: selecting)
      when key.home?  then s.input.home
      when key.end?   then s.input.end_of_line
      when c && !ev.ctrl? && !ev.alt? && !c.control?
        return false # x/y + Global breath → keymap
      end
      true
    end

    # ---- HEADER / PAYLOAD JSON editors (always-insert; edits re-encode live) ----
    private def edit_json(ev : Termisu::Event::Key, c : Char?, ed : TextArea) : Nil
      s = cur
      key = ev.key
      case
      when ev.ctrl_z?     then ed.undo; recompute_encode(s)
      when key.enter?     then ed.insert_newline; recompute_encode(s)
      when key.backspace? then ed.backspace; recompute_encode(s)
      when key.up?        then ed.at_top? ? cross_pane(s, -1) : ed.move(-1, 0)
      when key.down?      then ed.at_bottom? ? cross_pane(s, 1) : ed.move(1, 0)
      when key.left?      then ed.move(0, -1)
      when key.right?     then ed.move(0, 1)
      when key.home?      then ed.home
      when key.end?       then ed.end_of_line
      when key.delete?    then ed.delete; recompute_encode(s)
      else
        if c && !ev.ctrl? && !ev.alt?
          ed.insert(c)
          ed.set_preedit("")
          recompute_encode(s)
        end
      end
    end

    # ---- SECRET single-line field ----
    private def edit_secret(ev : Termisu::Event::Key, c : Char?) : Nil
      s = cur
      key = ev.key
      case
      when key.up?    then cross_pane(s, -1)
      when key.down?  then cross_pane(s, 1)
      when key.left?  then s.secret_cx = {s.secret_cx - 1, 0}.max
      when key.right? then s.secret_cx = {s.secret_cx + 1, s.secret.size}.min
      when key.home?  then s.secret_cx = 0
      when key.end?   then s.secret_cx = s.secret.size
      when key.backspace?
        if s.secret_cx > 0
          s.secret = s.secret[0, s.secret_cx - 1] + s.secret[s.secret_cx..]
          s.secret_cx -= 1
          s.secret_pre = ""
          recompute_encode(s)
        end
      else
        if c && !ev.ctrl? && !ev.alt? && !c.control?
          s.secret = s.secret[0, s.secret_cx] + c.to_s + s.secret[s.secret_cx..]
          s.secret_cx += 1
          s.secret_pre = ""
          recompute_encode(s)
        end
      end
    end

    # ---- read-only DECODED / OUTPUT panes ----
    private def handle_readonly(ev : Termisu::Event::Key, which : Symbol) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
      s = cur
      key = ev.key
      at_top = which == :decoded ? s.view.decoded_at_top? : s.view.output_at_top?
      case
      when key.up?, key.lower_k?
        at_top ? cross_pane(s, -1) : scroll_pane(s, which, -1)
      when key.down?, key.lower_j?
        scroll_pane(s, which, 1)
      when (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt? && !c.control?
        return false # y + Global breath → keymap
      end
      true
    end

    private def scroll_pane(s : JwtSession, which : Symbol, step : Int32) : Nil
      which == :decoded ? s.view.scroll_decoded(step) : s.view.scroll_output(step)
    end

    # ---- ATTACKS list ----
    private def handle_attacks(ev : Termisu::Event::Key) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
      s = cur
      key = ev.key
      case
      when key.up?, key.lower_k?
        s.view.attacks_at_top? ? cross_pane(s, -1) : s.view.attacks_move(-1)
      when key.down?, key.lower_j? then s.view.attacks_move(1)
      when key.enter?              then jwt_copy_attack
      when (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt? && !c.control?
        return false # y + Global breath → keymap
      end
      true
    end

    # --- focus ring ---
    private def panes(s : JwtSession) : Array(Symbol)
      s.mode == :decode ? DECODE_PANES : ENCODE_PANES
    end

    private def cross_pane(s : JwtSession, dir : Int32) : Nil
      order = panes(s)
      i = order.index(s.pane) || 0
      ni = i + dir
      if ni < 0
        commit
        @host.request_focus(:subtabs)
      elsif ni < order.size
        enter_pane(s, order[ni])
      end
    end

    private def enter_pane(s : JwtSession, p : Symbol) : Nil
      s.pane = p
      s.input_read.sync_from(s.input) if p == :input && s.input_mode == InputMode::Read
    end

    def pane_advance(dir : Int32) : Bool
      s = cur
      order = panes(s)
      i = order.index(s.pane) || 0
      ni = i + dir
      return false if ni < 0 || ni >= order.size
      enter_pane(s, order[ni])
      true
    end

    def focus_first : Nil
      enter_pane(cur, panes(cur).first)
    end

    def focus_last : Nil
      enter_pane(cur, panes(cur).last)
    end

    # --- mouse ---
    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      body = body_rect_below_filter(rect)
      s = cur
      if s.mode == :decode
        input_c, dec_c, atk_c = s.view.decode_layout(body)
        if input_c.contains?(mx, my)
          enter_pane(s, :input)
          s.input.click_to_cursor(input_c.inset(1, 1), mx, my)
          s.input_read.sync_from(s.input) unless s.input_mode == InputMode::Insert
        elsif dec_c.contains?(mx, my)
          enter_pane(s, :decoded)
        elsif atk_c.contains?(mx, my)
          enter_pane(s, :attacks)
        end
      else
        hdr_c, pay_c, sec_c, out_c = s.view.encode_layout(body)
        if hdr_c.contains?(mx, my)
          enter_pane(s, :header)
          s.header.click_to_cursor(hdr_c.inset(1, 1), mx, my)
        elsif pay_c.contains?(mx, my)
          enter_pane(s, :payload)
          s.payload.click_to_cursor(pay_c.inset(1, 1), mx, my)
        elsif sec_c.contains?(mx, my)
          enter_pane(s, :secret)
        elsif out_c.contains?(mx, my)
          enter_pane(s, :output)
        end
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      s = cur
      case s.pane
      when :decoded then s.view.scroll_decoded(step)
      when :output  then s.view.scroll_output(step)
      when :attacks then s.view.attacks_move(step)
      when :input   then s.input.scroll_view(step) if s.input_mode == InputMode::Read
      end
      true
    end

    def set_preedit(text : String) : Bool
      s = cur
      case s.pane
      when :input   then s.input.set_preedit(text) if s.input_mode == InputMode::Insert
      when :header  then s.header.set_preedit(text)
      when :payload then s.payload.set_preedit(text)
      when :secret  then s.secret_pre = text
      else               nil
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
      s.alg = Jwt::ALGS[(i + 1) % Jwt::ALGS.size]
      recompute_encode(s)
      @host.status("alg = #{s.alg}")
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
      if (a = Jwt.token_alg(token)) && Jwt::ALGS.includes?(a)
        s.alg = a
      end
      s.mode = :encode
      s.pane = :header
      recompute_encode(s)
      @host.status("loaded decoded claims into the editor")
    end

    def clear_all : Nil
      s = cur
      s.input.set_text("")
      s.header.set_text("")
      s.payload.set_text("")
      s.secret = ""
      s.secret_cx = 0
      recompute_decode(s)
      recompute_encode(s)
      @host.status("cleared")
    end

    # Copy the OUTPUT (re-signed) token.
    def jwt_copy_token : Nil
      s = cur
      if s.output_ok? && !s.output.empty?
        do_copy(s.output, "token")
      else
        @host.status("no valid token to copy")
      end
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

    # The unified Copy verb: selection (INPUT read) or the focused pane's content.
    def jwt_copy : Nil
      s = cur
      text = case s.pane
             when :input   then s.input_mode == InputMode::Read ? s.input_read.copy_text(s.input) : s.input.text
             when :header  then s.header.text
             when :payload then s.payload.text
             when :secret  then s.secret
             when :decoded then s.decoded
             when :output  then s.output_ok? ? s.output : ""
             when :attacks then (a = s.attacks[s.view.attacks_selected]?) ? a.token : ""
             else               ""
             end
      do_copy(text)
    end

    def jwt_copy_all : Nil
      jwt_copy
    end

    private def do_copy(text : String, label : String? = nil) : Nil
      if text.empty?
        @host.status("nothing to copy")
      else
        written = Clipboard.copy(text)
        prefix = label ? "copied \"#{label}\"" : "copied"
        @host.status("#{prefix} (#{written}b)")
      end
    end

    # --- selection (for the "Send selection to" flow + copy verbs) ---
    def jwt_read_mode? : Bool
      s = cur
      s.pane == :decoded || s.pane == :output || s.pane == :attacks ||
        (s.pane == :input && s.input_mode == InputMode::Read)
    end

    def jwt_selection_active? : Bool
      s = cur
      s.pane == :input && s.input_mode == InputMode::Read && s.input_read.selection?
    end

    def jwt_selection_text : String
      s = cur
      case s.pane
      when :input   then s.input_mode == InputMode::Read ? s.input_read.copy_text(s.input) : ""
      when :decoded then s.decoded
      when :output  then s.output_ok? ? s.output : ""
      when :attacks then (a = s.attacks[s.view.attacks_selected]?) ? a.token : ""
      else               ""
      end
    end

    def jwt_select_line : Nil
      s = cur
      s.input_read.select_line(s.input) if s.pane == :input && s.input_mode == InputMode::Read
    end

    def jwt_clear_selection : Nil
      cur.input_read.clear_selection if cur.pane == :input
    end

    def body_hint(focus : Symbol) : String
      s = cur
      y = Hotkeys.binding_label(@host.session.registry, "jwt.copy", "y")
      case s.pane
      when :input
        if s.input_mode == InputMode::Insert
          "type a JWT · esc read · ↓ decoded · ^E encode · ^L clear · ^N new · ↑ sub-tabs"
        else
          "i/↵ edit · ⇧arrows select · #{y} copy · space cmds · ↓ decoded · ^E encode · ^N new · esc tabs"
        end
      when :decoded
        "↑/↓ scroll · #{y} copy · space cmds · ↑-top input · ↓ attacks · ^E encode · esc tabs"
      when :attacks
        "↑/↓ pick · ↵/#{y} copy token · space cmds · ↑-top decoded · ^E encode · esc tabs"
      when :header, :payload
        "type JSON · ↑/↓ move+cross · ^A alg · ^E decode · space cmds · esc tabs"
      when :secret
        "type secret · ^A alg (#{s.alg}) · ↑/↓ cross · ^E decode · space cmds · esc tabs"
      when :output
        "↑/↓ scroll · #{y} copy token · space cmds · ^A alg · ^E decode · esc tabs"
      else
        ""
      end
    end

    def on_enter : Nil
      # Nothing to recompute on enter — caches stay valid across tab switches.
    end

    # Ephemeral scratch tool: sessions live in memory only (no settings persistence),
    # so commit is a no-op. Kept for the TabController contract + the runner's commit
    # call sites (focus-leave, quit) so a future persistence add has a single seam.
    def commit : Nil
    end

    # --- recompute ---
    private def recompute_decode(s : JwtSession) : Nil
      token = s.input.text.strip
      s.decoded = decode_text(token)
      s.attacks = Jwt.attacks(token)
      s.view.reset_decoded_scroll
    end

    private def decode_text(token : String) : String
      return "" if token.empty?
      Decoder::Codecs.jwt_decode(token.to_slice)
    rescue ex
      "// #{ex.message}"
    end

    private def recompute_encode(s : JwtSession) : Nil
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
