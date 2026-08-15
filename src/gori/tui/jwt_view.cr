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

    # Left stops for the top card's border chrome. `Frame.card` draws its title as ` TITLE `
    # from card.x + 2, so ` INPUT ` ends at card.x + 8 and ` HEADER ` at card.x + 9 — one past
    # each is where a right-chained badge may start. The INPUT number was a literal 8 in the
    # draw and a second literal 8 in `JwtController`'s hit-test, which let the mode badge take
    # the title's last cell at ~17 columns; both now read it here.
    INPUT_MIN_X  =  9
    HEADER_MIN_X = 10

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
                      pane : Symbol, focused : Bool, lens_chord : String) : Nil
      return if rect.empty?
      input_c, dec_c, atk_c = decode_layout(rect)

      render_input(screen, input_c, input, focused && pane == :input, input_mode, input_read, lens_chord) unless input_c.empty?
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
                      output : String, output_ok : Bool, pane : Symbol, focused : Bool,
                      lens_chord : String) : Nil
      return if rect.empty?
      hdr_c, pay_c, sec_c, out_c = encode_layout(rect)

      unless hdr_c.empty?
        render_json_editor(screen, hdr_c, "HEADER", header, focused && pane == :header)
        # HEADER is this lens' top card, so it carries the way back — see draw_lens_chip.
        draw_lens_chip(screen, hdr_c, :encode, lens_chord)
      end
      render_json_editor(screen, pay_c, "PAYLOAD", payload, focused && pane == :payload) unless pay_c.empty?
      render_secret(screen, sec_c, secret, secret_cx, secret_pre, alg, focused && pane == :secret) unless sec_c.empty?
      unless out_c.empty?
        out_lines = output_ok ? output.split('\n') : ["✗ #{output}"]
        @out_lines = out_lines.size
        # Just "OUTPUT". The failure is already the body's first line (`✗ <reason>`, in red,
        # two lines below) — the title said a shorter version of the same thing, and a card
        # title is what the card IS, not what state it is in.
        title = "OUTPUT"
        @out_h, @out_scroll = draw_text_card(screen, out_c, title, out_lines, @out_scroll,
          focused && pane == :output, fg: output_ok ? Theme.text : Theme.red)
      end
    end

    # ---- INPUT (editable, INS/READ like the Decoder input) ----
    private def render_input(screen : Screen, card : Rect, input : TextArea, active : Bool,
                             mode : InputMode, read : TextReadState, lens_chord : String) : Nil
      reading = active && mode == InputMode::Read
      insert = active && mode == InputMode::Insert
      Frame.card(screen, card, "INPUT", bg: Theme.bg, border: Frame.pane_border(active))
      # `mode`, not `insert` — the badge states the pane's own mode, and `JwtController`
      # hit-tests exactly that. Gating the draw on `active` (and passing the focus-folded
      # `insert`) left a live 8-cell target on an unpainted border: with focus on DECODED,
      # ATTACKS or SECRET, clicking the INPUT card's top-right corner toggled insert.
      # See the same fix in notes_view / fuzzer_view; focus stays in the border colour.
      Frame.mode_badge(screen, card.right - 1, card.y, card.x + INPUT_MIN_X, mode == InputMode::Insert)
      # …and the lens chip chains LEFT of it (`draw_lens_chip` re-derives that edge rather
      # than taking this return, so the hit-test can compute it the same way).
      draw_lens_chip(screen, card, :decode, lens_chord, mode == InputMode::Insert)
      body = card.inset(1, 1)
      input.render(screen, body, cursor: insert, gauge: true, gauge_focused: active)
      paint_read_chrome(screen, body, input, read) if reading
    end

    # ---- the lens chip: the ONE control on this tab with no other trace on screen ----
    # ` ^T:→ENCODE ` on the DECODE lens' INPUT card, ` ^T:→DECODE ` on the ENCODE lens'
    # HEADER card — the top card either way, where the eye lands when the tab opens. Each
    # lens is a complete workbench, so nothing inside one said the other existed: `^T` was
    # named in Help and in the footer and nowhere on the panes themselves.
    #
    # The NAME is where `^T` GOES, and the `→` says so. Naming the CURRENT lens — the way
    # the sibling ` ↵:READ ` chip names its own mode — would repeat what the card titles
    # under it already state (DECODED/ATTACKS vs PAYLOAD/SECRET/OUTPUT), and ` ^T:DECODE `
    # riding a decoding pane reads as "^T decodes this", i.e. as a key that does something
    # else. `chord` comes from the keymap, so a rebind moves this and the footer together —
    # and `lens_chord:` is REQUIRED on both render entry points rather than defaulting to
    # `"^T"`, so a second render path cannot quietly paint the default at someone who
    # rebound the switch.
    #
    # Never lit: a two-way switch has no "on" state to light (the Fuzzer's sort chip passes
    # `false` for the same reason).
    private def lens_name(mode : Symbol) : String
      mode == :decode ? "→ENCODE" : "→DECODE"
    end

    # `{right_edge, min_x}` for the chip. Draw and hit-test both derive from this one pair,
    # so the chip cannot drift off its own click target. On DECODE it chains left of INPUT's
    # READ/INS chip; on ENCODE the HEADER border carries nothing else, so it takes the edge.
    private def lens_chip_geom(card : Rect, mode : Symbol, insert : Bool) : {Int32, Int32}
      if mode == :decode
        min_x = card.x + INPUT_MIN_X
        {Frame.mode_badge_edge(card.right - 1, min_x, insert), min_x}
      else
        {card.right - 1, card.x + HEADER_MIN_X}
      end
    end

    private def draw_lens_chip(screen : Screen, card : Rect, mode : Symbol, chord : String,
                               insert : Bool = false) : Nil
      edge, min_x = lens_chip_geom(card, mode, insert)
      Frame.toggle_badge(screen, edge, card.y, min_x, chord, lens_name(mode), false)
    end

    # Hit-test the lens chip on the lens' top card — `JwtController#handle_click` runs it for
    # INPUT in DECODE and HEADER in ENCODE. `insert` is INPUT's REAL mode (the chip chains
    # past a badge whose two labels differ in width), and is unread on the ENCODE side.
    def lens_chip_hit(card : Rect, mx : Int32, my : Int32, mode : Symbol, chord : String,
                      insert : Bool = false) : Bool
      edge, min_x = lens_chip_geom(card, mode, insert)
      !Frame.right_badge_hit(mx, my, card.y, edge, min_x,
        [{:lens, chord, lens_name(mode)}] of {Symbol, String, String}).nil?
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
      Frame.card(screen, card, "ATTACKS", bg: Theme.bg, border: Frame.pane_border(focused))
      Frame.border_meta(screen, card, "ATTACKS", attacks.size.to_s)
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
        # Dimmed rather than erased when focus leaves this pane — the selection is still the
        # attack ↵ applies, and with the marker gone there was nothing on screen saying which.
        sel = idx == @atk_sel
        y = body.y + i
        bg = sel ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
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

    # The shared over-paint — see `TextReadState#paint_chrome`, which carries the reasoning
    # (including the `sync_from` this pane's own copy omitted: `^L` clears the INPUT buffer
    # without resetting the read cursor, so a caret parked on line >= 1 then indexed off the
    # end of the one-line snapshot and took the render down every tick until the tick-error
    # breaker exited the session). Routing here also makes the band wrap-correct, by
    # inverting the row list the editor actually drew instead of assuming `li - scroll`.
    private def paint_read_chrome(screen : Screen, rect : Rect, ed : TextArea, read : TextReadState) : Nil
      read.paint_chrome(screen, rect, ed)
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

    # Mouse: the attack index under a click in the ATTACKS card, or nil (past the last row).
    # Mirrors render_attacks' inset → @atk_scroll + i; the list has no header row. The pane
    # drew a cursor and moved it with ↑/↓ and the wheel, and the pointer could not place it.
    def attacks_row_at(card : Rect, my : Int32, count : Int32) : Int32?
      return nil if count <= 0
      body = card.inset(1, 1)
      return nil if body.h <= 0
      i = my - body.y
      return nil if i < 0 || i >= body.h
      idx = @atk_scroll + i
      idx < count ? idx : nil
    end

    # The attack a click on the ATTACKS gauge asks for. `@atk_scroll` is derived from
    # `@atk_sel` by render, so this answers with a selection. See `Frame.scroll_gauge_row`.
    def attacks_gauge_row(card : Rect, mx : Int32, my : Int32, count : Int32) : Int32?
      Frame.scroll_gauge_row(card.inset(1, 1), count, mx, my)
    end

    def select_attack_row(idx : Int32, count : Int32) : Nil
      @atk_sel = idx.clamp(0, {count - 1, 0}.max)
    end

    # Hit-test the SECRET card's ` ^A:<alg> ` badge. Geometry mirrors render_secret. The
    # Decoder's structurally identical ` ^X:<mode> ` on its OUTPUT card has always answered a
    # click; this one, on the sibling tool tab, did not.
    def secret_alg_hit(card : Rect, mx : Int32, my : Int32, alg : String) : Bool
      !Frame.right_badge_hit(mx, my, card.y, card.right - 1, card.x + 9,
        [{:alg, "^A", alg}] of {Symbol, String, String}).nil?
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
