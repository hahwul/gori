require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "./input_mode"
require "./text_read_state"
require "./gutter"
require "../jwt"

module Gori::Tui
  # The JWT tab's renderer. Two lenses over one session, toggled by the controller:
  #   DECODE — INPUT editor (raw token) → DECODED (live header/payload/sig) → ATTACKS
  #            (the generated testing payloads, one selectable row each).
  #   ENCODE — HEADER + PAYLOAD JSON editors → SECRET field (+ alg badge) → OUTPUT
  #            (the live re-signed token).
  # A pure renderer + layout math + read-only scroll / attack-selection state; the
  # controller owns the editable buffers and the cached decode/encode/attack results
  # (recomputed on edit, never on the render hot path).
  class JwtView
    # Custom sub-tab chip label (nil = derive from the token's alg); set by rename.
    property name : String? = nil

    SECRET_H = 3 # the SECRET card is a fixed single-line field, framed top + bottom.

    @dec_scroll : Int32 = 0
    @dec_h : Int32 = 0
    @dec_lines : Int32 = 0
    @out_scroll : Int32 = 0
    @out_h : Int32 = 0
    @out_lines : Int32 = 0
    @atk_sel : Int32 = 0
    @atk_scroll : Int32 = 0
    @atk_h : Int32 = 0

    # ---- DECODE lens layout: INPUT (fixed-ish) + DECODED + ATTACKS ----
    def decode_layout(rect : Rect) : {Rect, Rect, Rect}
      empty = Rect.new(rect.x, rect.y, 0, 0)
      return {empty, empty, rect} if rect.h < 9 || rect.w < 2
      input_h = (rect.h * 22 // 100).clamp(3, rect.h - 6)
      rest = rect.h - input_h
      dec_h = rest // 2
      atk_h = rest - dec_h
      y = rect.y
      input = Rect.new(rect.x, y, rect.w, input_h); y += input_h
      dec = Rect.new(rect.x, y, rect.w, dec_h); y += dec_h
      atk = Rect.new(rect.x, y, rect.w, atk_h)
      {input, dec, atk}
    end

    # ---- ENCODE lens layout: HEADER + PAYLOAD + SECRET (fixed) + OUTPUT ----
    def encode_layout(rect : Rect) : {Rect, Rect, Rect, Rect}
      empty = Rect.new(rect.x, rect.y, 0, 0)
      return {empty, empty, empty, rect} if rect.h < 12 || rect.w < 2
      rest = rect.h - SECRET_H
      hdr_h = (rest * 30 // 100).clamp(3, rest - 6)
      pay_h = (rest * 30 // 100).clamp(3, rest - hdr_h - 3)
      out_h = rest - hdr_h - pay_h
      y = rect.y
      hdr = Rect.new(rect.x, y, rect.w, hdr_h); y += hdr_h
      pay = Rect.new(rect.x, y, rect.w, pay_h); y += pay_h
      sec = Rect.new(rect.x, y, rect.w, SECRET_H); y += SECRET_H
      out = Rect.new(rect.x, y, rect.w, out_h)
      {hdr, pay, sec, out}
    end

    # ===================== DECODE lens =====================
    def render_decode(screen : Screen, rect : Rect, *, input : TextArea, input_mode : InputMode,
                      input_read : TextReadState, decoded : String, attacks : Array(Jwt::Attack),
                      pane : Symbol, focused : Bool) : Nil
      return if rect.empty?
      input_c, dec_c, atk_c = decode_layout(rect)

      render_input(screen, input_c, input, focused && pane == :input, input_mode, input_read) unless input_c.empty?
      unless dec_c.empty?
        lines = decoded_lines(decoded)
        @dec_lines = lines.size
        @dec_h, @dec_scroll = draw_text_card(screen, dec_c, "DECODED", lines, @dec_scroll, focused && pane == :decoded)
      end
      render_attacks(screen, atk_c, attacks, focused && pane == :attacks) unless atk_c.empty?
    end

    # ===================== ENCODE lens =====================
    def render_encode(screen : Screen, rect : Rect, *, header : TextArea, payload : TextArea,
                      secret : String, secret_cx : Int32, secret_pre : String, alg : String,
                      output : String, output_ok : Bool, pane : Symbol, focused : Bool) : Nil
      return if rect.empty?
      hdr_c, pay_c, sec_c, out_c = encode_layout(rect)

      render_json_editor(screen, hdr_c, "HEADER", header, focused && pane == :header) unless hdr_c.empty?
      render_json_editor(screen, pay_c, "PAYLOAD", payload, focused && pane == :payload) unless pay_c.empty?
      render_secret(screen, sec_c, secret, secret_cx, secret_pre, alg, focused && pane == :secret) unless sec_c.empty?
      unless out_c.empty?
        out_lines = output_ok ? output.split('\n') : ["✗ #{output}"]
        @out_lines = out_lines.size
        title = "OUTPUT#{output_ok ? "" : "  ✗ invalid JSON"}"
        @out_h, @out_scroll = draw_text_card(screen, out_c, title, out_lines, @out_scroll,
          focused && pane == :output, fg: output_ok ? Theme.text : Theme.red)
      end
    end

    # ---- INPUT (editable, INS/READ like the Decoder input) ----
    private def render_input(screen : Screen, card : Rect, input : TextArea, active : Bool,
                             mode : InputMode, read : TextReadState) : Nil
      reading = active && mode == InputMode::Read
      insert = active && mode == InputMode::Insert
      Frame.card(screen, card, "INPUT", bg: Theme.bg, border: Frame.pane_border(active))
      if active
        Frame.mode_badge(screen, card.right - 1, card.y, card.x + 8, insert)
      end
      body = card.inset(1, 1)
      input.render(screen, body, cursor: insert, gauge: true, gauge_focused: active)
      paint_read_chrome(screen, body, input, read) if reading
    end

    # ---- HEADER / PAYLOAD (editable JSON, always-insert small editors) ----
    private def render_json_editor(screen : Screen, card : Rect, title : String, ed : TextArea, active : Bool) : Nil
      Frame.card(screen, card, title, bg: Theme.bg, border: Frame.pane_border(active))
      ed.render(screen, card.inset(1, 1), cursor: active, highlight: :json, gauge: true, gauge_focused: active)
    end

    # ---- SECRET single-line field + alg badge ----
    private def render_secret(screen : Screen, card : Rect, secret : String, cx : Int32,
                              pre : String, alg : String, active : Bool) : Nil
      Frame.card(screen, card, "SECRET", bg: Theme.bg, border: Frame.pane_border(active))
      # ` ^A:ALG ` badge (cycled by jwt.cycle-alg) — lit when a real HS key matters.
      Frame.toggle_badge(screen, card.right - 1, card.y, card.x + 9, "^A", alg, alg != "none")
      c = card.inset(1, 1)
      return if c.h <= 0
      screen.text(c.x, c.y, "› ", Theme.accent, Theme.bg)
      fg = active ? Theme.text_bright : Theme.text
      vw = {c.w - 2, 1}.max
      if alg == "none"
        screen.text(c.x + 2, c.y, "(no secret — alg=none is unsigned)", Theme.muted, Theme.bg, width: vw)
      elsif active
        screen.input_line(c.x + 2, c.y, secret, cx, pre, fg, Theme.bg, width: vw)
      else
        screen.text(c.x + 2, c.y, secret.empty? ? "(empty key)" : secret, secret.empty? ? Theme.muted : fg, Theme.bg, width: vw)
      end
    end

    # ---- ATTACKS list (one selectable row per generated payload) ----
    private def render_attacks(screen : Screen, card : Rect, attacks : Array(Jwt::Attack), focused : Bool) : Nil
      Frame.card(screen, card, "ATTACKS · #{attacks.size}", bg: Theme.bg, border: Frame.pane_border(focused))
      body = card.inset(1, 1)
      return if body.h <= 0
      if attacks.empty?
        screen.text(body.x, body.y, "(paste a JWT into INPUT to generate testing payloads)", Theme.muted, Theme.bg, width: body.w)
        return
      end
      @atk_h = body.h
      @atk_sel = @atk_sel.clamp(0, attacks.size - 1)
      @atk_scroll = @atk_scroll.clamp(0, {attacks.size - body.h, 0}.max)
      @atk_scroll = @atk_sel if @atk_sel < @atk_scroll
      @atk_scroll = @atk_sel - body.h + 1 if @atk_sel >= @atk_scroll + body.h
      (0...body.h).each do |i|
        idx = @atk_scroll + i
        a = attacks[idx]?
        break unless a
        sel = focused && idx == @atk_sel
        y = body.y + i
        bg = sel ? Theme.accent_bg : Theme.bg
        screen.fill(Rect.new(body.x, y, body.w, 1), bg) if sel
        x = screen.text(body.x, y, sel ? "▎" : " ", Theme.accent, bg)
        x = screen.text(x, y, a.name, sel ? Theme.text_bright : Theme.text, bg, width: {body.w // 3, 8}.max)
        x = screen.text(x, y, "  ", Theme.muted, bg)
        screen.text(x, y, a.note, Theme.muted, bg, width: {body.right - x, 0}.max)
      end
      Frame.scroll_gauge(screen, body, attacks.size, @atk_scroll, focused)
    end

    # ---- read-only scrollable text card (DECODED / OUTPUT) ----
    # Returns {body_height, clamped_scroll} so the caller can persist the clamped scroll
    # (the mutators only floor at 0; the true upper bound is known here, at render).
    private def draw_text_card(screen : Screen, card : Rect, title : String, lines : Array(String),
                               scroll : Int32, focused : Bool, fg : Color = Theme.text) : {Int32, Int32}
      Frame.card(screen, card, title, bg: Theme.bg, border: Frame.pane_border(focused))
      body = card.inset(1, 1)
      return {0, scroll} if body.h <= 0
      top = scroll.clamp(0, {lines.size - body.h, 0}.max)
      (0...body.h).each do |i|
        line = lines[top + i]?
        break unless line
        # muted `// header` comment markers from jwt_decode, red WARNING lines.
        lfg = line.starts_with?("//") ? (line.includes?("WARNING") ? Theme.red : Theme.muted) : fg
        screen.text(body.x, body.y + i, line, lfg, Theme.bg, width: body.w)
      end
      Frame.scroll_gauge(screen, body, lines.size, top, focused)
      {body.h, top}
    end

    private def decoded_lines(decoded : String) : Array(String)
      decoded.empty? ? ["(paste or send a JWT into INPUT to decode)"] : decoded.split('\n')
    end

    private def paint_read_chrome(screen : Screen, rect : Rect, ed : TextArea, read : TextReadState) : Nil
      lines = ed.lines_snapshot
      return if lines.empty?
      scr = ed.scroll
      read.cursor.highlight_spans(lines).each do |(li, x0, x1)|
        next unless li >= scr && li < scr + rect.h
        paint_span_bg(screen, rect.x, rect.y + (li - scr), lines[li], x0, x1)
      end
      cy, cx = read.cursor.cy, read.cursor.cx
      return unless cy >= scr && cy < scr + rect.h
      line = lines[cy]
      px = rect.x + Screen.draw_width(line[0, cx.clamp(0, line.size)])
      return if px >= rect.x + rect.w
      ch = cx < line.size ? line[cx] : ' '
      screen.cell(px, rect.y + (cy - scr), ch, Theme.bg, Theme.accent_bg)
      screen.cursor(px, rect.y + (cy - scr))
    end

    private def paint_span_bg(screen : Screen, x : Int32, y : Int32, line : String, x0 : Int32, x1 : Int32) : Nil
      return if x0 >= x1
      # Cluster-wise, matching the base draw and the caret. Summing draw_width over single
      # CHARS is exactly the retired per-codepoint measure: it drifts right by each
      # cluster's inflation (1 column for a skin tone, 9 for a ZWJ family), and drawing
      # char-by-char also SHREDS a cluster across cells, stranding a bare combining mark in
      # one of its own. Span edges snap outward so the tint covers whole glyphs.
      a = Screen.cluster_start(line, {x0, line.size}.min)
      b = Screen.cluster_end(line, {x1, line.size}.min)
      px = x + Screen.draw_width(line[0, a])
      i = a
      while i < b
        e = Screen.cluster_end(line, i + 1)
        seg = line[i...e]
        screen.text(px, y, seg, Theme.text, Theme.accent_bg)
        px += Screen.draw_width(seg)
        i = e
      end
    end

    # ---- scroll / selection mutators (called by the controller) ----
    def scroll_decoded(step : Int32) : Nil
      @dec_scroll = {@dec_scroll + step, 0}.max
    end

    def scroll_output(step : Int32) : Nil
      @out_scroll = {@out_scroll + step, 0}.max
    end

    def attacks_move(dir : Int32) : Nil
      @atk_sel = {@atk_sel + dir, 0}.max
    end

    def attacks_selected : Int32
      @atk_sel
    end

    def decoded_at_top? : Bool
      @dec_scroll <= 0
    end

    # True when the DECODED card has no more lines below the viewport (or content fits).
    # A short decode uses this so ↓ leaves to ATTACKS instead of a no-op scroll.
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

    def attacks_at_top? : Bool
      @atk_sel <= 0
    end

    def reset_decoded_scroll : Nil
      @dec_scroll = 0
    end

    def reset_output_scroll : Nil
      @out_scroll = 0
    end
  end
end
