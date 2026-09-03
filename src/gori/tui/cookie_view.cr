require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "./input_mode"
require "./text_read_state"
require "./viewport"
require "../cookie"
require "./subtab_marks"

module Gori::Tui
  # The Cookie tab's renderer — the JWT tab's sibling for framework signed SESSION cookies
  # (Flask/itsdangerous, Rack, Django). Two lenses over one session, toggled by the controller:
  #   DECODE — INPUT editor (raw cookie) → DECODED (parsed parts) → OPTIONS (format / algorithm
  #            / salt) → SECRET (a candidate key + its live verify state; `c` cracks a wordlist).
  #   FORGE  — PAYLOAD editor (session JSON, or the Rack base64 value) → OPTIONS → SECRET →
  #            OUTPUT (the live re-signed cookie).
  # A pure renderer + layout math + read-only scroll state; the controller owns the editable
  # buffers and the cached decode / verify / forge results (recomputed on edit, never on the
  # render hot path). Modelled column-for-column on JwtView.
  class CookieView
    include SubtabRef # a sub-tab strip may hold a mark on this view (#683)
    # Custom sub-tab chip label (nil = derive from the detected format); set by rename.
    property name : String? = nil

    OPTS_H   = 3 # OPTIONS: a fixed single-line salt field, framed top + bottom (badges on border).
    SECRET_H = 3 # SECRET: a fixed single-line key field (verify state on the border).

    # Left stops for the top card's border chrome, mirroring JwtView's INPUT_MIN_X reasoning:
    # `Frame.card` draws ` TITLE ` from card.x + 2, so ` INPUT ` ends at card.x + 8 and
    # ` PAYLOAD ` at card.x + 9 — one past each is where a right-chained badge may start.
    INPUT_MIN_X   =  9
    PAYLOAD_MIN_X = 11
    OPTS_MIN_X    = 11 # past ` OPTIONS `
    SECRET_MIN_X  = 10 # past ` SECRET `

    @dec_scroll : Int32 = 0
    @dec_h : Int32 = 0
    @dec_lines : Int32 = 0
    @out_scroll : Int32 = 0
    @out_h : Int32 = 0
    @out_lines : Int32 = 0

    # ---- DECODE lens layout: INPUT + DECODED + OPTIONS (fixed) + SECRET (fixed) ----
    def decode_layout(rect : Rect) : {Rect, Rect, Rect, Rect}
      empty = Rect.new(rect.x, rect.y, 0, 0)
      return {empty, empty, empty, rect} if rect.h < 12 || rect.w < 2
      rest = rect.h - OPTS_H - SECRET_H
      input_h = (rest * 32 // 100).clamp(3, rest - 3)
      dec_h = rest - input_h
      y = rect.y
      input = Rect.new(rect.x, y, rect.w, input_h); y += input_h
      dec = Rect.new(rect.x, y, rect.w, dec_h); y += dec_h
      opts = Rect.new(rect.x, y, rect.w, OPTS_H); y += OPTS_H
      sec = Rect.new(rect.x, y, rect.w, SECRET_H)
      {input, dec, opts, sec}
    end

    # ---- FORGE lens layout: PAYLOAD + OPTIONS (fixed) + SECRET (fixed) + OUTPUT ----
    def forge_layout(rect : Rect) : {Rect, Rect, Rect, Rect}
      empty = Rect.new(rect.x, rect.y, 0, 0)
      return {empty, empty, empty, rect} if rect.h < 12 || rect.w < 2
      rest = rect.h - OPTS_H - SECRET_H
      pay_h = (rest * 45 // 100).clamp(3, rest - 3)
      out_h = rest - pay_h
      y = rect.y
      pay = Rect.new(rect.x, y, rect.w, pay_h); y += pay_h
      opts = Rect.new(rect.x, y, rect.w, OPTS_H); y += OPTS_H
      sec = Rect.new(rect.x, y, rect.w, SECRET_H); y += SECRET_H
      out = Rect.new(rect.x, y, rect.w, out_h)
      {pay, opts, sec, out}
    end

    # ===================== DECODE lens =====================
    def render_decode(screen : Screen, rect : Rect, *, input : TextArea, input_mode : InputMode,
                      input_read : TextReadState, decoded : String, format : String,
                      resolved_format : String, algorithm : String, salt : String, salt_cx : Int32,
                      salt_pre : String, salt_preset : String, verify_state : Symbol,
                      crack_note : String?, secret : String, secret_cx : Int32,
                      secret_pre : String, pane : Symbol, focused : Bool, lens_chord : String) : Nil
      return if rect.empty?
      input_c, dec_c, opts_c, sec_c = decode_layout(rect)

      render_input(screen, input_c, input, focused && pane == :input, input_mode, input_read, lens_chord) unless input_c.empty?
      unless dec_c.empty?
        lines = decoded_lines(decoded)
        @dec_lines = lines.size
        @dec_h, @dec_scroll = draw_text_card(screen, dec_c, "DECODED", lines, @dec_scroll, focused && pane == :decoded)
      end
      render_opts(screen, opts_c, format, resolved_format, algorithm, salt, salt_cx, salt_pre, salt_preset, focused && pane == :opts) unless opts_c.empty?
      render_secret(screen, sec_c, secret, secret_cx, secret_pre, verify_state, crack_note, focused && pane == :secret) unless sec_c.empty?
    end

    # ===================== FORGE lens =====================
    def render_forge(screen : Screen, rect : Rect, *, payload : TextArea, format : String,
                     resolved_format : String, algorithm : String, salt : String, salt_cx : Int32,
                     salt_pre : String, salt_preset : String, secret : String, secret_cx : Int32,
                     secret_pre : String, output : String, output_ok : Bool, pane : Symbol,
                     focused : Bool, lens_chord : String) : Nil
      return if rect.empty?
      pay_c, opts_c, sec_c, out_c = forge_layout(rect)

      unless pay_c.empty?
        render_payload(screen, pay_c, payload, format, focused && pane == :payload)
        # PAYLOAD is this lens' top card, so it carries the way back — see draw_lens_chip.
        draw_lens_chip(screen, pay_c, :forge, lens_chord)
      end
      render_opts(screen, opts_c, format, resolved_format, algorithm, salt, salt_cx, salt_pre, salt_preset, focused && pane == :opts) unless opts_c.empty?
      render_secret(screen, sec_c, secret, secret_cx, secret_pre, :none, nil, focused && pane == :secret) unless sec_c.empty?
      unless out_c.empty?
        out_lines = output_ok ? output.split('\n') : ["✗ #{output}"]
        @out_lines = out_lines.size
        @out_h, @out_scroll = draw_text_card(screen, out_c, "OUTPUT", out_lines, @out_scroll,
          focused && pane == :output, fg: output_ok ? Theme.text : Theme.red)
      end
    end

    # ---- INPUT (editable cookie string, INS/READ like the JWT input) ----
    private def render_input(screen : Screen, card : Rect, input : TextArea, active : Bool,
                             mode : InputMode, read : TextReadState, lens_chord : String) : Nil
      reading = active && mode == InputMode::Read
      insert = active && mode == InputMode::Insert
      Frame.card(screen, card, "INPUT", bg: Theme.bg, border: Frame.pane_border(active))
      # `mode`, not `insert` — a live 8-cell badge must sit on the pane's own mode even when
      # focus is elsewhere (see the note in JwtView#render_input).
      Frame.mode_badge(screen, card.right - 1, card.y, card.x + INPUT_MIN_X, mode == InputMode::Insert)
      draw_lens_chip(screen, card, :decode, lens_chord, mode == InputMode::Insert)
      body = card.inset(1, 1)
      input.render(screen, body, cursor: insert, gauge: true, gauge_focused: active)
      paint_read_chrome(screen, body, input, read) if reading
    end

    # ---- PAYLOAD (editable JSON / Rack base64 value; always-insert) ----
    private def render_payload(screen : Screen, card : Rect, ed : TextArea, format : String, active : Bool) : Nil
      # Flask/Django sign a JSON session; Rack signs an opaque base64 Marshal blob. The title
      # says which so a paste into the wrong shape is caught before FORGE, not after.
      title = format == "rack" ? "VALUE (base64)" : "PAYLOAD (json)"
      hl = format == "rack" ? nil : :json
      Frame.card(screen, card, title, bg: Theme.bg, border: Frame.pane_border(active))
      ed.render(screen, card.inset(1, 1), cursor: active, highlight: hl, gauge: true, gauge_focused: active)
    end

    # ---- the lens chip (` ^T:→FORGE ` / ` ^T:→DECODE `), the tab's one traceless control ----
    # See JwtView#draw_lens_chip for the reasoning; identical geometry, different target names.
    private def lens_name(mode : Symbol) : String
      mode == :decode ? "→FORGE" : "→DECODE"
    end

    private def lens_chip_geom(card : Rect, mode : Symbol, insert : Bool) : {Int32, Int32}
      if mode == :decode
        min_x = card.x + INPUT_MIN_X
        {Frame.mode_badge_edge(card.right - 1, min_x, insert), min_x}
      else
        {card.right - 1, card.x + PAYLOAD_MIN_X}
      end
    end

    private def draw_lens_chip(screen : Screen, card : Rect, mode : Symbol, chord : String,
                               insert : Bool = false) : Nil
      edge, min_x = lens_chip_geom(card, mode, insert)
      Frame.toggle_badge(screen, edge, card.y, min_x, chord, lens_name(mode), false)
    end

    def lens_chip_hit(card : Rect, mx : Int32, my : Int32, mode : Symbol, chord : String,
                      insert : Bool = false) : Bool
      edge, min_x = lens_chip_geom(card, mode, insert)
      !Frame.right_badge_hit(mx, my, card.y, edge, min_x,
        [{:lens, chord, lens_name(mode)}] of {Symbol, String, String}).nil?
    end

    # ---- OPTIONS card: format / algorithm badges on the border + a salt field ----
    # `format` cycles with ^A (auto/flask/rack/django). `algorithm` has no chord — `^G` is the
    # shell's go-to-line key, so this badge is click-only (also the space-menu verb + palette),
    # and it wears `algo:` rather than a `^`-chord so it never advertises a key that would not
    # fire. Django only. SALT is the framework signing salt — meaningful for Flask/Django, inert
    # for Rack. The badges chain from the right edge like the JWT SECRET card's ` ^A:alg `.
    # `format` is the DISPLAY format (drives the ^A badge label — may read `auto`); `resolved`
    # is the concrete format the engine actually uses (auto → detected), so the Django-only
    # `algo`/`salt` badges and the salt-field wording appear even while the pin stays `auto`.
    private def render_opts(screen : Screen, card : Rect, format : String, resolved : String,
                            algorithm : String, salt : String, cx : Int32, pre : String,
                            salt_preset : String, active : Bool) : Nil
      Frame.card(screen, card, "OPTIONS", bg: Theme.bg, border: Frame.pane_border(active))
      min_x = card.x + OPTS_MIN_X
      # ^A:format — always lit (there is always a format in play).
      fx = Frame.toggle_badge(screen, card.right - 1, card.y, min_x, "^A", format, true)
      # algo:<hmac> then salt:<preset> — click-only chips chained left, drawn only for Django.
      if resolved == "django"
        ax = Frame.toggle_badge(screen, fx, card.y, min_x, "algo", algorithm, true)
        Frame.toggle_badge(screen, ax, card.y, min_x, "salt", salt_preset, true)
      end
      c = card.inset(1, 1)
      return if c.h <= 0
      screen.text(c.x, c.y, "salt ", Theme.accent, Theme.bg)
      vw = {c.w - 5, 1}.max
      fg = active ? Theme.text_bright : Theme.text
      if resolved == "rack"
        screen.text(c.x + 5, c.y, "(rack cookies have no salt)", Theme.muted, Theme.bg, width: vw)
      elsif active
        screen.input_line(c.x + 5, c.y, salt, cx, pre, fg, Theme.bg, width: vw)
      elsif salt.empty?
        screen.text(c.x + 5, c.y, salt_placeholder(resolved), Theme.muted, Theme.bg, width: vw)
      else
        screen.text(c.x + 5, c.y, salt, fg, Theme.bg, width: vw)
      end
    end

    # The salt a blank field signs under — the framework default, shown muted so the operator
    # knows what is in effect without typing it. A Django SESSION cookie needs SESSION_SALT, so
    # the Django hint names the `salt` badge as the way to it rather than implying the generic
    # signing salt is always right.
    private def salt_placeholder(format : String) : String
      case format
      when "flask"  then "(default: #{Cookie::Flask::SALT})"
      when "django" then "(blank = #{Cookie::Django::DEFAULT_SALT}; salt badge → session)"
      else               "(default salt)"
      end
    end

    # Hit-test the OPTIONS badges. Returns :format, :algorithm, :salt, or nil. `resolved` decides
    # whether the algorithm + salt badges were drawn at all (Django only), so the chain is built
    # to match render; `format` (display) is the ^A label whose WIDTH positions the rest.
    def opts_badge_hit(card : Rect, mx : Int32, my : Int32, format : String, resolved : String,
                       algorithm : String, salt_preset : String) : Symbol?
      badges = [{:format, "^A", format}] of {Symbol, String, String}
      if resolved == "django"
        badges << {:algorithm, "algo", algorithm}
        badges << {:salt, "salt", salt_preset}
      end
      Frame.right_badge_hit(mx, my, card.y, card.right - 1, card.x + OPTS_MIN_X, badges)
    end

    # ---- SECRET single-line field + verify state on the border ----
    private def render_secret(screen : Screen, card : Rect, secret : String, cx : Int32,
                              pre : String, verify_state : Symbol, crack_note : String?, active : Bool) : Nil
      Frame.card(screen, card, "SECRET", bg: Theme.bg, border: Frame.pane_border(active))
      # State on the border: the crack result if one is fresh, else the live verify verdict.
      meta, mfg = secret_meta(verify_state, crack_note, secret)
      Frame.border_meta(screen, card, "SECRET", meta, fg: mfg) unless meta.empty?
      c = card.inset(1, 1)
      return if c.h <= 0
      screen.text(c.x, c.y, "› ", Theme.accent, Theme.bg)
      fg = active ? Theme.text_bright : Theme.text
      vw = {c.w - 2, 1}.max
      if active
        screen.input_line(c.x + 2, c.y, secret, cx, pre, fg, Theme.bg, width: vw)
      else
        screen.text(c.x + 2, c.y, secret.empty? ? "(candidate key — c cracks a wordlist)" : secret,
          secret.empty? ? Theme.muted : fg, Theme.bg, width: vw)
      end
    end

    private def secret_meta(verify_state : Symbol, crack_note : String?, secret : String) : {String, Color}
      return {crack_note, Theme.green} if crack_note && !crack_note.empty?
      case verify_state
      when :ok  then {"✓ verified", Theme.green}
      when :bad then {"✗ bad key", Theme.red}
      else           {"", Theme.muted}
      end
    end

    # ---- read-only scrollable text card (DECODED / OUTPUT) — copied from JwtView ----
    private def draw_text_card(screen : Screen, card : Rect, title : String, lines : Array(String),
                               scroll : Int32, focused : Bool, fg : Color = Theme.text) : {Int32, Int32}
      Frame.card(screen, card, title, bg: Theme.bg, border: Frame.pane_border(focused))
      body = card.inset(1, 1)
      return {0, scroll} if body.h <= 0
      top = scroll.clamp(0, {lines.size - body.h, 0}.max)
      (0...body.h).each do |i|
        line = lines[top + i]?
        break unless line
        # muted `// format:` comment markers from Cookie.decode, red WARNING lines.
        lfg = line.starts_with?("//") ? (line.includes?("WARNING") ? Theme.red : Theme.muted) : fg
        screen.text(body.x, body.y + i, line, lfg, Theme.bg, width: body.w)
      end
      Frame.scroll_gauge(screen, body, lines.size, top, focused)
      {body.h, top}
    end

    private def decoded_lines(decoded : String) : Array(String)
      decoded.empty? ? ["(paste or send a signed session cookie into INPUT to decode)"] : decoded.split('\n')
    end

    private def paint_read_chrome(screen : Screen, rect : Rect, ed : TextArea, read : TextReadState) : Nil
      read.paint_chrome(screen, rect, ed)
    end

    # ---- scroll mutators (called by the controller) ----
    def scroll_decoded(step : Int32) : Nil
      @dec_scroll = {@dec_scroll + step, 0}.max
    end

    def scroll_output(step : Int32) : Nil
      @out_scroll = {@out_scroll + step, 0}.max
    end

    def decoded_at_top? : Bool
      @dec_scroll <= 0
    end

    def decoded_at_bottom? : Bool
      return true if @dec_h <= 0
      @dec_scroll >= {@dec_lines - @dec_h, 0}.max
    end

    def output_at_top? : Bool
      @out_scroll <= 0
    end

    def output_at_bottom? : Bool
      return true if @out_h <= 0
      @out_scroll >= {@out_lines - @out_h, 0}.max
    end

    def reset_decoded_scroll : Nil
      @dec_scroll = 0
    end

    def reset_output_scroll : Nil
      @out_scroll = 0
    end
  end
end
