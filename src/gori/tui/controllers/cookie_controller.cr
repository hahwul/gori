require "json"
require "../tab_controller"
require "../cookie_view"
require "../text_area"
require "../input_mode"
require "../text_read_state"
require "../clipboard"
require "../subtab_clone"
require "../../cookie"
require "../../fuzz/payload"

module Gori::Tui
  # One Cookie workbench session (a sub-tab). Carries the two lenses' buffers: the DECODE
  # side (raw cookie INPUT + the cached decode/verify derived from it) and the FORGE side
  # (PAYLOAD editor + SECRET + format/algorithm/salt → the cached OUTPUT cookie). `mode`
  # picks the visible lens; `pane` is the focus ring position within it. Modelled on
  # JwtSession — the same shape over a different signature scheme. Mutable class.
  class CookieSession
    property view : CookieView
    property input : TextArea
    property input_mode : InputMode = InputMode::Read
    property input_read : TextReadState = TextReadState.new
    property payload : TextArea
    property secret : String = ""
    property secret_cx : Int32 = 0
    property secret_pre : String = ""
    property salt : String = ""
    property salt_cx : Int32 = 0
    property salt_pre : String = ""
    property format : String = "auto"      # auto | flask | rack | django
    property algorithm : String = "sha256" # sha256 | sha1 (Django only)
    # False until the operator cycles the algorithm by hand. While false, a Django cookie's
    # algorithm is inferred from its signature length (sha1 = 20 bytes, sha256 = 32) — the
    # same "auto until you pin it" contract `format` has — so a real SHA-1 `sessionid` does
    # not read as ✗ bad key under the SHA-256 default. Cycling the algo pins the choice.
    property? algorithm_pinned : Bool = false
    property mode : Symbol = :decode # :decode | :forge
    property pane : Symbol = :input
    # Cached results (recomputed on edit, never on the render hot path).
    property decoded : String = ""
    property detected : String? = nil      # the auto-detected format, for the FORGE promotion
    property verify_state : Symbol = :none # :none | :ok | :bad
    property crack_note : String? = nil    # "cracked: …" set by a successful crack, cleared on edit
    property output : String = ""
    property? output_ok : Bool = true

    def initialize(input_text : String, name : String?)
      @view = CookieView.new
      @view.name = name
      @input = TextArea.new(input_text)
      @input.follow_x = true
      @payload = TextArea.new("")
    end

    # Home/End on the INPUT pane — the editor move + READ cursor adoption travel together,
    # exactly as in JwtSession (four sibling views pair them at their own seam).
    def input_home(selecting : Bool = false) : Nil
      @input.home(selecting)
      adopt_input_caret(selecting)
    end

    def input_end(selecting : Bool = false) : Nil
      @input.end_of_line(selecting)
      adopt_input_caret(selecting)
    end

    private def adopt_input_caret(selecting : Bool) : Nil
      return if @input_mode == InputMode::Insert
      @input_read.sync_to(@input, selecting: selecting)
    end
  end

  # The Cookie tab: a hidden workbench for decoding, verifying, cracking, and re-signing
  # framework signed session cookies (Flask/itsdangerous, Rack, Django). Body consumes every
  # printable key (like JWT/Decoder), so command_scope is the Cookie scope and handle_body_key
  # always returns true; the Cookie verbs' mnemonics never collide with literal text — they
  # reach from the space menu + palette. A runner-owned sub-tab strip appears from the first
  # session (^N new · ^W close · ^T lens · ^A format).
  class CookieController < TabController
    DECODE_PANES = [:input, :decoded, :opts, :secret]
    FORGE_PANES  = [:payload, :opts, :secret, :output]
    # ^A cycles these. DECODE includes `auto` (it can detect from the punctuation); FORGE
    # cannot — minting needs a concrete scheme — so it steps the three real formats only.
    DECODE_FORMATS = ["auto", "flask", "rack", "django"]
    FORGE_FORMATS  = ["flask", "rack", "django"]
    ALGORITHMS     = ["sha256", "sha1"]

    @sessions : Array(CookieSession)

    def initialize(host : Host)
      super(host)
      @sessions = [make_session("", nil)]
      @idx = 0
    end

    def tab : Symbol
      :cookie
    end

    def command_scope : Verb::Scope
      Verb::Scope::Cookie
    end

    # The focused pane, so section-tagged verbs (cookie.copy-cookie on :output) surface in the
    # space menu's CONTEXT group (mirrors JwtController).
    def command_section : Symbol
      cur.pane
    end

    # INS editors (input-insert / payload / secret / salt) show the EDITOR badge; the rest is
    # navigable body.
    def body_badge : Symbol
      s = cur
      editing = case s.pane
                when :input                   then s.input_mode == InputMode::Insert
                when :payload, :opts, :secret then true
                else                               false
                end
      editing ? :editor : :body
    end

    private def cur : CookieSession
      @sessions[@idx]
    end

    private def make_session(input_text : String, name : String?) : CookieSession
      s = CookieSession.new(input_text, name)
      recompute_decode(s)
      recompute_forge(s)
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
      %w[name]
    end

    def filter_subjects : Array(Repeater::SubtabFilter::Subject)
      @sessions.map do |s|
        Repeater::SubtabFilter::Subject.new(s.view.name, s.input.text, "", "", [] of String)
      end
    end

    # The ⌕ picker searches the DECODED parts + the FORGE payload, not the opaque cookie the
    # summary carries — an operator remembers a cookie by something inside it (a username, a
    # flag), never by its base64. Both, so either direction is findable by what it says.
    def subtab_search_extras : Array(String)
      @sessions.map { |s| search_extra("#{s.decoded} #{s.payload.text}") }
    end

    # The chip label: the custom name, else the cookie's format (or "empty"), capped ~18 cols.
    private def session_label(s : CookieSession) : String
      raw = (n = s.view.name) ? n : cookie_summary(s)
      raw.size > 18 ? raw[0, 17] + "…" : raw
    end

    private def cookie_summary(s : CookieSession) : String
      return "empty" if s.input.text.strip.empty?
      (f = s.detected) ? "cookie #{f}" : "cookie"
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
    def cookie_new : Nil
      @sessions << make_session("", nil)
      @idx = @sessions.size - 1
      @host.request_focus(:body)
      @host.status("new Cookie session (#{@sessions.size} open)")
    end

    # Seed a NEW session from an externally-supplied cookie (the "Send selection to → Cookie"
    # flow) and jump into it. Mirrors JwtController#jwt_from_text.
    def cookie_from_text(text : String, name : String? = nil) : Nil
      s = make_session(text.strip, name)
      @sessions << s
      @idx = @sessions.size - 1
      @host.goto_tab(:cookie)
      @host.status("sent selection to Cookie (#{text.bytesize}b)")
    end

    # Duplicates the MARKED sub-tabs when the strip carries marks, the active one otherwise
    # (`target_subtab_indices` — the one target rule).
    def cookie_duplicate : Nil
      msg = nil.as(String?)
      if refs = batch_subtab_refs
        msg = duplicate_marked_subtabs(refs, "session") { |i| duplicate_at(i) }
        unless msg
          @host.status("#{refs.size} sub-tabs marked — duplicate is capped at #{Runner::BATCH_SUBTAB_CAP}")
          return
        end
      else
        duplicate_at(@idx)
      end
      @host.request_focus(:body)
      @host.status(msg ? "#{msg} (#{@sessions.size} open)" : "duplicated Cookie session (#{@sessions.size} open)")
    end

    # Clone sub-tab `idx` onto the end of the strip. Toast-free — the arm above says it.
    private def duplicate_at(idx : Int32) : Nil
      return unless src = @sessions[idx]?
      dup = make_session(src.input.text, SubtabClone.copy_name(src.view.name))
      dup.payload.set_text(src.payload.text)
      dup.secret = src.secret
      dup.salt = src.salt
      dup.format = src.format
      dup.algorithm = src.algorithm
      dup.algorithm_pinned = src.algorithm_pinned?
      recompute_decode(dup)
      recompute_forge(dup)
      @sessions << dup
      @idx = @sessions.size - 1
    end

    # ^W closes the MARKED sub-tabs when the strip carries marks, the active one otherwise
    # (`target_subtab_indices` — the one target rule). The single close stays confirm-free as
    # it has always been; a plural one asks, because it discards more than the operator can
    # see at the moment they press the key.
    def cookie_close : Nil
      if refs = batch_subtab_refs
        @host.confirm("CLOSE COOKIE SESSIONS", "Close #{marked_subtab_phrase(refs.size)}?\nEach cookie and its edits are discarded.",
          confirm_label: "close", danger: true) { close_marked_sessions(refs) }
        return
      end
      close_at(@idx)
      @host.status(@sessions.size == 1 ? "session closed" : "session closed (#{@sessions.size} open)")
    end

    private def close_marked_sessions(refs : Array(SubtabRef)) : Nil
      msg = close_marked_subtabs(refs)
      @host.status(msg)
      @host.resolve_subtab_focus
    end

    # Nothing here is persisted, so a close can never leave a saved session behind.
    protected def close_subtab_at(idx : Int32) : Bool
      close_at(idx)
      false
    end

    # Close sub-tab `idx`, keeping at least one session: the last one is REPLACED by a blank
    # rather than removed, so the tab always has something to type into. That replacement
    # also retires the old view object, which is what drops its mark.
    private def close_at(idx : Int32) : Nil
      return if idx < 0 || idx >= @sessions.size
      if @sessions.size <= 1
        @sessions[0] = make_session("", nil)
        @idx = 0
      else
        @sessions.delete_at(idx)
        # Closing a session to the LEFT slides the active one down; a bare clamp would read
        # that as "stay put" and land the operator on its neighbour.
        @idx -= 1 if idx < @idx
        @idx = @idx.clamp(0, @sessions.size - 1)
      end
    end

    def view_at(idx : Int32) : CookieView?
      (0 <= idx < @sessions.size) ? @sessions[idx].view : nil
    end

    # The object that IS sub-tab `idx`, for the strip's mark set (#683). The view, not the
    # index: a reconcile can reorder or drop chips under a standing mark.
    def subtab_ref(idx : Int32) : SubtabRef?
      view_at(idx)
    end

    def apply_rename(view : CookieView, name : String) : Nil
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
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused, labels, @idx, @subtab_start, subtab_hidden, strip_divider: subtab_strip_divider?, find: subtab_find_shown?, find_lit: @host.subtab_find_focused?, marked: marked_chip_set) do |content|
        render_with_filter(screen, content, subtabs_focused) do |body|
          if s.mode == :decode
            s.view.render_decode(screen, body,
              input: s.input, input_mode: s.input_mode, input_read: s.input_read,
              decoded: s.decoded, format: display_format(s), resolved_format: effective_format(s),
              algorithm: effective_algorithm(s), salt: s.salt, salt_cx: s.salt_cx, salt_pre: s.salt_pre,
              salt_preset: salt_preset_label(s),
              verify_state: s.verify_state, crack_note: s.crack_note,
              secret: s.secret, secret_cx: s.secret_cx, secret_pre: s.secret_pre,
              pane: s.pane, focused: body_focused, lens_chord: lens_chord)
          else
            s.view.render_forge(screen, body,
              payload: s.payload, format: display_format(s), resolved_format: effective_format(s),
              algorithm: effective_algorithm(s), salt: s.salt, salt_cx: s.salt_cx, salt_pre: s.salt_pre,
              salt_preset: salt_preset_label(s),
              secret: s.secret, secret_cx: s.secret_cx, secret_pre: s.secret_pre,
              output: s.output, output_ok: s.output_ok?,
              pane: s.pane, focused: body_focused, lens_chord: lens_chord)
          end
        end
      end
    end

    # The lens switch's CURRENT chord — read from the keymap (not hardcoded `^T`) so a rebind
    # moves the top card's chip and the footer that names the same key together.
    private def lens_chord : String
      reg = @host.session.registry
      lens_chord(reg, Hotkeys.rebindable_overrides(reg))
    end

    private def lens_chord(reg : Verb::Registry, overrides : Hash(String, Array(Verb::Chord))) : String
      Hotkeys.binding_label(reg, "cookie.toggle-mode", "^T", overrides)
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
        cookie_new
      elsif ev.ctrl? && key.lower_w?
        cookie_close
      elsif ev.ctrl_z? || editing_motion?(ev)
        return route_pane(ev, c)
      elsif ev.ctrl? || ev.alt?
        # Every other modified chord defers to the central keymap (rebindable) — the rule the
        # Repeater/Fuzzer/JWT already follow; ^A/^T/^L are registered verb chords.
        return false
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
        s.input_read.adopt_editor_selection(s.input)
      else
        commit
        @host.request_focus(:subtabs)
      end
    end

    private def route_pane(ev : Termisu::Event::Key, c : Char?) : Bool
      case cur.pane
      when :input   then edit_input(ev, c)
      when :payload then edit_payload(ev, c); true
      when :opts    then edit_salt(ev, c); true
      when :secret  then edit_secret(ev, c); true
      when :decoded then handle_readonly(ev, :decoded)
      when :output  then handle_readonly(ev, :output)
      else               true
      end
    end

    # ---- INPUT editor (INS/READ, like the JWT input) ----
    private def edit_input(ev : Termisu::Event::Key, c : Char?) : Bool
      s = cur
      return handle_input_read(ev, c) unless s.input_mode == InputMode::Insert
      key = ev.key
      case
      when ev.ctrl_z?                   then s.input.undo; recompute_decode(s)
      when key.enter?                   then s.input.insert_newline; recompute_decode(s)
      when s.input.word_delete_key?(ev) then editor_motion(ev, s.input) { recompute_decode(s) }
      when key.backspace?               then s.input.backspace; recompute_decode(s)
      when key.up?
        (s.input.at_top? && !ev.shift?) ? cross_pane(s, -1) : editor_motion(ev, s.input) { recompute_decode(s) }
      when key.down?
        (s.input.at_bottom? && !ev.shift?) ? cross_pane(s, 1) : editor_motion(ev, s.input) { recompute_decode(s) }
      when editor_motion(ev, s.input) { recompute_decode(s) } then nil
      when key.delete?                                        then s.input.delete; recompute_decode(s)
      else
        if c && !ev.ctrl? && !ev.alt?
          s.input.insert(c)
          report_replaced(s.input.last_replaced)
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
      when key.home?  then s.input_home(selecting)
      when key.end?   then s.input_end(selecting)
      when c && !ev.ctrl? && !ev.alt? && !c.control?
        return false # x/y/c + Global breath → keymap (crack is `c` in read mode)
      end
      true
    end

    private def editor_motion(ev : Termisu::Event::Key, ed : TextArea, & : -> _) : Bool
      before = ed.edits
      return false unless ed.handle_motion_key(ev)
      yield if ed.edits != before
      true
    end

    # ---- PAYLOAD editor (always-insert; edits re-forge live) ----
    private def edit_payload(ev : Termisu::Event::Key, c : Char?) : Nil
      s = cur
      ed = s.payload
      key = ev.key
      case
      when ev.ctrl_z?                                   then ed.undo; recompute_forge(s)
      when key.enter?                                   then ed.insert_newline; recompute_forge(s)
      when ed.word_delete_key?(ev)                      then editor_motion(ev, ed) { recompute_forge(s) }
      when key.backspace?                               then ed.backspace; recompute_forge(s)
      when key.up?                                      then (ed.at_top? && !ev.shift?) ? cross_pane(s, -1) : editor_motion(ev, ed) { recompute_forge(s) }
      when key.down?                                    then (ed.at_bottom? && !ev.shift?) ? cross_pane(s, 1) : editor_motion(ev, ed) { recompute_forge(s) }
      when key.delete?                                  then ed.delete; recompute_forge(s)
      when editor_motion(ev, ed) { recompute_forge(s) } then nil
      else
        if c && !ev.ctrl? && !ev.alt?
          ed.insert(c)
          report_replaced(ed.last_replaced)
          ed.set_preedit("")
          recompute_forge(s)
        end
      end
    end

    # ---- SALT single-line field (OPTIONS pane) ----
    private def edit_salt(ev : Termisu::Event::Key, c : Char?) : Nil
      s = cur
      case ev.key
      when .up?   then cross_pane(s, -1)
      when .down? then cross_pane(s, 1)
      else
        text, cx, changed = line_field_key(ev, c, s.salt, s.salt_cx)
        s.salt = text
        s.salt_cx = cx
        if changed
          s.salt_pre = ""
          recompute_all(s)
        end
      end
    end

    # ---- SECRET single-line field ----
    private def edit_secret(ev : Termisu::Event::Key, c : Char?) : Nil
      s = cur
      case ev.key
      when .up?   then cross_pane(s, -1)
      when .down? then cross_pane(s, 1)
      else
        text, cx, changed = line_field_key(ev, c, s.secret, s.secret_cx)
        s.secret = text
        s.secret_cx = cx
        if changed
          s.secret_pre = ""
          on_secret_edit(s)
        end
      end
    end

    # One printable-key step over a single-line field: `{new_text, new_caret, changed?}`. The
    # SALT and SECRET fields differ only in the field triplet and their recompute callback, so
    # the cursor arithmetic (left/right/home/end/backspace/insert) is stated once here; up/down
    # cross panes and are handled by the caller before this. `changed?` gates the recompute.
    private def line_field_key(ev : Termisu::Event::Key, c : Char?, text : String, cx : Int32) : {String, Int32, Bool}
      key = ev.key
      case
      when key.left?  then {text, {cx - 1, 0}.max, false}
      when key.right? then {text, {cx + 1, text.size}.min, false}
      when key.home?  then {text, 0, false}
      when key.end?   then {text, text.size, false}
      when key.backspace?
        cx > 0 ? {text[0, cx - 1] + text[cx..], cx - 1, true} : {text, cx, false}
      else
        if c && !ev.ctrl? && !ev.alt? && !c.control?
          {text[0, cx] + c.to_s + text[cx..], cx + 1, true}
        else
          {text, cx, false}
        end
      end
    end

    # Editing the SECRET clears a stale crack note (the field no longer holds what cracked) and
    # re-runs the live verify + re-forge under the new key.
    private def on_secret_edit(s : CookieSession) : Nil
      s.crack_note = nil
      recompute_verify(s)
      recompute_forge(s)
    end

    # ---- read-only DECODED / OUTPUT panes ----
    private def handle_readonly(ev : Termisu::Event::Key, which : Symbol) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
      s = cur
      key = ev.key
      at_top = which == :decoded ? s.view.decoded_at_top? : s.view.output_at_top?
      at_bottom = which == :decoded ? s.view.decoded_at_bottom? : s.view.output_at_bottom?
      case
      when key.up?, key.lower_k?
        at_top ? cross_pane(s, -1) : scroll_pane(s, which, -1)
      when key.down?, key.lower_j?
        at_bottom ? cross_pane(s, 1) : scroll_pane(s, which, 1)
      when (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt? && !c.control?
        return false # y/c + Global breath → keymap
      end
      true
    end

    private def scroll_pane(s : CookieSession, which : Symbol, step : Int32) : Nil
      which == :decoded ? s.view.scroll_decoded(step) : s.view.scroll_output(step)
    end

    # --- focus ring ---
    private def panes(s : CookieSession) : Array(Symbol)
      s.mode == :decode ? DECODE_PANES : FORGE_PANES
    end

    private def cross_pane(s : CookieSession, dir : Int32) : Nil
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

    private def enter_pane(s : CookieSession, p : Symbol) : Nil
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

    # --- mouse drag + double-click (the editable TextArea only: INPUT in decode, PAYLOAD in forge) ---
    def supports_drag? : Bool
      true
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      ed, area, read = editor_at(rect, mx, my) || return
      ed.click_to_cursor(area, mx, my, selecting: true)
      read.try &.sync_to(ed, selecting: true)
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      ed, area, read = editor_at(rect, mx, my) || return false
      return read.select_word(ed, area, mx, my) if read
      ed.select_word_at(area, mx, my)
    end

    private def editor_at(rect : Rect, mx : Int32, my : Int32) : {TextArea, Rect, TextReadState?}?
      body = body_rect_below_filter(rect)
      s = cur
      if s.mode == :decode
        input_c, _, _, _ = s.view.decode_layout(body)
        return nil unless input_c.contains?(mx, my) && my > input_c.y
        {s.input, input_c.inset(1, 1), s.input_mode == InputMode::Insert ? nil : s.input_read}
      else
        pay_c, _, _, _ = s.view.forge_layout(body)
        return nil unless pay_c.contains?(mx, my) && my > pay_c.y
        {s.payload, pay_c.inset(1, 1), nil}
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      body = body_rect_below_filter(rect)
      s = cur
      if s.mode == :decode
        input_c, dec_c, opts_c, sec_c = s.view.decode_layout(body)
        if input_c.contains?(mx, my)
          enter_pane(s, :input)
          if Frame.mode_badge_hit(mx, my, input_c.y, input_c.right - 1, input_c.x + CookieView::INPUT_MIN_X,
               s.input_mode == InputMode::Insert)
            s.input_mode = s.input_mode == InputMode::Insert ? InputMode::Read : InputMode::Insert
            s.input_read.sync_from(s.input) if s.input_mode == InputMode::Read
          elsif s.view.lens_chip_hit(input_c, mx, my, :decode, lens_chord, s.input_mode == InputMode::Insert)
            toggle_mode
          elsif s.input_mode == InputMode::Insert
            s.input.click_to_cursor(input_c.inset(1, 1), mx, my)
          else
            s.input_read.click(s.input, input_c.inset(1, 1), mx, my)
          end
        elsif dec_c.contains?(mx, my)
          enter_pane(s, :decoded)
        elsif opts_c.contains?(mx, my)
          enter_pane(s, :opts)
          click_opts_badge(s, opts_c, mx, my)
        elsif sec_c.contains?(mx, my)
          enter_pane(s, :secret)
        end
      else
        pay_c, opts_c, sec_c, out_c = s.view.forge_layout(body)
        if pay_c.contains?(mx, my)
          enter_pane(s, :payload)
          if s.view.lens_chip_hit(pay_c, mx, my, :forge, lens_chord)
            toggle_mode
          else
            s.payload.click_to_cursor(pay_c.inset(1, 1), mx, my)
          end
        elsif opts_c.contains?(mx, my)
          enter_pane(s, :opts)
          click_opts_badge(s, opts_c, mx, my)
        elsif sec_c.contains?(mx, my)
          enter_pane(s, :secret)
        elsif out_c.contains?(mx, my)
          enter_pane(s, :output)
        end
      end
      true
    end

    private def click_opts_badge(s : CookieSession, opts_c : Rect, mx : Int32, my : Int32) : Nil
      case s.view.opts_badge_hit(opts_c, mx, my, display_format(s), effective_format(s),
        effective_algorithm(s), salt_preset_label(s))
      when :format    then cycle_format
      when :algorithm then cycle_algorithm
      when :salt      then cycle_salt_preset
      end
    end

    def handle_wheel(step : Int32) : Bool
      s = cur
      case s.pane
      when :decoded then s.view.scroll_decoded(step)
      when :output  then s.view.scroll_output(step)
      when :input   then s.input.scroll_view(step)
      when :payload then s.payload.scroll_view(step)
      end
      true
    end

    def set_preedit(text : String) : Bool
      s = cur
      case s.pane
      when :input   then s.input.set_preedit(text) if s.input_mode == InputMode::Insert
      when :payload then s.payload.set_preedit(text)
      when :opts    then s.salt_pre = text
      when :secret  then s.secret_pre = text
      else               nil
      end
      true
    end

    # --- verbs / actions ---
    def toggle_mode : Nil
      s = cur
      if s.mode == :decode
        s.mode = :forge
        s.pane = :payload
        recompute_forge(s)
      else
        s.mode = :decode
        s.pane = :input
      end
      @host.status(s.mode == :forge ? "FORGE lens" : "DECODE lens")
    end

    def cycle_format : Nil
      s = cur
      list = s.mode == :forge ? FORGE_FORMATS : DECODE_FORMATS
      # Step from what the OPTIONS badge actually shows: in FORGE that is the resolved concrete
      # format (never `auto`), so `^A` advances from there rather than jumping to Flask. `auto`
      # is not in FORGE_FORMATS, so a first `^A` in FORGE lands on the next real format.
      i = list.index(display_format(s)) || -1
      s.format = list[(i + 1) % list.size]
      recompute_all(s)
      @host.status("format = #{s.format}")
    end

    def cycle_algorithm : Nil
      s = cur
      # Step from what is CURRENTLY in effect — the inferred algorithm when it was auto, so the
      # first cycle moves off the detected one rather than jumping back to the sha256 default —
      # and pin the choice so detection no longer overrides it.
      i = ALGORITHMS.index(effective_algorithm(s)) || 0
      s.algorithm = ALGORITHMS[(i + 1) % ALGORITHMS.size]
      s.algorithm_pinned = true
      recompute_all(s)
      @host.status(effective_format(s) == "django" ? "algorithm = #{s.algorithm}" : "algorithm = #{s.algorithm} (Django only)")
    end

    # Flip the Django salt field between the session-backend salt and the generic signing salt.
    # A Django `sessionid` cookie — the "crack the key, forge an admin session" target — signs
    # under SESSION_SALT, NOT the default `django.core.signing`, so a blank field silently
    # verifies/forges under the wrong salt and the correct secret reads as ✗ bad key. This writes
    # the CONCRETE salt string into the field so decode/verify/crack/forge all sign under the
    # salt the badge names. Django only (Flask's salt is fixed; Rack has none).
    def cycle_salt_preset : Nil
      s = cur
      unless effective_format(s) == "django"
        @host.status("salt presets are Django-only")
        return
      end
      s.salt = s.salt.strip == Cookie::Django::SESSION_SALT ? Cookie::Django::DEFAULT_SALT : Cookie::Django::SESSION_SALT
      s.salt_cx = s.salt.size
      s.salt_pre = ""
      recompute_all(s)
      @host.status("salt = #{salt_preset_label(s)} (#{s.salt})")
    end

    # The salt badge's label: which canonical Django salt is in effect. A blank field signs under
    # the signing default, so it reads "signing"; a hand-typed salt that is neither canonical one
    # reads "custom".
    def salt_preset_label(s : CookieSession) : String
      case s.salt.strip
      when Cookie::Django::SESSION_SALT     then "session"
      when "", Cookie::Django::DEFAULT_SALT then "signing"
      else                                       "custom"
      end
    end

    # Crack the signing secret over the SECRET field, read as a wordlist SOURCE: a path to an
    # existing file is a wordlist, anything else is a comma-separated inline candidate list (a
    # lone secret is a one-element list — the same verify, said as a crack). On success the
    # field is replaced with the winning secret and the verify state flips to ✓.
    def crack : Nil
      s = cur
      # Cracks the DECODE INPUT cookie, so it runs from the DECODE lens only — `c` reaches here
      # from the FORGE OUTPUT pane too (both are read panes), where cracking the hidden input and
      # swapping out the secret the OUTPUT is signed under would be an invisible side effect.
      unless s.mode == :decode
        @host.status("crack runs from the DECODE lens")
        return
      end
      token = s.input.text.strip
      if token.empty?
        @host.status("INPUT is empty — paste a cookie to crack")
        return
      end
      spec = s.secret.strip
      if spec.empty?
        @host.status("SECRET is empty — enter a wordlist path or a comma-separated candidate list")
        return
      end
      source = crack_source(spec)
      found = Cookie.crack(token, source, decode_format(s), salt: effective_salt(s), algorithm: effective_algorithm(s))
      if found
        s.secret = found
        s.secret_cx = found.size
        s.crack_note = "cracked: #{found.size > 24 ? found[0, 23] + "…" : found}"
        recompute_verify(s)
        recompute_forge(s)
        @host.status("cracked the signing secret")
      else
        # No `source.size` here: for a WordlistFile that re-reads the whole file just to print a
        # count, doubling the I/O of the crack that already scanned it.
        s.crack_note = nil
        @host.status("no candidate verified")
      end
    rescue ex : Gori::Error
      @host.status("crack: #{ex.message}")
    end

    # A file path → a lazily-read wordlist; anything else → the comma-split inline list. A path
    # that does not exist is treated as a one/many-element inline candidate list, not an error:
    # a bare secret typed into the field must still crack (as itself).
    private def crack_source(spec : String) : Fuzz::PayloadSource
      return Fuzz::WordlistFile.new(spec) if File.file?(spec)
      Fuzz::InlineList.new(spec.split(',').map(&.strip).reject(&.empty?))
    end

    # Seed the FORGE payload editor from the DECODE input's parsed payload + switch to FORGE.
    def load_decoded : Nil
      s = cur
      token = s.input.text.strip
      if token.empty?
        @host.status("INPUT is empty — nothing to load")
        return
      end
      begin
        doc = JSON.parse(Cookie.decode_json(token, decode_format(s)))
      rescue
        @host.status("INPUT is not a decodable cookie")
        return
      end
      fmt = doc["format"]?.try(&.as_s?)
      s.format = fmt if fmt && FORGE_FORMATS.includes?(fmt)
      if effective_format(s) == "rack"
        s.payload.set_text(doc["value_base64"]?.try(&.as_s?) || "")
      elsif (pl = doc["payload"]?) && !pl.raw.nil?
        s.payload.set_text(pl.to_pretty_json)
      else
        s.payload.set_text("")
      end
      s.mode = :forge
      s.pane = :payload
      recompute_forge(s)
      @host.status("loaded decoded payload into FORGE")
    end

    def clear_all : Nil
      s = cur
      s.input.set_text("")
      s.payload.set_text("")
      s.secret = ""
      s.secret_cx = 0
      s.salt = ""
      s.salt_cx = 0
      s.crack_note = nil
      recompute_decode(s)
      recompute_forge(s)
      @host.status("cleared")
    end

    # Copy the OUTPUT (forged) cookie.
    def cookie_copy_output : Nil
      s = cur
      if s.output_ok? && !s.output.empty?
        do_copy(s.output, "cookie")
      else
        @host.status("no valid cookie to copy")
      end
    end

    # The unified Copy verb: the selection if one is live, else the focused pane's content.
    def cookie_copy : Nil
      do_copy(cookie_copy_text)
    end

    def cookie_copy_text : String
      s = cur
      case s.pane
      when :input   then s.input_mode == InputMode::Read ? read_or_all(s.input_read, s.input) : band_or_all(s.input)
      when :payload then band_or_all(s.payload)
      when :opts    then s.salt
      when :secret  then s.secret
      when :decoded then s.decoded
      when :output  then s.output_ok? ? s.output : ""
      else               ""
      end
    end

    def cookie_copy_all : Nil
      cookie_copy
    end

    private def band_or_all(ed : TextArea) : String
      ed.selection_text || ed.text
    end

    private def read_or_all(read : TextReadState, ed : TextArea) : String
      read.selection? ? read.copy_text(ed) : read.copy_all(ed)
    end

    private def do_copy(text : String, label : String? = nil) : Nil
      if text.empty?
        @host.status("nothing to copy")
      else
        written = Clipboard.copy(text)
        prefix = label ? "copied \"#{label}\"" : "copied"
        @host.status("#{prefix} (#{written}b)#{Clipboard.note(written, text)}")
      end
    end

    # --- selection (for the "Send selection to" flow + copy verbs) ---
    def cookie_read_mode? : Bool
      s = cur
      s.pane == :decoded || s.pane == :output ||
        (s.pane == :input && s.input_mode == InputMode::Read)
    end

    # The FORGE payload pane too — see `JwtController#jwt_selection_active?` for why the
    # always-typing panes must report the band their copy already reads.
    def cookie_selection_active? : Bool
      s = cur
      case s.pane
      when :input   then s.input_mode == InputMode::Insert ? s.input.selection? : s.input_read.selection?
      when :payload then s.payload.selection?
      else               false
      end
    end

    def cookie_selection_text : String
      s = cur
      case s.pane
      when :input
        if s.input_mode == InputMode::Insert
          s.input.selection_text || s.input_read.copy_text(s.input)
        else
          s.input_read.copy_text(s.input)
        end
      when :decoded then s.decoded
      when :output  then s.output_ok? ? s.output : ""
      else               ""
      end
    end

    def cookie_select_line : Nil
      s = cur
      s.input_read.select_line(s.input) if s.pane == :input && s.input_mode == InputMode::Read
    end

    def cookie_clear_selection : Nil
      s = cur
      return unless s.pane == :input
      s.input_mode == InputMode::Insert ? s.input.clear_selection : s.input_read.clear_selection
    end

    def body_hint(focus : Symbol) : String
      s = cur
      reg = @host.session.registry
      ov = Hotkeys.rebindable_overrides(reg)
      y = Hotkeys.binding_label(reg, "cookie.copy", "y", ov)
      lens = lens_chord(reg, ov)
      case s.pane
      when :input
        if s.input_mode == InputMode::Insert
          keys("type a cookie · ⇧arrows select · ^Y copy · esc read · ↓ decoded · #{lens} forge · {cookie.cycle-format} format · {cookie.clear} clear · ↑ sub-tabs")
        else
          keys("i/↵ edit · {cookie.crack} crack · #{y} copy · space cmds · ↓ decoded · #{lens} forge · {cookie.cycle-format} format · ^N new · esc sub-tabs")
        end
      when :decoded
        keys("↑/↓ scroll · {cookie.crack} crack · #{y} copy · space cmds · ↑-top input · ↓ options · #{lens} forge · esc sub-tabs")
      when :opts
        if effective_format(s) == "django"
          keys("type salt · salt:#{salt_preset_label(s)} (click/space) · {cookie.cycle-format} format · algo #{effective_algorithm(s)} · ↑/↓ cross · #{lens} forge · esc sub-tabs")
        else
          keys("type salt · {cookie.cycle-format} format · ↑/↓ cross · #{lens} forge · esc sub-tabs")
        end
      when :secret
        keys("type secret · ^Y copy · {cookie.cycle-format} format · ↑/↓ cross · #{lens} forge · esc sub-tabs")
      when :payload
        keys("type payload · ⇧arrows select · ^Y copy · ↑/↓ move+cross · {cookie.cycle-format} format · #{lens} decode · esc sub-tabs")
      when :output
        keys("↑/↓ scroll · #{y} copy cookie · space cmds · {cookie.cycle-format} format · #{lens} decode · esc sub-tabs")
      else
        ""
      end
    end

    def on_enter : Nil
      # Nothing to recompute on enter — caches stay valid across tab switches.
    end

    # Ephemeral scratch tool: sessions live in memory only (no settings persistence), so commit
    # is a no-op. Kept for the TabController contract + the runner's commit call sites.
    def commit : Nil
    end

    # --- recompute ---
    # The format passed to the decode/verify/crack engine: nil (auto-detect) unless the operator
    # pinned one.
    private def decode_format(s : CookieSession) : String?
      s.format == "auto" ? nil : s.format
    end

    # The concrete format for FORGE, resolving `auto` through detection (Flask as the fallback).
    private def effective_format(s : CookieSession) : String
      s.format == "auto" ? (s.detected || "flask") : s.format
    end

    # The format the OPTIONS badge shows and a click/cycle acts on: the pinned one in DECODE
    # (which may be `auto`), the resolved concrete one in FORGE — since FORGE cannot mint under
    # `auto`. `s.format` itself stays `auto`, so toggling back to DECODE and pasting a different
    # framework's cookie still auto-detects rather than being decoded under a format FORGE pinned.
    private def display_format(s : CookieSession) : String
      s.mode == :forge ? effective_format(s) : s.format
    end

    private def effective_salt(s : CookieSession) : String?
      t = s.salt.strip
      t.empty? ? nil : t
    end

    # The Django HMAC algorithm the engine actually verifies/signs under: the operator's pinned
    # choice once they cycle it, otherwise inferred from the INPUT cookie's signature length
    # (sha1 = 20 raw bytes, sha256 = 32 — unambiguous). This closes the sibling of the salt trap
    # ([[cookie-tab-session-salt-trap]]): a genuine SHA-1 `sessionid` would otherwise read as
    # ✗ bad key under the SHA-256 default even with the correct secret. Non-Django and a pinned
    # choice both fall straight through to the stored value; an undetectable cookie keeps it too.
    private def effective_algorithm(s : CookieSession) : String
      return s.algorithm if s.algorithm_pinned? || effective_format(s) != "django"
      detect_django_algo(s.input.text.strip) || s.algorithm
    end

    # sha1 / sha256 read off the byte length of a Django cookie's signature segment, or nil when
    # the cookie is not a parseable 3-part Django token or the signature is some other length.
    private def detect_django_algo(token : String) : String?
      parts = token.split(':')
      return nil unless parts.size == 3
      case Cookie.b64decode(parts[2]).size
      when 20 then "sha1"
      when 32 then "sha256"
      else         nil
      end
    rescue Cookie::CookieError
      nil
    end

    private def recompute_all(s : CookieSession) : Nil
      recompute_decode(s)
      recompute_forge(s)
    end

    private def recompute_decode(s : CookieSession) : Nil
      token = s.input.text.strip
      s.detected = token.empty? ? nil : Cookie.detect(token)
      s.decoded = decode_text(token, decode_format(s))
      recompute_verify(s)
      s.view.reset_decoded_scroll
    end

    private def decode_text(token : String, format : String?) : String
      return "" if token.empty?
      Cookie.decode(token, format)
    rescue ex
      "// #{ex.message}"
    end

    private def recompute_verify(s : CookieSession) : Nil
      token = s.input.text.strip
      if token.empty? || s.secret.empty?
        s.verify_state = :none
        s.crack_note = nil
        return
      end
      ok = Cookie.verify(token, s.secret, decode_format(s), salt: effective_salt(s), algorithm: effective_algorithm(s))
      s.verify_state = ok ? :ok : :bad
      # A green "cracked" verdict cannot outlive a failing verify: changing the INPUT cookie, the
      # salt, the format or the algorithm re-runs this, and if the cracked key no longer signs
      # the cookie the card must say "✗ bad key", not keep showing the stale crack result.
      s.crack_note = nil unless ok
    end

    private def recompute_forge(s : CookieSession) : Nil
      body = s.payload.text
      if body.strip.empty?
        s.output = ""
        s.output_ok = true
        s.view.reset_output_scroll
        return
      end
      begin
        s.output = forge_cookie(s, body)
        s.output_ok = true
      rescue ex : Cookie::CookieError
        s.output = ex.message || "invalid input"
        s.output_ok = false
      rescue ex : JSON::ParseException
        s.output = "payload is not valid JSON"
        s.output_ok = false
      end
      s.view.reset_output_scroll
    end

    private def forge_cookie(s : CookieSession, body : String) : String
      ts = Time.utc.to_unix
      salt = effective_salt(s)
      case effective_format(s)
      when "rack"
        Cookie::Rack.forge(body.strip, s.secret)
      when "django"
        Cookie::Django.forge(body, s.secret, ts,
          salt: salt || Cookie::Django::DEFAULT_SALT, algorithm: effective_algorithm(s))
      else # flask
        Cookie::Flask.forge(body, s.secret, ts, salt: salt || Cookie::Flask::SALT)
      end
    end
  end
end
